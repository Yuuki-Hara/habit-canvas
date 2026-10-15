//
//  Item.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class VisitLog {
    @Attribute(.unique) var id: UUID
    var venueName: String
    var categoryRawValue: String
    var durationMinutes: Int
    var startedAt: Date
    var updatedAt: Date

    var category: LifeMode {
        get { LifeMode(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        venueName: String,
        category: LifeMode,
        durationMinutes: Int,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.venueName = venueName
        self.categoryRawValue = category.rawValue
        self.durationMinutes = durationMinutes
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

enum LifeMode: String, CaseIterable, Codable {
    case home
    case work
    case selfInvestment
    case dining
    case leisure
    case other

    var label: String {
        switch self {
        case .home: return "自宅"
        case .work: return "仕事"
        case .selfInvestment: return "自己投資"
        case .dining: return "外食"
        case .leisure: return "レジャー"
        case .other: return "その他"
        }
    }

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

    var accentColor: Color {
        switch self {
        case .home: return .blue
        case .work: return .orange
        case .selfInvestment: return .green
        case .dining: return .pink
        case .leisure: return .purple
        case .other: return .gray
        }
    }
}

extension VisitLog {
    var durationText: String {
        let hours = durationMinutes / 60
        let minutes = durationMinutes % 60

        if hours > 0 {
            return "\(hours)時間 \(minutes)分"
        }
        return "\(minutes)分"
    }

    var startedAtText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: startedAt)
    }

    var summaryText: String {
        "\(venueName) · \(category.label) · \(durationText)"
    }
}
