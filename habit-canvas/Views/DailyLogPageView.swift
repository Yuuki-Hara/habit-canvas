//
//  DailyLogPageView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import SwiftData
import CoreLocation

struct DailyLogPageView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var locationService: LocationService
    @Query(sort: \VisitLog.arrivalDate, order: .forward) private var allVisits: [VisitLog]
    
    @State private var selectedDate: Date = .now
    @State private var selectedVisitForDetail: VisitLog?
    @State private var isShowingBaseSettings: Bool = false
    
    private var dailyVisits: [VisitLog] {
        let calendar = Calendar.current
        return allVisits.filter {
            !$0.isIgnored && calendar.isDate($0.arrivalDate, inSameDayAs: selectedDate)
        }
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
                
                // 操作パネル＆GPS精度ビジュアルインジケーター
                VStack(spacing: 8) {
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
                    
                    // 【追加】現在のGPS精度を視覚的にわかるようにするインジケーターバー
                    GPSAccuracyIndicatorView(
                        retryText: locationService.retryStatusText,
                        isRecording: locationService.isRecordingTestLocation
                    )
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))
                
                if dailyVisits.isEmpty {
                    ScrollView {
                        ContentUnavailableView(
                            "この日の滞在記録はありません",
                            systemImage: "mappin.slash",
                            description: Text("滞在が検知されると自動で記録され、Push通知から店舗の変更や破棄も行えます。")
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
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
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
                        Label("設定・デバッグ", systemImage: "gearshape.fill")
                    }
                }
            }
            .sheet(item: $selectedVisitForDetail) { visit in
                VisitDetailSheetView(visit: visit)
            }
            .sheet(isPresented: $isShowingBaseSettings) {
                BaseLocationSettingsSheetView()
            }
            // NotificationCenter経由で安全に通知アクションを受け取る
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DidReceiveNotificationAction"))) { notification in
                guard let userInfo = notification.userInfo,
                      let actionID = userInfo["actionID"] as? String,
                      let visitID = userInfo["visitID"] as? UUID else {
                    return
                }

                Task { @MainActor in
                    if actionID == NotificationService.ActionID.openMapEdit || actionID == UNNotificationDefaultActionIdentifier {
                        // マップで修正：こちらは既存の allVisits から探して安全にシートを開く
                        if let targetVisit = allVisits.first(where: { $0.id == visitID && !$0.isIgnored }) {
                            selectedDate = targetVisit.arrivalDate
                            selectedVisitForDetail = targetVisit
                        }
                    } else {
                        executeActionSafely(actionID: actionID, visitID: visitID)
                    }
                }
            }
        }
    }
    
    @MainActor
    private func deleteVisit(_ visit: VisitLog) {
        withAnimation {
            visit.isIgnored = true
            try? modelContext.save()
        }
    }
    @MainActor
    private func handleNotificationActionDB(actionID: String, visitID: UUID) {
        // 【修正】modelContext.fetch を使わず、メインスレッド側のメモリ上にある allVisits から直接安全に探す
        guard let visit = allVisits.first(where: { $0.id == visitID }) else { return }
        
        switch actionID {
        case NotificationService.ActionID.keep:
            visit.isManuallyEdited = true
            try? modelContext.save()
            
        case NotificationService.ActionID.selectCandidate1:
            if visit.candidates.count > 1 {
                applyCandidate(visit.candidates[1], to: visit)
            }
            
        case NotificationService.ActionID.selectCandidate2:
            if visit.candidates.count > 2 {
                applyCandidate(visit.candidates[2], to: visit)
            }
            
        case NotificationService.ActionID.ignore:
            visit.isIgnored = true
            try? modelContext.save()
            
        default:
            break
        }
    }
    
    @MainActor
    private func applyCandidate(_ candidate: PlaceCandidate, to visit: VisitLog) {
        visit.placeName = candidate.name
        visit.rawCategory = candidate.rawCategory
        visit.lifeMode = candidate.lifeMode
        visit.latitude = candidate.latitude
        visit.longitude = candidate.longitude
        visit.isManuallyEdited = true
        try? modelContext.save()
    }
    /// メインスレッド上で安全に専用のコンテキストを切ってデータを更新する（根本的なスレッド競合の回避）
    @MainActor
    private func executeActionSafely(actionID: String, visitID: UUID) {
        do {
            var descriptor = FetchDescriptor<VisitLog>(
                predicate: #Predicate { $0.id == visitID }
            )
            descriptor.fetchLimit = 1

            if let visit = try modelContext.fetch(descriptor).first {
                switch actionID {
                case NotificationService.ActionID.keep:
                    visit.isManuallyEdited = true

                case NotificationService.ActionID.selectCandidate1:
                    if visit.candidates.count > 1 {
                        let candidate = visit.candidates[1]
                        visit.placeName = candidate.name
                        visit.rawCategory = candidate.rawCategory
                        visit.lifeMode = candidate.lifeMode
                        visit.latitude = candidate.latitude
                        visit.longitude = candidate.longitude
                        visit.isManuallyEdited = true
                    }

                case NotificationService.ActionID.selectCandidate2:
                    if visit.candidates.count > 2 {
                        let candidate = visit.candidates[2]
                        visit.placeName = candidate.name
                        visit.rawCategory = candidate.rawCategory
                        visit.lifeMode = candidate.lifeMode
                        visit.latitude = candidate.latitude
                        visit.longitude = candidate.longitude
                        visit.isManuallyEdited = true
                    }

                case NotificationService.ActionID.ignore:
                    visit.isIgnored = true

                default:
                    break
                }

                try modelContext.save()
            }
        } catch {
            print("通知アクションのデータ処理に失敗しました: \(error.localizedDescription)")
        }
    }
}

// =========================================================================
// 【修正版】現在のGPS精度（定量値・数値付き）を示すインジケーターコンポーネント
// =========================================================================
struct GPSAccuracyIndicatorView: View {
    let retryText: String
    let isRecording: Bool
    @EnvironmentObject private var locationService: LocationService

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(statusTitle)
                        .font(.caption.bold())
                        .foregroundStyle(statusColor)

                    Spacer()

                    // 定量的な誤差の数値をリアルタイム表示
                    Text(quantitativeAccuracyText)
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(statusColor)
                }

                if !retryText.isEmpty {
                    Text(retryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 精度レベルに応じたビジュアルバー
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .frame(height: 4)

                        Capsule()
                            .fill(statusColor)
                            .frame(width: barWidth(totalWidth: geometry.size.width), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var iconName: String {
        if isRecording { return "antenna.radiowaves.left.and.right" }
        return "location.circle.fill"
    }

    private var statusTitle: String {
        if isRecording { return "GPS高精度リトライ測位中" }
        return "GPSバックグラウンド監視中"
    }

    /// 定量的な精度テキストを算出
    private var quantitativeAccuracyText: String {
        if let lastLoc = CLLocationManager().location, lastLoc.horizontalAccuracy > 0 {
            return String(format: "精度: ±%.1f m", lastLoc.horizontalAccuracy)
        }
        return isRecording ? "測位中..." : "待機中"
    }

    /// 精度の良さに応じたステータスカラー
    private var statusColor: Color {
        if isRecording { return .orange }
        
        if let lastLoc = CLLocationManager().location, lastLoc.horizontalAccuracy > 0 {
            let acc = lastLoc.horizontalAccuracy
            if acc <= 5.0 { return .green }
            if acc <= 20.0 { return .yellow }
            return .red
        }
        return .green
    }

    /// 【修正】バーの長さを計算するメソッド（funcに変更）
    private func barWidth(totalWidth: CGFloat) -> CGFloat {
        if isRecording { return totalWidth * 0.7 }
        
        if let lastLoc = CLLocationManager().location, lastLoc.horizontalAccuracy > 0 {
            let acc = lastLoc.horizontalAccuracy
            if acc <= 5.0 { return totalWidth }
            if acc <= 20.0 { return totalWidth * 0.6 }
            return totalWidth * 0.3
        }
        return totalWidth
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
