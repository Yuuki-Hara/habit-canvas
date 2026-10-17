//
//  DateHeaderView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import MapKit

struct DateHeaderView: View {
    @Binding var selectedDate: Date

    var body: some View {
        HStack {
            Button { changeDate(by: -1) } label: {
                Image(systemName: "chevron.left").font(.headline).padding(8)
            }
            Spacer()
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "ja_JP"))
            Spacer()
            Button { changeDate(by: 1) } label: {
                Image(systemName: "chevron.right").font(.headline).padding(8)
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

struct DailyMapView: View {
    let visits: [VisitLog]
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(visits) { visit in
                Marker("\(visit.lifeMode.icon) \(visit.placeName)", coordinate: visit.coordinate)
                    .tint(visit.isManuallyEdited ? .green : .orange)
            }
        }
        .onChange(of: visits.count) {
            position = .automatic
        }
    }
}

struct VisitCardView: View {
    let visit: VisitLog

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // 時刻 ＋ 精度バッジ
                HStack(spacing: 8) {
                    Label(visit.timeRangeString, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(String(format: "±%.1fm", visit.horizontalAccuracy))
                        .font(.caption2.monospaced())
                        .foregroundStyle(visit.horizontalAccuracy <= 5.0 ? .green : .secondary)
                    
                    if visit.isManuallyEdited {
                        Text("修正済")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)
                    }
                }

                // 店名
                Text(visit.placeName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                // ライフモード ＆ MapKitカテゴリバッジ
                HStack(spacing: 6) {
                    Text(visit.lifeMode.displayName)
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())

                    Text(visit.rawCategory)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(Capsule())
                }
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