//
//  DateHeaderView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import MapKit

// VisitLog に「滞在中かどうか」を判定する拡張プロパティを追加
extension VisitLog {
    var isStaying: Bool {
        departureDate == nil
    }
}

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
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $position) {
            // 1. 現在の位置情報（青いドット）を表示
            UserAnnotation()

            // 2. 各滞在ログのピンを表示（滞在中・修正済・通常で色を変える）
            ForEach(visits) { visit in
                Marker(
                    markerTitle(for: visit),
                    coordinate: visit.coordinate
                )
                .tint(markerColor(for: visit))
            }
        }
        // 右上に「現在地へ戻る」ボタンを表示
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onChange(of: visits.count) {
            if !visits.isEmpty {
                position = .automatic
            }
        }
    }

    /// ピンのラベル文字列（滞在中は分かりやすく表示）
    private func markerTitle(for visit: VisitLog) -> String {
        if visit.isStaying {
            return "【滞在中】\(visit.lifeMode.icon) \(visit.placeName)"
        } else {
            return "\(visit.lifeMode.icon) \(visit.placeName)"
        }
    }

    /// ピンの色（滞在中: パープル / 修正済: グリーン / 通常: オレンジ）
    private func markerColor(for visit: VisitLog) -> Color {
        if visit.isStaying {
            return .purple
        } else if visit.isManuallyEdited {
            return .green
        } else {
            return .orange
        }
    }
}

struct VisitCardView: View {
    let visit: VisitLog

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                // 時刻 ＋ 滞在中バッジ ＋ 精度バッジ
                HStack(spacing: 8) {
                    Label(visit.timeRangeString, systemImage: visit.isStaying ? "dot.radiowaves.left.and.right" : "clock")
                        .font(.caption.bold())
                        .foregroundStyle(visit.isStaying ? .purple : .secondary)

                    if visit.isStaying {
                        Text("滞在中")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }

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
                        .background((visit.isStaying ? Color.purple : Color.orange).opacity(0.15))
                        .foregroundStyle(visit.isStaying ? .purple : .orange)
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
        // 滞在中の場合はカードの背景色と枠線をパープル系に変えて強調する
        .background(
            visit.isStaying
                ? Color.purple.opacity(0.08)
                : Color(.secondarySystemGroupedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(visit.isStaying ? Color.purple.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
}
