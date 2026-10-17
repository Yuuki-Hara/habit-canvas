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
    
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isRecordingTestLocation: Bool = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
        self.authorizationStatus = manager.authorizationStatus
        manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
        
        startMonitoringIfAuthorized()
    }

    /// 位置情報の権限リクエスト（「使用中のみ」→「常に許可」の順）
    func requestPermission() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
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

    /// 【検証用】15分待たずに、今の現在地を即座に1件の滞在ログとして記録する
    func recordCurrentLocationForTest() {
        guard !isRecordingTestLocation else { return }
        isRecordingTestLocation = true
        manager.requestLocation()
    }
    
    private func configureBackgroundLocationUpdatesIfNeeded() {
        let hasBackgroundLocationMode = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
        manager.allowsBackgroundLocationUpdates = hasBackgroundLocationMode && manager.authorizationStatus == .authorizedAlways
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            self.manager.allowsBackgroundLocationUpdates = status == .authorizedAlways
            self.startMonitoringIfAuthorized()
            if status == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
            }
        }
    }

    /// 本番用：OSが「滞在（CLVisit）」を検知したときに自動で呼ばれる
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let coordinate = visit.coordinate
        let arrival = visit.arrivalDate == Date.distantPast ? Date() : visit.arrivalDate
        let departure = visit.departureDate == Date.distantFuture ? nil : visit.departureDate
        let accuracy = visit.horizontalAccuracy

        Task { @MainActor in
            await saveVisitLog(
                coordinate: coordinate,
                arrival: arrival,
                departure: departure,
                accuracy: accuracy
            )
        }
    }

    /// 検証用：`recordCurrentLocationForTest()` で現在地を取得したときに呼ばれる
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard self.isRecordingTestLocation else { return }
            self.isRecordingTestLocation = false
            
            await saveVisitLog(
                coordinate: location.coordinate,
                arrival: Date(),
                departure: nil,
                accuracy: location.horizontalAccuracy
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("位置情報エラー: \(error.localizedDescription)")
        Task { @MainActor in
            self.isRecordingTestLocation = false
        }
    }

    // MARK: - 保存処理

    private func saveVisitLog(
        coordinate: CLLocationCoordinate2D,
        arrival: Date,
        departure: Date?,
        accuracy: Double
    ) async {
        // 1. まずログを作成して挿入
        let newLog = VisitLog(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracy: accuracy
        )
        modelContext.insert(newLog)
        try? modelContext.save()

        // 2. MapKitで店名とカテゴリを特定して更新
        let resolved = await PlaceResolver.resolve(coordinate: coordinate)
        newLog.placeName = resolved.name
        newLog.rawCategory = resolved.category
        try? modelContext.save()
    }
}
