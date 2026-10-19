//
//  CLVisitDebugLog.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/20.
//


import Foundation
import SwiftData
import CoreLocation

@Model
final class CLVisitDebugLog {
    var id: UUID
    var receivedAt: Date          // アプリがOSから通知を受け取った日時
    var rawArrivalDate: Date      // CLVisitの生のarrivalDate
    var rawDepartureDate: Date    // CLVisitの生のdepartureDate
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var statusSummary: String     // 「✅ 採用」「⏭️ 時間不足でスキップ」「⚠️ 時刻逆転で破棄」などの判定結果
    var detailNote: String        // 詳細メモ（滞在分数や閾値など）

    init(
        id: UUID = UUID(),
        receivedAt: Date = .now,
        rawArrivalDate: Date,
        rawDepartureDate: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        statusSummary: String,
        detailNote: String
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.rawArrivalDate = rawArrivalDate
        self.rawDepartureDate = rawDepartureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.statusSummary = statusSummary
        self.detailNote = detailNote
    }

    var isArrivalDistantPast: Bool {
        rawArrivalDate == Date.distantPast
    }

    var isDepartureDistantFuture: Bool {
        rawDepartureDate == Date.distantFuture
    }
}
