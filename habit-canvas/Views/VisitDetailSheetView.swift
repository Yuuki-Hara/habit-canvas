//
//  VisitDetailSheetView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import MapKit

struct VisitDetailSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let visit: VisitLog

    var body: some View {
        NavigationStack {
            List {
                // 1. ズームマップ（建物とピンのズレ確認用）
                Section("取得座標の位置確認") {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: visit.coordinate,
                        latitudinalMeters: 150,
                        longitudinalMeters: 150
                    ))) {
                        Marker(visit.placeName, coordinate: visit.coordinate)
                            .tint(.red)
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                }

                // 2. 店名・MapKitカテゴリ
                Section("MapKit 判定結果") {
                    LabeledContent("店名・施設名", value: visit.placeName)
                    LabeledContent("MapKitカテゴリ") {
                        Text(visit.rawCategory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                }

                // 3. 緯度経度・精度データ
                Section("位置情報 生データ（長押しでコピー）") {
                    LabeledContent("緯度 (Latitude)") {
                        Text(String(format: "%.6f", visit.latitude))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("経度 (Longitude)") {
                        Text(String(format: "%.6f", visit.longitude))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("水平誤差半径", value: String(format: "±%.1f m", visit.horizontalAccuracy))
                }

                // 4. 日時データ
                Section("滞在日時") {
                    LabeledContent("到着時刻", value: formatDateTime(visit.arrivalDate))
                    LabeledContent("出発時刻", value: visit.departureDate.map(formatDateTime) ?? "未確定（または手動記録）")
                }
            }
            .navigationTitle("滞在ログ詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
