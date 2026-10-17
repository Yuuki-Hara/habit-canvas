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

    /// 【検証用】ボタン押下で高精度サンプリング（閾値5m・最大3回リトライ）を開始する
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

        print("採用されたベスト座標の精度: ±\(String(format: "%.1f", bestLocation.horizontalAccuracy))m (計\(collectedLocations.count)サンプル中)")

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
        let arrival = visit.arrivalDate == Date.distantPast ? Date() : visit.arrivalDate
        let departure = visit.departureDate == Date.distantFuture ? nil : visit.departureDate
        let initialLoc = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: Date()
        )

        Task { @MainActor in
            if visit.horizontalAccuracy > 0 && visit.horizontalAccuracy <= self.accuracyThreshold {
                await self.finalizeAndSave(bestLocation: initialLoc, arrival: arrival, departure: departure)
            } else {
                self.startHighAccuracySampling(initialLocation: initialLoc, arrival: arrival, departure: departure)
            }
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
            print("GPS受信 [試行\(self.currentRetryCount)]: 精度 ±\(String(format: "%.1f", latest.horizontalAccuracy))m")

            if latest.horizontalAccuracy <= self.accuracyThreshold {
                print("閾値(\(self.accuracyThreshold)m)以下を達成したため即採用します！")
                self.finishSamplingWithBestLocation()
            } else {
                self.advanceRetryOrFinalize()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("位置情報取得エラー: \(error.localizedDescription)")
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
        // 1. 保存前に、過去の「手動修正済み（isManuallyEdited == true）」ログ一覧を取得しておく
        let learnedSnapshots = fetchLearnedPlaces()

        let coordinate = bestLocation.coordinate
        let newLog = VisitLog(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: bestLocation.horizontalAccuracy
        )
        modelContext.insert(newLog)
        try? modelContext.save()

        // 2. 学習データを渡してPlaceResolverを実行
        let resolved = await PlaceResolver.resolve(
            coordinate: coordinate,
            arrivalDate: arrival,
            learnedPlaces: learnedSnapshots
        )
        
        newLog.placeName = resolved.primaryName
        newLog.rawCategory = resolved.primaryCategory
        newLog.lifeMode = resolved.majorityLifeMode
        newLog.candidates = resolved.candidates
        // 学習履歴から自動マッチした場合は修正済みフラグも引き継ぐ
        if resolved.isMatchedFromHistory {
            newLog.isManuallyEdited = true
        }
        try? modelContext.save()
    }

    /// 過去にユーザーが手動で修正したログをSwiftDataから取得する（直近の修正を優先）
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