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
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var locationService: LocationService
    @Query(sort: \VisitLog.arrivalDate, order: .forward) private var allVisits: [VisitLog]
    
    @State private var selectedDate: Date = .now
    @State private var selectedVisitForDetail: VisitLog?
    @State private var isShowingBaseSettings: Bool = false

    private var dailyVisits: [VisitLog] {
        let calendar = Calendar.current
        return allVisits.filter { calendar.isDate($0.arrivalDate, inSameDayAs: selectedDate) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if locationService.authorizationStatus != .authorizedAlways {
                    PermissionBannerView(status: locationService.authorizationStatus) {
                        locationService.requestPermission()
                    }
                }

                DateHeaderView(selectedDate: $selectedDate)
                Divider()

                DailyMapView(visits: dailyVisits)
                    .frame(height: 230)
                Divider()

                VStack(spacing: 6) {
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

                    if !locationService.retryStatusText.isEmpty {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption2)
                            Text(locationService.retryStatusText)
                                .font(.caption2)
                            Spacer()
                        }
                        .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                // カードリスト（左スワイプで削除可能）
                if dailyVisits.isEmpty {
                    ScrollView {
                        ContentUnavailableView(
                            "この日の滞在記録はありません",
                            systemImage: "mappin.slash",
                            description: Text("右上の⚙️ボタンから「自宅」「仕事」を事前登録しておくと、該当エリアの記録がシンプルに表示されます。")
                        )
                        .padding(.top, 30)
                    }
                    .background(Color(.systemGroupedBackground))
                } else {
                    List {
                        ForEach(dailyVisits) { visit in
                            VisitCardView(visit: visit)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedVisitForDetail = visit
                                }
                                // カードデザインの見た目を保つためのList行調整
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                // 左スワイプで削除アクション
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteVisit(visit)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("HabitCanvas PoC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingBaseSettings = true
                    } label: {
                        Label("自宅・仕事設定", systemImage: "gearshape.fill")
                    }
                }
            }
            .sheet(item: $selectedVisitForDetail) { visit in
                VisitDetailSheetView(visit: visit)
            }
            .sheet(isPresented: $isShowingBaseSettings) {
                BaseLocationSettingsSheetView()
            }
        }
    }

    /// 滞在ログをSwiftDataから削除して保存する
    private func deleteVisit(_ visit: VisitLog) {
        withAnimation {
            modelContext.delete(visit)
            try? modelContext.save()
        }
    }
}

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