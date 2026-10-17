//
//  ReportPageView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import SwiftUI
import SwiftData
import Charts

struct ReportPageView: View {
    @Query(sort: \VisitLog.arrivalDate, order: .reverse) private var allVisits: [VisitLog]

    enum PeriodScope: String, CaseIterable, Identifiable {
        case week = "週間"
        case month = "月間"
        var id: String { rawValue }
    }

    @State private var selectedScope: PeriodScope = .week
    @State private var anchorDate: Date = .now
    @State private var expandedMode: LifeMode? = nil

    // アクション（お出かけ）として主集計する4モード
    private let outingModes: [LifeMode] = [.selfInvestment, .dining, .leisure, .other]
    // ベース拠点として別枠表示する2モード
    private let baseModes: [LifeMode] = [.work, .home]

    /// 現在選択されている期間（週または月）の開始日〜終了日
    private var currentPeriodInterval: DateInterval {
        let calendar = Calendar.current
        switch selectedScope {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: anchorDate)
                ?? DateInterval(start: anchorDate, duration: 86400 * 7)
        case .month:
            return calendar.dateInterval(of: .month, for: anchorDate)
                ?? DateInterval(start: anchorDate, duration: 86400 * 30)
        }
    }

    /// 期間内に含まれる VisitLog 一覧
    private var periodVisits: [VisitLog] {
        let interval = currentPeriodInterval
        return allVisits.filter { interval.contains($0.arrivalDate) }
    }

    /// ライフモードごとの該当ログ配列
    private func visits(for mode: LifeMode) -> [VisitLog] {
        periodVisits.filter { $0.lifeMode == mode }
    }

    /// お出かけ系モードの合計回数
    private var totalOutingCount: Int {
        outingModes.reduce(0) { $0 + visits(for: $1).count }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. 週間 / 月間 セグメント ＆ 期間切り替えヘッダー
                    VStack(spacing: 10) {
                        Picker("期間タイプ", selection: $selectedScope) {
                            ForEach(PeriodScope.allCases) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Button {
                                shiftPeriod(by: -1)
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.headline)
                                    .padding(6)
                            }

                            Spacer()

                            Text(periodTitleString)
                                .font(.headline)

                            Spacer()

                            Button {
                                shiftPeriod(by: 1)
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.headline)
                                    .padding(6)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // 2. お出かけ回数 合計サマリー ＆ 棒グラフ
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("お出かけアクション合計")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(totalOutingCount)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text("回")
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                        }

                        if totalOutingCount == 0 {
                            ContentUnavailableView(
                                "この期間のお出かけ記録はありません",
                                systemImage: "chart.bar.xaxis",
                                description: Text("カフェやジム、お出かけ先での滞在が記録されるとここに回数グラフが描かれます。")
                            )
                            .frame(height: 180)
                        } else {
                            Chart {
                                ForEach(outingModes) { mode in
                                    let count = visits(for: mode).count
                                    BarMark(
                                        x: .value("ライフモード", mode.displayName),
                                        y: .value("回数", count)
                                    )
                                    .foregroundStyle(color(for: mode))
                                    .cornerRadius(6)
                                    .annotation(position: .top) {
                                        if count > 0 {
                                            Text("\(count)回")
                                                .font(.caption.bold())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .chartYAxis {
                                AxisMarks(values: .automatic(desiredCount: 4))
                            }
                            .frame(height: 190)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // 3. お出かけ系ライフモード別の回数カード（タップで内訳展開）
                    VStack(alignment: .leading, spacing: 10) {
                        Text("お出かけモード別の回数（タップで履歴を表示）")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        ForEach(outingModes) { mode in
                            ModeCountExpandableRow(
                                mode: mode,
                                logs: visits(for: mode),
                                tintColor: color(for: mode),
                                isExpanded: expandedMode == mode,
                                onToggle: {
                                    withAnimation(.snappy) {
                                        expandedMode = (expandedMode == mode) ? nil : mode
                                    }
                                }
                            )
                        }
                    }

                    // 4. ベース拠点（仕事・自宅）の記録回数
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ベース拠点の記録回数")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        ForEach(baseModes) { mode in
                            ModeCountExpandableRow(
                                mode: mode,
                                logs: visits(for: mode),
                                tintColor: color(for: mode),
                                isExpanded: expandedMode == mode,
                                onToggle: {
                                    withAnimation(.snappy) {
                                        expandedMode = (expandedMode == mode) ? nil : mode
                                    }
                                }
                            )
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("HabitCanvas レポート")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - ヘルパー

    private var periodTitleString: String {
        let interval = currentPeriodInterval
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")

        switch selectedScope {
        case .week:
            formatter.dateFormat = "M/d(E)"
            let startStr = formatter.string(from: interval.start)
            // DateIntervalのendは翌週頭0:00になるため、1秒引いて最終日を表示
            let endDay = interval.end.addingTimeInterval(-1)
            let endStr = formatter.string(from: endDay)
            return "\(startStr) 〜 \(endStr)"
        case .month:
            formatter.dateFormat = "yyyy年 M月"
            return formatter.string(from: interval.start)
        }
    }

    private func shiftPeriod(by value: Int) {
        let calendar = Calendar.current
        let component: Calendar.Component = (selectedScope == .week) ? .weekOfYear : .month
        if let newDate = calendar.date(byAdding: component, value: value, to: anchorDate) {
            anchorDate = newDate
        }
    }

    private func color(for mode: LifeMode) -> Color {
        switch mode {
        case .selfInvestment: return .purple
        case .dining: return .orange
        case .leisure: return .green
        case .other: return .gray
        case .work: return .blue
        case .home: return .teal
        }
    }
}

// MARK: - ライフモード別の回数 ＆ タップで内訳を展開するカード
struct ModeCountExpandableRow: View {
    let mode: LifeMode
    let logs: [VisitLog]
    let tintColor: Color
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(tintColor.opacity(0.18))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Text(mode.icon)
                                .font(.title3)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.rawValue)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if let latest = logs.first {
                            Text("直近: \(latest.placeName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("記録なし")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(logs.count)")
                            .font(.title2.bold())
                            .foregroundStyle(logs.isEmpty ? .secondary : tintColor)
                        Text("回")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                }
                .padding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // タップ時に展開される訪問リスト内訳
            if isExpanded && !logs.isEmpty {
                Divider()
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(logs) { log in
                        HStack {
                            Text(formatShortDate(log.arrivalDate))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 85, alignment: .leading)

                            Text(log.placeName)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground).opacity(0.5))
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E) HH:mm"
        return formatter.string(from: date)
    }
}