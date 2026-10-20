//
//  RegisteredPlacesStore.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import Foundation
import CoreLocation
import Combine

@MainActor
final class RegisteredPlacesStore: ObservableObject {
    static let shared = RegisteredPlacesStore()

    let homeRadiusMeters: Double = 60.0
    let workRadiusMeters: Double = 80.0

    @Published var homeCoordinate: CLLocationCoordinate2D? {
        didSet { saveCoordinate(homeCoordinate, latKey: "registered_home_lat", lonKey: "registered_home_lon") }
    }

    @Published var workCoordinate: CLLocationCoordinate2D? {
        didSet { saveCoordinate(workCoordinate, latKey: "registered_work_lat", lonKey: "registered_work_lon") }
    }

    @Published var minimumStayMinutes: Int {
        didSet {
            let clamped = max(0, minimumStayMinutes)
            if minimumStayMinutes != clamped {
                minimumStayMinutes = clamped
            }
            UserDefaults.standard.set(minimumStayMinutes, forKey: "debug_minimum_stay_minutes")
        }
    }

    /// 【追加】自宅・仕事エリアでもPush通知を送るか（デフォルト: 検証用にON）
    @Published var notifyForBaseLocations: Bool {
        didSet {
            UserDefaults.standard.set(notifyForBaseLocations, forKey: "debug_notify_base_locations")
        }
    }

    var minimumStayDurationSeconds: TimeInterval {
        TimeInterval(minimumStayMinutes * 60)
    }

    private init() {
        if UserDefaults.standard.object(forKey: "debug_minimum_stay_minutes") != nil {
            self.minimumStayMinutes = UserDefaults.standard.integer(forKey: "debug_minimum_stay_minutes")
        } else {
            self.minimumStayMinutes = 10
        }

        if UserDefaults.standard.object(forKey: "debug_notify_base_locations") != nil {
            self.notifyForBaseLocations = UserDefaults.standard.bool(forKey: "debug_notify_base_locations")
        } else {
            self.notifyForBaseLocations = true
        }

        self.homeCoordinate = loadCoordinate(latKey: "registered_home_lat", lonKey: "registered_home_lon")
        self.workCoordinate = loadCoordinate(latKey: "registered_work_lat", lonKey: "registered_work_lon")
    }

    func matchRegisteredMode(for coordinate: CLLocationCoordinate2D) -> (mode: LifeMode, distance: Double)? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var candidates: [(mode: LifeMode, distance: Double)] = []

        if let home = homeCoordinate {
            let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let dist = target.distance(from: homeLoc)
            if dist <= homeRadiusMeters {
                candidates.append((.home, dist))
            }
        }

        if let work = workCoordinate {
            let workLoc = CLLocation(latitude: work.latitude, longitude: work.longitude)
            let dist = target.distance(from: workLoc)
            if dist <= workRadiusMeters {
                candidates.append((.work, dist))
            }
        }

        return candidates.min(by: { $0.distance < $1.distance })
    }

    private func saveCoordinate(_ coord: CLLocationCoordinate2D?, latKey: String, lonKey: String) {
        let defaults = UserDefaults.standard
        if let coord {
            defaults.set(coord.latitude, forKey: latKey)
            defaults.set(coord.longitude, forKey: lonKey)
        } else {
            defaults.removeObject(forKey: latKey)
            defaults.removeObject(forKey: lonKey)
        }
    }

    private func loadCoordinate(latKey: String, lonKey: String) -> CLLocationCoordinate2D? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: latKey) != nil,
              defaults.object(forKey: lonKey) != nil else {
            return nil
        }
        let lat = defaults.double(forKey: latKey)
        let lon = defaults.double(forKey: lonKey)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
