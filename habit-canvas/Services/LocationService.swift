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
    
    // 【追加】最小滞在時間フィルター（10分 = 600秒未満の立ち止まりは記録しない）
    private let minimumStayDurationSeconds: TimeInterval = 10 * 60
    
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

    /// 【検証用】ボタン押下で高精度サンプリング（手動テスト記録は時間フィルター対象外で即記録）
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
            print(retryStatusText)
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
            print("有効な位置情報が1件も取得できませんでした")
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

    /// 本番用：OSが「滞在（CLVisit）」を検知したときに呼ばれる
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

    /// CLVisitの時刻逆転防止・短時間滞在の除外・出発時刻の更新を一括処理する
    private func handleIncomingVisit(
        rawArrival: Date,
        rawDeparture: Date,
        coordinate: CLLocationCoordinate2D,
        accuracy: Double
    ) {
        // 1. 到着時刻が不明（distantPast）な場合は、開始・終了時刻の逆転原因になるため無視する
        guard rawArrival != Date.distantPast else {
            print("⚠️ 到着時刻が不明(distantPast)なCLVisitのためスキップしました")
            return
        }

        let isDepartureConfirmed = (rawDeparture != Date.distantFuture)

        // 2. 出発時刻が確定している場合のチェック
        if isDepartureConfirmed {
            // (A) 開始時刻と終了時刻が逆転・同一している異常データは破棄
            guard rawDeparture > rawArrival else {
                print("⚠️ 時刻逆転データ(arrival: \(rawArrival), departure: \(rawDeparture))を破棄しました")
                return
            }

            let duration = rawDeparture.timeIntervalSince(rawArrival)

            // (B) すでに「到着時（departureDate == nil）」に仮保存された同一ログがあるか検索
            if let existingLog = findMatchingOngoingVisit(arrival: rawArrival, coordinate: coordinate) {
                if duration < minimumStayDurationSeconds {
                    // 10分未満の立ち止まりだった場合は、仮保存していたログ自体を削除する
                    print("🗑️ 滞在時間が短いため(\(Int(duration / 60))分)、仮ログを削除しました")
                    modelContext.delete(existingLog)
                } else {
                    // 10分以上滞在していた場合は、出発時刻を更新して確定させる
                    print("✅ 既存ログの出発時刻を更新しました (滞在: \(Int(duration / 60))分)")
                    existingLog.departureDate = rawDeparture
                }
                try? modelContext.save()
                return
            }

            // (C) 到着時の仮ログがなく、出発確定として新規に届いた場合も10分未満なら破棄
            guard duration >= minimumStayDurationSeconds else {
                print("⏭️ 滞在時間が\(Int(minimumStayDurationSeconds / 60))分未満(\(Int(duration))秒)のため記録をスキップしました")
                return
            }
        } else {
            // 3. 到着通知（まだ滞在中）の場合：すでに同じ到着時刻のログがあれば重複作成しない
            if findMatchingOngoingVisit(arrival: rawArrival, coordinate: coordinate) != nil {
                return
            }
            // ※「出発が確定して10分以上と分かってから初めてカードを表示したい」場合は、
            //   ここの else ブロックで return するように変更することも可能です。
            return
        }

        // 4. 10分以上の有効な滞在として確定したものだけ、高精度測位または保存へ進む
        let initialLoc = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: Date()
        )

        let confirmedDeparture: Date? = isDepartureConfirmed ? rawDeparture : nil

        if accuracy > 0 && accuracy <= accuracyThreshold {
            Task {
                await finalizeAndSave(
                    bestLocation: initialLoc,
                    arrival: rawArrival,
                    departure: confirmedDeparture
                )
            }
        } else {
            startHighAccuracySampling(
                initialLocation: initialLoc,
                arrival: rawArrival,
                departure: confirmedDeparture
            )
        }
    }

    /// 到着時刻がほぼ同じ（誤差2分以内）または距離が50m以内の未確定ログを探す
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
        // 保存直前にも、万が一時刻の逆転がないか最終ガード
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
