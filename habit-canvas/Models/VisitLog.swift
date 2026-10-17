import Foundation
import SwiftData
import CoreLocation

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

    init(
        id: UUID = UUID(),
        arrivalDate: Date,
        departureDate: Date?,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        placeName: String = "場所を特定中...",
        rawCategory: String = "取得中..."
    ) {
        self.id = id
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.placeName = placeName
        self.rawCategory = rawCategory
    }

    // MapKit表示用の座標プロパティ
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // 滞在時間のテキスト表示
    var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: arrivalDate)
        if let departure = departureDate {
            let end = formatter.string(from: departure)
            return "\(start) - \(end)"
        } else {
            return "\(start) - 滞在中（または手動記録）"
        }
    }
}