//
//  DailyLogPageView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import SwiftData
import MapKit

struct DailyLogPageView: View {
    @EnvironmentObject private var locationService: LocationService
    @Query(sort: \VisitLog.arrivalDate, order: .forward) private var allVisits: [VisitLog]
    
    @State private var selectedDate: Date = .now
    @State private var selectedVisitForDetail: VisitLog?

    /// 選択された日付の 00:00 〜 23:59 のログだけを抽出
    private var dailyVisits: [VisitLog] {
        let calendar = Calendar.current
        return allVisits.filter { calendar.isDate($0.arrivalDate, inSameDayAs: selectedDate) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 1. 権限が未許可の場合のバナー
                if locationService.authorizationStatus != .authorizedAlways {
                    PermissionBannerView(status: locationService.authorizationStatus) {
                        locationService.requestPermission()
                    }
                }

                // 2. 日付切り替えバー
                DateHeaderView(selectedDate: $selectedDate)
                
                Divider()

                // 3. マップビュー（ピン表示）
                DailyMapView(visits: dailyVisits)
                    .frame(height: 240)

                Divider()

                // 4. 滞在場所カード一覧ヘッダー ＋ テスト記録ボタン
                HStack {
                    Text("滞在場所一覧 (\(dailyVisits.count)件)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button {
                        locationService.recordCurrentLocationForTest()
                    } label: {
                        HStack(spacing: 4) {
                            if locationService.isRecordingTestLocation {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus.circle.fill")
                            }
                            Text("現在地を記録(検証用)")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(locationService.isRecordingTestLocation)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                // 5. カードリスト（縦並び）
                ScrollView {
                    if dailyVisits.isEmpty {
                        ContentUnavailableView(
                            "この日の滞在記録はありません",
                            systemImage: "mappin.slash",
                            description: Text("15分以上同じ場所に滞在するか、右上の「現在地を記録」ボタンでテスト記録を追加できます。")
                        )
                        .padding(.top, 30)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(dailyVisits) { visit in
                                VisitCardView(visit: visit)
                                    .onTapGesture {
                                        selectedVisitForDetail = visit
                                    }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("HabitCanvas PoC")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedVisitForDetail) { visit in
                VisitDetailSheetView(visit: visit)
            }
        }
    }
}

// MARK: - 権限リクエストバナー
struct PermissionBannerView: View {
    let status: CLAuthorizationStatus
    let onRequest: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "location.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("位置情報の「常に許可」が必要です")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Text("現在: \(statusText)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button("許可する", action: onRequest)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white)
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        }
        .padding(10)
        .background(Color.blue)
    }

    private var statusText: String {
        switch status {
        case .notDetermined: return "未設定"
        case .authorizedWhenInUse: return "使用中のみ許可（常に許可へ変更してください）"
        case .denied, .restricted: return "拒否されています（設定アプリから変更してください）"
        default: return "設定済み"
        }
    }
}
