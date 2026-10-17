//
//  DateHeaderView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import MapKit

// MARK: - 1. 日付切り替えバー
struct DateHeaderView: View {
    @Binding var selectedDate: Date

    var body: some View {
        HStack {
            Button {
                changeDate(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .padding(8)
            }

            Spacer()

            DatePicker(
                "",
                selection: $selectedDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "ja_JP"))

            Spacer()

            Button {
                changeDate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .padding(8)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private func changeDate(by days: Int) {
        if let newDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) {
            selectedDate = newDate
        }
    }
}

// MARK: - 2. その日の滞在ピンを表示するマップビュー
struct DailyMapView: View {
    let visits: [VisitLog]
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(visits) { visit in
                Marker(visit.placeName, coordinate: visit.coordinate)
                    .tint(.orange)
            }
        }
        .onChange(of: visits.count) {
            position = .automatic
        }
    }
}

// MARK: - 3. 縦に並ぶ滞在場所カードUI
struct VisitCardView: View {
    let visit: VisitLog

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // 滞在時刻
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(visit.timeRangeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 店名
                Text(visit.placeName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                // MapKitカテゴリバッジ
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                        .font(.caption2)
                    Text(visit.rawCategory)
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
