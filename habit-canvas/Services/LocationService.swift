//
//  LocationService.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import Foundation
import CoreLocation
import SwiftData
import Combine

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let modelContext: ModelContext
    
    private let accuracyThreshold: Double = 5.0
    private let maxRetries: Int = 3
    
    private var minimumStayDurationSeconds: TimeInterval {
        RegisteredPlacesStore.shared.minimumStayDurationSeconds
    }
    
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecordingTestLocation: Bool = false
    @Published var retryStatusText: String = ""

    private var collectedLocations: [CLLocation] = []
    private var currentRetryCount: Int = 0
    private var targetLogForRefinement: VisitLog? = nil
    private var isCollectingSamples: Bool = false
    private var samplingTimeoutTask: Task<Void, Never>?
    private var pendingArrivalWaitTasks: [String: Task<Void, Never>] = [:]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        self.authorizationStatus = manager.authorizationStatus
        
        startMonitoringIfAuthorized()
    }

    func requestPermission() {
        NotificationService.shared.requestAuthorization()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    private func startMonitoringIfAuthorized() {
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.startMonitoringVisits()
            NotificationService.shared.requestAuthorization()
            print("CLVisit（滞在監視）を開始しました")
        }
    }

    /// 【検証用】ボタン押下で現在地を即座に記録＆Push通知送信
    func recordCurrentLocationForTest() {
        guard !isCollectingSamples else { return }
        isRecordingTestLocation = true
        
        if let currentLoc = manager.location, currentLoc.horizontalAccuracy > 0 {
            Task {
                let log = await createOrUpdateVisitLog(
                    coordinate: currentLoc.coordinate,
                    accuracy: currentLoc.horizontalAccuracy,
                    arrival: .now,
                    departure: nil,
                    shouldSendNotification: true
                )
                if currentLoc.horizontalAccuracy > accuracyThreshold {
                    startHighAccuracySampling(for: log, initialLocation: currentLoc)
                } else {
                    isRecordingTestLocation = false
                }
            }
        } else {
            startHighAccuracySampling(for: nil, initialLocation: nil)
        }
    }

    private func startHighAccuracySampling(
        for existingLog: VisitLog?,
        initialLocation: CLLocation?
    ) {
        collectedLocations.removeAll()
        if let initial = initialLocation, initial.horizontalAccuracy > 0 {
            collectedLocations.append(initial)
        }

        targetLogForRefinement = existingLog
        currentRetryCount = 0
        isCollectingSamples = true
        retryStatusText = "高精度GPS計測中 (初回)..."

        manager.startUpdatingLocation()
        scheduleTimeoutForCurrentAttempt()
    }

    private func scheduleTimeoutForCurrentAttempt() {
        samplingTimeoutTask?.cancel()
        samplingTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.isCollectingSamples else { return }
            self.advanceRetryOrFinalize()
        }
    }

    private func advanceRetryOrFinalize() {
        if currentRetryCount < maxRetries {
            currentRetryCount += 1
            retryStatusText = "精度5m超過のため再試行中 (\(currentRetryCount)/\(maxRetries)回目)..."
            scheduleTimeoutForCurrentAttempt()
        } else {
            finishSamplingWithBestLocation()
        }
    }

    private func finishSamplingWithBestLocation() {
        samplingTimeoutTask?.cancel()
        manager.stopUpdatingLocation()
        isCollectingSamples = false
        isRecordingTestLocation = false
        retryStatusText = ""

        guard let bestLocation = collectedLocations
            .filter({ $0.horizontalAccuracy > 0 })
            .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else {
            targetLogForRefinement = nil
            return
        }

        let logToUpdate = targetLogForRefinement
        targetLogForRefinement = nil

        Task {
            if let log = logToUpdate {
                if bestLocation.horizontalAccuracy < log.horizontalAccuracy {
                    await updateExistingLogLocation(log, with: bestLocation)
                }
            } else {
                _ = await createOrUpdateVisitLog(
                    coordinate: bestLocation.coordinate,
                    accuracy: bestLocation.horizontalAccuracy,
                    arrival: .now,
                    departure: nil,
                    shouldSendNotification: true
                )
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            self.startMonitoringIfAuthorized()
            if status == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let rawArrival = visit.arrivalDate
        let rawDeparture = visit.departureDate
        let coordinate = visit.coordinate
        let accuracy = visit.horizontalAccuracy

        Task { @MainActor in
            await self.handleIncomingVisit(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy
            )
        }
    }

    private func handleIncomingVisit(
        rawArrival: Date,
        rawDeparture: Date,
        coordinate: CLLocationCoordinate2D,
        accuracy: Double
    ) async {
        let currentMinSeconds = minimumStayDurationSeconds
        let currentMinMinutes = Int(currentMinSeconds / 60)
        let visitKey = "\(Int(rawArrival.timeIntervalSince1970))"

        guard rawArrival != Date.distantPast else {
            saveDebugLog(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy,
                status: "⚠️ 到着時刻不明で破棄",
                note: "arrivalDate が distantPast のためスキップしました"
            )
            return
        }

        let isDepartureConfirmed = (rawDeparture != Date.distantFuture)

        // パターンA：まだ出発前（滞在中）
        if !isDepartureConfirmed {
            let elapsedSinceArrival = Date().timeIntervalSince(rawArrival)
            let elapsedMinutesStr = String(format: "%.1f分", max(0, elapsedSinceArrival) / 60.0)

            if elapsedSinceArrival >= currentMinSeconds {
                let log = await createOrUpdateVisitLog(
                    coordinate: coordinate,
                    accuracy: accuracy,
                    arrival: rawArrival,
                    departure: nil,
                    shouldSendNotification: true
                )
                saveDebugLog(
                    rawArrival: rawArrival,
                    rawDeparture: rawDeparture,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    status: "✅ 到着採用（通知＆一覧表示）",
                    note: "到着から \(elapsedMinutesStr) 経過（閾値 \(currentMinMinutes)分以上）のため一覧保存＆通知を送信しました"
                )
                if accuracy > accuracyThreshold {
                    startHighAccuracySampling(for: log, initialLocation: CLLocation(
                        coordinate: coordinate,
                        altitude: 0,
                        horizontalAccuracy: accuracy,
                        verticalAccuracy: -1,
                        timestamp: Date()
                    ))
                }
            } else {
                let remainingSeconds = currentMinSeconds - max(0, elapsedSinceArrival)
                let remainingMinutesStr = String(format: "%.1f分", remainingSeconds / 60.0)

                saveDebugLog(
                    rawArrival: rawArrival,
                    rawDeparture: rawDeparture,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    status: "🔵 到着検知（条件待機中）",
                    note: "現在 \(elapsedMinutesStr) 経過。あと \(remainingMinutesStr) 滞在が続けば一覧保存＆Push通知を送ります"
                )

                pendingArrivalWaitTasks[visitKey]?.cancel()
                pendingArrivalWaitTasks[visitKey] = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(remainingSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.pendingArrivalWaitTasks.removeValue(forKey: visitKey)

                    if self.findMatchingVisit(arrival: rawArrival, coordinate: coordinate) == nil {
                        _ = await self.createOrUpdateVisitLog(
                            coordinate: coordinate,
                            accuracy: accuracy,
                            arrival: rawArrival,
                            departure: nil,
                            shouldSendNotification: true
                        )
                        self.saveDebugLog(
                            rawArrival: rawArrival,
                            rawDeparture: Date.distantFuture,
                            coordinate: coordinate,
                            accuracy: accuracy,
                            status: "✅ 滞在条件達成（通知＆一覧追加）",
                            note: "到着から \(currentMinMinutes)分 が経過したため、一覧保存＆Push通知を送信しました"
                        )
                    }
                }
            }
            return
        }

        // パターンB：出発時刻が確定した場合
        pendingArrivalWaitTasks[visitKey]?.cancel()
        pendingArrivalWaitTasks.removeValue(forKey: visitKey)

        guard rawDeparture > rawArrival else {
            saveDebugLog(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy,
                status: "⚠️ 時刻逆転で破棄",
                note: "出発時刻が到着時刻以前になっている異常データのため破棄しました"
            )
            return
        }

        let durationSeconds = rawDeparture.timeIntervalSince(rawArrival)
        let durationMinutesString = String(format: "%.1f分", durationSeconds / 60.0)

        // 1. すでに到着時に保存されたログがある場合
        if let existingLog = findMatchingVisit(arrival: rawArrival, coordinate: coordinate) {
            // 通知から「登録しない（破棄）」が選ばれていた場合はそのまま無視する
            if existingLog.isIgnored {
                saveDebugLog(
                    rawArrival: rawArrival,
                    rawDeparture: rawDeparture,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    status: "🗑️ 破棄済みログのため無視",
                    note: "通知で「登録しない」が選択された滞在のため、出発通知もスキップしました"
                )
                return
            }

            if durationSeconds < currentMinSeconds {
                modelContext.delete(existingLog)
                try? modelContext.save()
                saveDebugLog(
                    rawArrival: rawArrival,
                    rawDeparture: rawDeparture,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    status: "⏭️ 時間不足で削除",
                    note: "最終滞在 \(durationMinutesString) ＜ 設定閾値 \(currentMinMinutes)分 のため仮ログを削除"
                )
            } else {
                existingLog.departureDate = rawDeparture
                try? modelContext.save()
                saveDebugLog(
                    rawArrival: rawArrival,
                    rawDeparture: rawDeparture,
                    coordinate: coordinate,
                    accuracy: accuracy,
                    status: "✅ 出発時刻を更新",
                    note: "滞在 \(durationMinutesString)（閾値 \(currentMinMinutes)分以上）で既存カードの終了時刻を確定しました"
                )
            }
            return
        }

        // 2. 既存ログがない場合、滞在時間が閾値以上かチェック
        guard durationSeconds >= currentMinSeconds else {
            saveDebugLog(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy,
                status: "⏭️ 時間不足でスキップ",
                note: "滞在 \(durationMinutesString) ＜ 設定閾値 \(currentMinMinutes)分 のため記録せずスキップ"
            )
            return
        }

        // 3. 新規に出発確定として届いた場合：即保存＆まだ通知していなかったのでPush通知を送る
        let createdLog = await createOrUpdateVisitLog(
            coordinate: coordinate,
            accuracy: accuracy,
            arrival: rawArrival,
            departure: rawDeparture,
            shouldSendNotification: true
        )

        saveDebugLog(
            rawArrival: rawArrival,
            rawDeparture: rawDeparture,
            coordinate: coordinate,
            accuracy: accuracy,
            status: "✅ 採用（滞在確定＆通知）",
            note: "滞在 \(durationMinutesString)（閾値 \(currentMinMinutes)分以上）のため一覧保存＆通知しました（場所: \(createdLog.placeName)）"
        )

        if accuracy > accuracyThreshold {
            let initialLoc = CLLocation(
                coordinate: coordinate,
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: -1,
                timestamp: Date()
            )
            startHighAccuracySampling(for: createdLog, initialLocation: initialLoc)
        }
    }

    // MARK: - ログの作成・更新・検索ヘルパー

    private func createOrUpdateVisitLog(
        coordinate: CLLocationCoordinate2D,
        accuracy: Double,
        arrival: Date,
        departure: Date?,
        shouldSendNotification: Bool
    ) async -> VisitLog {
        if let existing = findMatchingVisit(arrival: arrival, coordinate: coordinate) {
            if let dep = departure, dep > arrival {
                existing.departureDate = dep
            }
            try? modelContext.save()
            return existing
        }

        let validDeparture: Date? = (departure != nil && departure! > arrival) ? departure : nil
        let learnedSnapshots = fetchLearnedPlaces()

        let newLog = VisitLog(
            arrivalDate: arrival,
            departureDate: validDeparture,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: accuracy
        )
        modelContext.insert(newLog)
        try? modelContext.save()

        let resolved = await PlaceResolver.resolve(
            coordinate: coordinate,
            learnedPlaces: learnedSnapshots
        )
        
        newLog.placeName = resolved.primaryName
        newLog.rawCategory = resolved.primaryCategory
        newLog.lifeMode = resolved.majorityLifeMode
        newLog.candidates = resolved.candidates
        if resolved.isMatchedFromHistory {
            newLog.isManuallyEdited = true
        }
        try? modelContext.save()

        // 場所解決が完了した時点でインタラクティブPush通知を送信
        if shouldSendNotification {
            await NotificationService.shared.sendVisitRecordedNotification(for: newLog)
        }

        return newLog
    }

    private func updateExistingLogLocation(_ log: VisitLog, with betterLocation: CLLocation) async {
        guard !log.isManuallyEdited, !log.isIgnored else { return }

        let coord = betterLocation.coordinate
        log.latitude = coord.latitude
        log.longitude = coord.longitude
        log.horizontalAccuracy = betterLocation.horizontalAccuracy

        let learnedSnapshots = fetchLearnedPlaces()
        let resolved = await PlaceResolver.resolve(
            coordinate: coord,
            learnedPlaces: learnedSnapshots
        )
        log.placeName = resolved.primaryName
        log.rawCategory = resolved.primaryCategory
        log.lifeMode = resolved.majorityLifeMode
        log.candidates = resolved.candidates
        if resolved.isMatchedFromHistory {
            log.isManuallyEdited = true
        }
        try? modelContext.save()
    }

    private func findMatchingVisit(arrival: Date, coordinate: CLLocationCoordinate2D) -> VisitLog? {
        let descriptor = FetchDescriptor<VisitLog>(
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        guard let logs = try? modelContext.fetch(descriptor) else { return nil }
        let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return logs.first { log in
            let timeDiff = abs(log.arrivalDate.timeIntervalSince(arrival))
            let logLoc = CLLocation(latitude: log.latitude, longitude: log.longitude)
            let dist = targetLoc.distance(from: logLoc)
            return timeDiff < 180 || (log.departureDate == nil && dist < 60)
        }
    }

    private func saveDebugLog(
        rawArrival: Date,
        rawDeparture: Date,
        coordinate: CLLocationCoordinate2D,
        accuracy: Double,
        status: String,
        note: String
    ) {
        let log = CLVisitDebugLog(
            rawArrivalDate: rawArrival,
            rawDepartureDate: rawDeparture,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: accuracy,
            statusSummary: status,
            detailNote: note
        )
        modelContext.insert(log)
        try? modelContext.save()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let freshLocations = locations.filter {
            $0.horizontalAccuracy > 0 && abs($0.timestamp.timeIntervalSinceNow) < 5.0
        }
        guard let latest = freshLocations.last else { return }

        Task { @MainActor in
            guard self.isCollectingSamples else { return }
            self.collectedLocations.append(latest)

            if latest.horizontalAccuracy <= self.accuracyThreshold {
                self.finishSamplingWithBestLocation()
            } else {
                self.advanceRetryOrFinalize()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.isCollectingSamples else { return }
            self.advanceRetryOrFinalize()
        }
    }

    private func fetchLearnedPlaces() -> [LearnedPlaceSnapshot] {
        let descriptor = FetchDescriptor<VisitLog>(
            predicate: #Predicate { $0.isManuallyEdited == true && $0.isIgnored == false },
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        guard let editedLogs = try? modelContext.fetch(descriptor) else { return [] }
        
        return editedLogs.map { log in
            LearnedPlaceSnapshot(
                placeName: log.placeName,
                rawCategory: log.rawCategory,
                lifeMode: log.lifeMode,
                latitude: log.latitude,
                longitude: log.longitude
            )
        }
    }
}
