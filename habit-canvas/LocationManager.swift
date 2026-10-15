import Foundation
import SwiftUI
import Combine
import CoreLocation
import MapKit
import SwiftData

@MainActor
final class VisitLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastKnownLocation: CLLocation?
    @Published var lastVisit: CLVisit?

    private let locationManager = CLLocationManager()
    private var modelContext: ModelContext?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters

#if targetEnvironment(simulator)
        locationManager.allowsBackgroundLocationUpdates = false
#else
        locationManager.allowsBackgroundLocationUpdates = true
#endif

        locationManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = locationManager.authorizationStatus
    }

    func startMonitoring(context: ModelContext) {
        modelContext = context

        switch locationManager.authorizationStatus {
        case .notDetermined:
#if targetEnvironment(simulator)
            locationManager.requestWhenInUseAuthorization()
#else
            locationManager.requestAlwaysAuthorization()
#endif
        case .authorizedAlways, .authorizedWhenInUse:
            startTracking()
        default:
            break
        }
    }

    func requestPermission() {
#if targetEnvironment(simulator)
        locationManager.requestWhenInUseAuthorization()
#else
        locationManager.requestAlwaysAuthorization()
#endif
    }

    private func startTracking() {
#if targetEnvironment(simulator)
        locationManager.startUpdatingLocation()
#else
        locationManager.startMonitoringVisits()
        locationManager.startUpdatingLocation()
#endif
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            startTracking()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastKnownLocation = location
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        lastVisit = visit

        Task {
            let placeName = await resolvePlaceName(for: visit.coordinate) ?? "未分類スポット"
            let category = classifyLifeMode(for: placeName)
            let durationMinutes = max(15, Int(visit.departureDate.timeIntervalSince(visit.arrivalDate) / 60))

            guard let modelContext else { return }

            let log = VisitLog(
                venueName: placeName,
                category: category,
                durationMinutes: durationMinutes,
                startedAt: visit.arrivalDate,
                updatedAt: visit.departureDate
            )

            modelContext.insert(log)
            try? modelContext.save()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager error: \(error.localizedDescription)")
    }

    private func resolvePlaceName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "cafe restaurant library gym park movie theater"
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 500,
            longitudinalMeters: 500
        )

        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.first?.name
        } catch {
            return nil
        }
    }

    private func classifyLifeMode(for placeName: String) -> LifeMode {
        let hour = Calendar.current.component(.hour, from: Date())
        let isWeekday = Calendar.current.isDateInWeekend(Date()) == false
        let lowerName = placeName.lowercased()

        if hour >= 0 && hour <= 5 {
            return .home
        }

        if isWeekday && hour >= 9 && hour <= 18 {
            return .work
        }

        if lowerName.contains("cafe") || lowerName.contains("restaurant") || lowerName.contains("coffee") || lowerName.contains("burger") || lowerName.contains("bar") || lowerName.contains("supermarket") || lowerName.contains("grocery") || lowerName.contains("food") {
            return .dining
        }

        if lowerName.contains("library") || lowerName.contains("book") || lowerName.contains("gym") || lowerName.contains("fitness") || lowerName.contains("museum") {
            return .selfInvestment
        }

        if lowerName.contains("park") || lowerName.contains("movie") || lowerName.contains("theater") || lowerName.contains("stadium") || lowerName.contains("spa") || lowerName.contains("amusement") {
            return .leisure
        }

        return .other
    }
}
