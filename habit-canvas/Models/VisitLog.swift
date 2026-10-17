//
//  VisitLog.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import Foundation
import SwiftData
import CoreLocation
import MapKit

enum LifeMode: String, Codable, CaseIterable, Identifiable {
    case home = "自宅"
    case work = "仕事"
    case selfInvestment = "自己投資"
    case dining = "外食"
    case leisure = "レジャー"
    case other = "その他"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "🏠"
        case .work: return "🏢"
        case .selfInvestment: return "💪"
        case .dining: return "🍽️"
        case .leisure: return "⛺️"
        case .other: return "📦"
        }
    }

    var displayName: String {
        "\(icon) \(rawValue)"
    }

    /// MapKitのカテゴリからライフモードを判定する（自宅・仕事は事前登録座標で判定するためここには含めない）
    static func classify(rawCategory: String?) -> LifeMode {
        guard let raw = rawCategory else {
            return .other
        }

        let category = MKPointOfInterestCategory(rawValue: raw)
        switch category {
        // 💪 自己投資
        case .fitnessCenter, .library, .museum, .planetarium, .school, .university:
            return .selfInvestment
        // 🍽️ 外食
        case .cafe, .restaurant, .bakery, .brewery, .foodMarket, .winery, .distillery:
            return .dining
        // ⛺️ レジャー
        case .movieTheater, .theater, .nightlife, .park, .amusementPark, .aquarium, .beach, .campground, .marina, .nationalPark, .stadium, .zoo:
            return .leisure
        default:
            if raw.lowercased().contains("bookstore") || raw.lowercased().contains("library") {
                return .selfInvestment
            }
            return .other
        }
    }
}

struct PlaceCandidate: Codable, Identifiable, Hashable {
    var id: String { "\(name)_\(latitude)_\(longitude)" }
    let name: String
    let rawCategory: String
    let lifeModeRaw: String
    let distanceMeters: Double
    let latitude: Double
    let longitude: Double

    var lifeMode: LifeMode {
        LifeMode(rawValue: lifeModeRaw) ?? .other
    }
}

@Model
final class VisitLog {
    var id: UUID
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var placeName: String
    var rawCategory: String
    var lifeModeRaw: String
    var isManuallyEdited: Bool
    var candidatesData: Data?

    init(
        id: UUID = UUID(),
        arrivalDate: Date,
        departureDate: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        placeName: String = "場所を特定中...",
        rawCategory: String = "取得中...",
        lifeMode: LifeMode = .other,
        isManuallyEdited: Bool = false,
        candidates: [PlaceCandidate] = []
    ) {
        self.id = id
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.placeName = placeName
        self.rawCategory = rawCategory
        self.lifeModeRaw = lifeMode.rawValue
        self.isManuallyEdited = isManuallyEdited
        self.candidatesData = try? JSONEncoder().encode(candidates)
    }

    var lifeMode: LifeMode {
        get { LifeMode(rawValue: lifeModeRaw) ?? .other }
        set { lifeModeRaw = newValue.rawValue }
    }

    var candidates: [PlaceCandidate] {
        get {
            guard let data = candidatesData else { return [] }
            return (try? JSONDecoder().decode([PlaceCandidate].self, from: data)) ?? []
        }
        set {
            candidatesData = try? JSONEncoder().encode(newValue)
        }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: arrivalDate)
        if let departure = departureDate {
            let end = formatter.string(from: departure)
            return "\(start) - \(end)"
        } else {
            return "\(start) - 記録"
        }
    }
}
