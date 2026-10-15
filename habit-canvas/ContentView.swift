//
//  ContentView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//

import SwiftUI
import SwiftData
import CoreLocation

struct ContentView: View {
    @AppStorage("habitCanvasHasSeenOnboarding") private var hasSeenOnboarding = false
    @StateObject private var locationManager = VisitLocationManager()

    var body: some View {
        if hasSeenOnboarding {
            MainTabView(locationManager: locationManager)
        } else {
            OnboardingView {
                hasSeenOnboarding = true
                locationManager.requestPermission()
            }
        }
    }
}

struct MainTabView: View {
    @ObservedObject var locationManager: VisitLocationManager

    var body: some View {
        TabView {
            TimelineView(locationManager: locationManager)
                .tabItem {
                    Label("Timeline", systemImage: "clock.fill")
                }

            WeeklyReportView()
                .tabItem {
                    Label("Report", systemImage: "chart.bar.fill")
                }
        }
        .tint(.teal)
    }
}

struct OnboardingView: View {
    let onComplete: () -> Void

    private let highlights: [(title: String, description: String, icon: String)] = [
        ("自動で記録", "15分以上同じ場所に滞在すると、生活ログが自動で残ります。", "location.fill"),
        ("生活を意味で整理", "自宅・仕事・外食・レジャーなどに自動分類。", "brain.head.profile"),
        ("週ごとに気づきを伝える", "先週比で生活の偏りがわかり、改善のきっかけを作ります。", "bell.fill")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemTeal).opacity(0.22), Color(.systemMint).opacity(0.12), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("habit-canvas")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("あなたの生活を、勝手に見える化する")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

                VStack(spacing: 16) {
                    ForEach(highlights, id: \ .title) { item in
                        HStack(alignment: .top, spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.teal.opacity(0.12))
                                    .frame(width: 42, height: 42)
                                Image(systemName: item.icon)
                                    .foregroundStyle(.teal)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .font(.headline)
                                Text(item.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(icon: "lock.shield.fill", title: "完全ローカル処理", detail: "データは端末内に保存され、外部サーバーに送信しません。")
                    InfoRow(icon: "location.fill", title: "位置情報で生活を観測", detail: "同じ場所に長く滞在した際、自動で記録されます。")
                    InfoRow(icon: "bell.fill", title: "毎週の気づきを通知", detail: "日曜日の夜に、先週との比較をわかりやすくお知らせします。")
                }
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 20)

                Button(action: onComplete) {
                    Text("はじめる")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: [Color.teal, Color.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 8)
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var locationManager: VisitLocationManager
    @Query(sort: \VisitLog.startedAt, order: .reverse) private var logs: [VisitLog]

    @State private var selectedLog: VisitLog?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HeaderCard(title: "今日の生活", subtitle: "今日〜今週の滞在まとめ")

                    if let lastVisit = locationManager.lastVisit {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("直近の滞在")
                                .font(.headline)
                            Text("\(lastVisit.arrivalDate, format: .dateTime.hour(.twoDigits(amPM: .wide)).minute())")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("今週の滞在")
                            .font(.title3)
                            .fontWeight(.semibold)

                        if logs.isEmpty {
                            Text("まだ記録がありません。位置情報の収集が開始されると、ここに生活ログが表示されます。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            ForEach(logs) { log in
                                Button {
                                    selectedLog = log
                                } label: {
                                    TimelineCard(log: log)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Timeline")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        addSampleDataIfNeeded()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .onAppear {
                locationManager.startMonitoring(context: modelContext)
            }
            .sheet(item: $selectedLog) { log in
                EditVisitSheet(log: log) { updatedLog in
                    updatedLog.updatedAt = Date()
                }
            }
        }
    }

    private func addSampleDataIfNeeded() {
        if !logs.isEmpty { return }

        let sampleLogs: [VisitLog] = [
            VisitLog(venueName: "自宅", category: .home, durationMinutes: 210, startedAt: Date().addingTimeInterval(-3600)),
            VisitLog(venueName: "cafe Momo", category: .dining, durationMinutes: 55, startedAt: Date().addingTimeInterval(-7200)),
            VisitLog(venueName: "図書館", category: .selfInvestment, durationMinutes: 90, startedAt: Date().addingTimeInterval(-8500)),
            VisitLog(venueName: "駅前の映画館", category: .leisure, durationMinutes: 120, startedAt: Date().addingTimeInterval(-15000)),
            VisitLog(venueName: "オフィス", category: .work, durationMinutes: 280, startedAt: Date().addingTimeInterval(-26000))
        ]

        for log in sampleLogs {
            modelContext.insert(log)
        }
    }
}

struct HeaderCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.teal.opacity(0.18), Color.mint.opacity(0.12)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct TimelineCard: View {
    let log: VisitLog

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(log.category.accentColor.opacity(0.18))
                    .frame(width: 46, height: 46)
                Text(log.category.icon)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(log.venueName)
                    .font(.headline)
                Text(log.category.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(log.durationText)
                    .font(.headline)
                Text("滞在")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct EditVisitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var editingLog: VisitLog
    let onSave: (VisitLog) -> Void

    init(log: VisitLog, onSave: @escaping (VisitLog) -> Void) {
        self._editingLog = State(initialValue: log)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("場所") {
                    TextField("店名・施設名", text: $editingLog.venueName)
                }

                Section("ライフモード") {
                    Picker("カテゴリ", selection: $editingLog.category) {
                        ForEach(LifeMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("滞在時間") {
                    Stepper(value: $editingLog.durationMinutes, in: 15...480, step: 15) {
                        Text("\(editingLog.durationMinutes) 分")
                    }
                }
            }
            .navigationTitle("微修正")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(editingLog)
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct WeeklyReportView: View {
    @Query private var logs: [VisitLog]

    private var metrics: [WeeklyMetric] {
        let grouped = Dictionary(grouping: logs) { log in
            log.category
        }

        return [
            WeeklyMetric(mode: .selfInvestment, count: grouped[.selfInvestment]?.count ?? 0, delta: -1),
            WeeklyMetric(mode: .dining, count: grouped[.dining]?.count ?? 0, delta: 2),
            WeeklyMetric(mode: .leisure, count: grouped[.leisure]?.count ?? 0, delta: 1),
            WeeklyMetric(mode: .other, count: grouped[.other]?.count ?? 0, delta: 0)
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HeaderCard(title: "今週のライフバランス", subtitle: "先週と比べた変化をまとめました")

                    VStack(alignment: .leading, spacing: 12) {
                        Text("アクション系ライフモード")
                            .font(.title3)
                            .fontWeight(.semibold)

                        ForEach(metrics) { metric in
                            WeeklyMetricRow(metric: metric)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("要約")
                            .font(.title3)
                            .fontWeight(.semibold)

                        Text("外食の回数が少し増え、自己投資の時間は前週より1回少なめでした。休息と成長の時間をもう少し意識すると、生活のバランスが整いやすくなります。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .padding(20)
            }
            .navigationTitle("Weekly Report")
        }
    }
}

struct WeeklyMetricRow: View {
    let metric: WeeklyMetric

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(metric.mode.accentColor.opacity(0.18))
                    .frame(width: 42, height: 42)
                Text(metric.mode.icon)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(metric.mode.label)
                    .font(.headline)
                Text(metric.deltaText)
                    .font(.subheadline)
                    .foregroundStyle(metric.delta >= 0 ? .green : .orange)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(metric.count)回")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("今週")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct WeeklyMetric: Identifiable {
    let id = UUID()
    let mode: LifeMode
    let count: Int
    let delta: Int

    var deltaText: String {
        let sign = delta > 0 ? "+" : ""
        return "先週比 \(sign)\(delta)回"
    }
}

#Preview {
    let container = try! ModelContainer(
        for: VisitLog.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    let sampleLogs: [VisitLog] = [
        VisitLog(venueName: "自宅", category: .home, durationMinutes: 210, startedAt: Date().addingTimeInterval(-3600)),
        VisitLog(venueName: "cafe Momo", category: .dining, durationMinutes: 55, startedAt: Date().addingTimeInterval(-7200)),
        VisitLog(venueName: "図書館", category: .selfInvestment, durationMinutes: 90, startedAt: Date().addingTimeInterval(-8500))
    ]

    for log in sampleLogs {
        container.mainContext.insert(log)
    }

    return ContentView()
        .modelContainer(container)
}
