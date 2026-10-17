//
//  RegisteredPlacesStore.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import Foundation
import CoreLocation
import Combine

/// 事前登録された「自宅」「仕事」の座標を管理するクラス
@MainActor
final class RegisteredPlacesStore: ObservableObject {
    static let shared = RegisteredPlacesStore()

    // 判定半径（自宅: 60m以内、仕事: 80m以内）
    let homeRadiusMeters: Double = 60.0
    let workRadiusMeters: Double = 80.0

    @Published var homeCoordinate: CLLocationCoordinate2D? {
        didSet { saveCoordinate(homeCoordinate, latKey: "registered_home_lat", lonKey: "registered_home_lon") }
    }

    @Published var workCoordinate: CLLocationCoordinate2D? {
        didSet { saveCoordinate(workCoordinate, latKey: "registered_work_lat", lonKey: "registered_work_lon") }
    }

    private init() {
        self.homeCoordinate = loadCoordinate(latKey: "registered_home_lat", lonKey: "registered_home_lon")
        self.workCoordinate = loadCoordinate(latKey: "registered_work_lat", lonKey: "registered_work_lon")
    }

    /// 渡された座標が「自宅」または「仕事」の半径内に入っているか判定する
    func matchRegisteredMode(for coordinate: CLLocationCoordinate2D) -> (mode: LifeMode, distance: Double)? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        if let home = homeCoordinate {
            let homeLoc = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let dist = target.distance(from: homeLoc)
            if dist <= homeRadiusMeters {
                return (.home, dist)
            }
        }

        if let work = workCoordinate {
            let workLoc = CLLocation(latitude: work.latitude, longitude: work.longitude)
            let dist = target.distance(from: workLoc)
            if dist <= workRadiusMeters {
                return (.work, dist)
            }
        }

        return nil
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
