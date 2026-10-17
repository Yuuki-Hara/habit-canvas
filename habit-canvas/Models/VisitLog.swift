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

/// 6つのライフモード定義
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

    /// MapKitのカテゴリと到着日時からライフモードを判定する
    static func classify(rawCategory: String?, arrivalDate: Date) -> LifeMode {
        guard let raw = rawCategory else {
            return classifyByTimeHeuristics(arrivalDate: arrivalDate)
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
            // BookstoreなどiOSバージョン依存の文字列も含めて判定
            if raw.lowercased().contains("bookstore") || raw.lowercased().contains("library") {
                return .selfInvestment
            }
            return .other
        }
    }

    /// POIがない場所（住宅街やオフィス街など）の時間帯判定
    static func classifyByTimeHeuristics(arrivalDate: Date) -> LifeMode {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: arrivalDate)
        let isWeekend = calendar.isDateInWeekend(arrivalDate)

        // 深夜22時〜朝7時の滞在開始は「自宅」と仮判定
        if hour >= 22 || hour <= 7 {
            return .home
        }
        // 平日9時〜18時の滞在開始は「仕事」と仮判定
        if !isWeekend && (9...18).contains(hour) {
            return .work
        }
        return .other
    }
}

/// 周辺の施設候補データ（JSONとしてVisitLog内に保存可能にする）
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
    var candidatesData: Data? // 周辺候補リスト（JSONエンコードデータ）

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