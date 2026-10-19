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
    
    // 精度閾値（5.0m）と最大リトライ回数（3回）
    private let accuracyThreshold: Double = 5.0
    private let maxRetries: Int = 3
    
    /// 設定画面で指定された最小滞在時間（秒）を動的に取得する
    private var minimumStayDurationSeconds: TimeInterval {
        RegisteredPlacesStore.shared.minimumStayDurationSeconds
    }
    
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecordingTestLocation: Bool = false
    @Published var retryStatusText: String = ""

    private var collectedLocations: [CLLocation] = []
    private var currentRetryCount: Int = 0
    private var pendingArrivalDate: Date = .now
    private var pendingDepartureDate: Date? = nil
    private var isCollectingSamples: Bool = false
    private var samplingTimeoutTask: Task<Void, Never>?

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
            print("CLVisit（滞在監視）を開始しました")
        }
    }

    func recordCurrentLocationForTest() {
        guard !isCollectingSamples else { return }
        isRecordingTestLocation = true
        startHighAccuracySampling(initialLocation: nil, arrival: .now, departure: nil)
    }

    private func startHighAccuracySampling(
        initialLocation: CLLocation?,
        arrival: Date,
        departure: Date?
    ) {
        collectedLocations.removeAll()
        if let initial = initialLocation, initial.horizontalAccuracy > 0 {
            collectedLocations.append(initial)
            if initial.horizontalAccuracy <= accuracyThreshold {
                Task {
                    await finalizeAndSave(bestLocation: initial, arrival: arrival, departure: departure)
                }
                return
            }
        }

        currentRetryCount = 0
        pendingArrivalDate = arrival
        pendingDepartureDate = departure
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
            return
        }

        let arrival = pendingArrivalDate
        let departure = pendingDepartureDate
        Task {
            await finalizeAndSave(bestLocation: bestLocation, arrival: arrival, departure: departure)
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
            self.handleIncomingVisit(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy
            )
        }
    }

    /// CLVisitの受信生ログを保存しつつ、フィルター判定とVisitLog保存を行う
    private func handleIncomingVisit(
        rawArrival: Date,
        rawDeparture: Date,
        coordinate: CLLocationCoordinate2D,
        accuracy: Double
    ) {
        let currentMinSeconds = minimumStayDurationSeconds
        let currentMinMinutes = Int(currentMinSeconds / 60)

        // 1. 到着時刻が不明（distantPast）な場合
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

        // 2. 出発時刻が確定している場合
        if isDepartureConfirmed {
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

            // 既存の滞在中ログがあれば更新または削除
            if let existingLog = findMatchingOngoingVisit(arrival: rawArrival, coordinate: coordinate) {
                if durationSeconds < currentMinSeconds {
                    modelContext.delete(existingLog)
                    try? modelContext.save()
                    saveDebugLog(
                        rawArrival: rawArrival,
                        rawDeparture: rawDeparture,
                        coordinate: coordinate,
                        accuracy: accuracy,
                        status: "⏭️ 時間不足で削除",
                        note: "滞在 \(durationMinutesString) ＜ 設定閾値 \(currentMinMinutes)分 のため仮ログを削除"
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
                        note: "滞在 \(durationMinutesString)（閾値 \(currentMinMinutes)分以上）で既存ログを更新確定"
                    )
                }
                return
            }

            // 新規で出発確定通知が届いた場合の閾値チェック
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

            // 条件クリアで新規保存へ
            saveDebugLog(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy,
                status: "✅ 採用（滞在確定）",
                note: "滞在 \(durationMinutesString)（閾値 \(currentMinMinutes)分以上）のため新規記録します"
            )
        } else {
            // 3. 到着通知（departureDate == distantFuture）の場合
            saveDebugLog(
                rawArrival: rawArrival,
                rawDeparture: rawDeparture,
                coordinate: coordinate,
                accuracy: accuracy,
                status: "🔵 到着検知（待機中）",
                note: "まだ出発時刻が未確定（滞在中）のイベントです。出発確定時に\(currentMinMinutes)分以上か判定します"
            )
            return
        }

        // 4. 有効な滞在として確定したものを測位・保存
        let initialLoc = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: Date()
        )

        if accuracy > 0 && accuracy <= accuracyThreshold {
            Task {
                await finalizeAndSave(
                    bestLocation: initialLoc,
                    arrival: rawArrival,
                    departure: rawDeparture
                )
            }
        } else {
            startHighAccuracySampling(
                initialLocation: initialLoc,
                arrival: rawArrival,
                departure: rawDeparture
            )
        }
    }

    /// CLVisitの生イベントをデバッグログとしてSwiftDataに保存する
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

    private func findMatchingOngoingVisit(arrival: Date, coordinate: CLLocationCoordinate2D) -> VisitLog? {
        let descriptor = FetchDescriptor<VisitLog>(
            sortBy: [SortDescriptor(\.arrivalDate, order: .reverse)]
        )
        guard let logs = try? modelContext.fetch(descriptor) else { return nil }
        let targetLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        return logs.first { log in
            let timeDiff = abs(log.arrivalDate.timeIntervalSince(arrival))
            let logLoc = CLLocation(latitude: log.latitude, longitude: log.longitude)
            let dist = targetLoc.distance(from: logLoc)
            return timeDiff < 120 || (log.departureDate == nil && dist < 50)
        }
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

    // MARK: - SwiftDataへの保存 ＆ 学習データの参照

    private func finalizeAndSave(
        bestLocation: CLLocation,
        arrival: Date,
        departure: Date?
    ) async {
        let validDeparture: Date?
        if let dep = departure, dep > arrival {
            validDeparture = dep
        } else {
            validDeparture = nil
        }

        let learnedSnapshots = fetchLearnedPlaces()
        let coordinate = bestLocation.coordinate

        let newLog = VisitLog(
            arrivalDate: arrival,
            departureDate: validDeparture,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: bestLocation.horizontalAccuracy
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
    }

    private func fetchLearnedPlaces() -> [LearnedPlaceSnapshot] {
        let descriptor = FetchDescriptor<VisitLog>(
            predicate: #Predicate { $0.isManuallyEdited == true },
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
