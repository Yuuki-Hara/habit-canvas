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
    private let samePlaceRadiusMeters: Double = 60.0
    
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

    // =========================================================================
    // 検証用ボタン押下時：
    // 1. 同じ場所に「滞在中」のカードがあれば → 出発時刻を記録して「出発済」にする
    // 2. 同じ場所に「滞在中」のカードがなければ → 古い「滞在中」を閉じて、確実に新規「滞在中」カードを追加する
    // =========================================================================
    func recordCurrentLocationForTest() {
        if isCollectingSamples {
            samplingTimeoutTask?.cancel()
            manager.stopUpdatingLocation()
            isCollectingSamples = false
        }

        let now = Date()
        let fallbackCoord = RegisteredPlacesStore.shared.homeCoordinate
            ?? CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125)
        let currentLoc = manager.location
        let currentCoord = currentLoc?.coordinate ?? fallbackCoord
        let currentAccuracy = (currentLoc != nil && currentLoc!.horizontalAccuracy > 0)
            ? currentLoc!.horizontalAccuracy
            : 30.0

        // パターン1：同じ場所（半径60m以内）に「滞在中（departureDate == nil）」のカードがある場合
        // → そのカードに出発時刻を入れて「出発済」に変化させる（カードは増やさず色を変化させる）
        if let ongoingSamePlace = findOngoingVisitNear(coordinate: currentCoord) {
            ongoingSamePlace.departureDate = max(now, ongoingSamePlace.arrivalDate.addingTimeInterval(60))
            try? modelContext.save()

            saveDebugLog(
                rawArrival: ongoingSamePlace.arrivalDate,
                rawDeparture: ongoingSamePlace.departureDate ?? now,
                coordinate: ongoingSamePlace.coordinate,
                accuracy: ongoingSamePlace.horizontalAccuracy,
                status: "✅ 手動テスト：出発確定",
                note: "滞在中だった「\(ongoingSamePlace.placeName)」を出発済に更新しました（もう一度押すと新規カードが追加されます）"
            )
            isRecordingTestLocation = false
            retryStatusText = "「\(ongoingSamePlace.placeName)」を出発済に更新しました（もう一度押すと新規追加）"
            return
        }

        // パターン2：同じ場所に「滞在中」のカードがない場合
        // → 他の場所に残っている「滞在中」があればすべてクローズし、現在地で新しい「滞在中」カードを作成する
        closeAllOtherOngoingVisits(at: now, enforceMinDuration: false)

        isRecordingTestLocation = true
        retryStatusText = "新規の滞在中カードを作成中..."

        Task {
            // 新規の「滞在中（departure: nil）」カードを確実に作成する
            let newLog = await insertNewVisitLog(
                coordinate: currentCoord,
                accuracy: currentAccuracy,
                arrival: now,
                departure: nil,
                shouldSendNotification: true
            )

            saveDebugLog(
                rawArrival: now,
                rawDeparture: Date.distantFuture,
                coordinate: currentCoord,
                accuracy: currentAccuracy,
                status: "🔵 手動テスト：新規到着（滞在中）",
                note: "新規の「滞在中」カードを作成しました（\(newLog.placeName)）"
            )

            if currentAccuracy > accuracyThreshold {
                startHighAccuracySampling(for: newLog, initialLocation: currentLoc)
            } else {
                isRecordingTestLocation = false
                retryStatusText = ""
            }
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

    // =========================================================================
    // CLVisit 受信ハンドリング
    // =========================================================================
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

        // パターンA：まだ出発前（滞在中 / departureDate == distantFuture）
        if !isDepartureConfirmed {
            closeAllOtherOngoingVisits(
                exceptNear: coordinate,
                at: rawArrival,
                enforceMinDuration: true
            )

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
                        self.closeAllOtherOngoingVisits(
                            exceptNear: coordinate,
                            at: rawArrival,
                            enforceMinDuration: true
                        )
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

        if let existingLog = findMatchingVisit(arrival: rawArrival, coordinate: coordinate) {
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

        closeAllOtherOngoingVisits(
            exceptNear: coordinate,
            at: rawArrival,
            enforceMinDuration: true
        )

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

    // MARK: - ログの作成・更新・検索・「滞在中」クローズ処理

    /// 【修正】SwiftDataのPredicateバグを避けるため、全件取得後にメモリ上で「!isIgnored && departureDate == nil」を確実に判定する
    private func fetchActiveOngoingLogs() -> [VisitLog] {
        let descriptor = FetchDescriptor<VisitLog>(
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        guard let allLogs = try? modelContext.fetch(descriptor) else { return [] }
        return allLogs.filter { !$0.isIgnored && $0.departureDate == nil }
    }

    /// 指定した座標の近く（半径60m以内）で現在「滞在中（departureDate == nil）」になっているログを探す
    private func findOngoingVisitNear(coordinate: CLLocationCoordinate2D) -> VisitLog? {
        let ongoingLogs = fetchActiveOngoingLogs()
        let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return ongoingLogs.first { log in
            let logLoc = CLLocation(latitude: log.latitude, longitude: log.longitude)
            return targetLoc.distance(from: logLoc) <= samePlaceRadiusMeters
        }
    }

    /// 他の場所で「滞在中（departureDate == nil）」のまま残っている古いログをすべて指定時刻でクローズする
    private func closeAllOtherOngoingVisits(
        exceptNear excludedCoordinate: CLLocationCoordinate2D? = nil,
        at closingTime: Date,
        enforceMinDuration: Bool
    ) {
        let ongoingLogs = fetchActiveOngoingLogs()
        guard !ongoingLogs.isEmpty else { return }

        for log in ongoingLogs {
            if let excluded = excludedCoordinate {
                let excludedLoc = CLLocation(latitude: excluded.latitude, longitude: excluded.longitude)
                let logLoc = CLLocation(latitude: log.latitude, longitude: log.longitude)
                if excludedLoc.distance(from: logLoc) <= samePlaceRadiusMeters {
                    continue
                }
            }

            let finalDeparture = (closingTime > log.arrivalDate) ? closingTime : Date()
            let duration = finalDeparture.timeIntervalSince(log.arrivalDate)

            if enforceMinDuration && duration < minimumStayDurationSeconds {
                modelContext.delete(log)
            } else {
                log.departureDate = max(finalDeparture, log.arrivalDate.addingTimeInterval(60))
            }
        }
        try? modelContext.save()
    }

    /// CLVisit用：既存の未出発ログがあればそれを更新し、なければ新規作成する
    private func createOrUpdateVisitLog(
        coordinate: CLLocationCoordinate2D,
        accuracy: Double,
        arrival: Date,
        departure: Date?,
        shouldSendNotification: Bool
    ) async -> VisitLog {
        if let existing = findMatchingVisit(arrival: arrival, coordinate: coordinate) {
            if let dep = departure, dep > existing.arrivalDate {
                existing.departureDate = dep
            }
            try? modelContext.save()
            return existing
        }

        return await insertNewVisitLog(
            coordinate: coordinate,
            accuracy: accuracy,
            arrival: arrival,
            departure: departure,
            shouldSendNotification: shouldSendNotification
        )
    }

    /// 新しいVisitLogレコードを確実にSwiftDataへ挿入し、場所解決とPush通知を行う
    private func insertNewVisitLog(
        coordinate: CLLocationCoordinate2D,
        accuracy: Double,
        arrival: Date,
        departure: Date?,
        shouldSendNotification: Bool
    ) async -> VisitLog {
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

    /// 【修正】すでに「出発済み（departureDate != nil）」の別セッションのカードを誤って拾わないよう修正
    private func findMatchingVisit(arrival: Date, coordinate: CLLocationCoordinate2D) -> VisitLog? {
        let descriptor = FetchDescriptor<VisitLog>(
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        guard let allLogs = try? modelContext.fetch(descriptor) else { return nil }
        let activeLogs = allLogs.filter { !$0.isIgnored }
        let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return activeLogs.first { log in
            let timeDiff = abs(log.arrivalDate.timeIntervalSince(arrival))
            let logLoc = CLLocation(latitude: log.latitude, longitude: log.longitude)
            let dist = targetLoc.distance(from: logLoc)

            // 1. 現在「滞在中（departureDate == nil）」で半径60m以内のカードがあればマッチ
            if log.departureDate == nil && dist <= samePlaceRadiusMeters {
                return true
            }
            // 2. CLVisitの同一イベント重複通知（arrivalDateが10秒以内かつ同じ場所）であればマッチ
            if timeDiff < 10 && dist <= samePlaceRadiusMeters {
                return true
            }
            return false
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
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        guard let allLogs = try? modelContext.fetch(descriptor) else { return [] }
        let editedLogs = allLogs.filter { $0.isManuallyEdited && !$0.isIgnored }
        
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
