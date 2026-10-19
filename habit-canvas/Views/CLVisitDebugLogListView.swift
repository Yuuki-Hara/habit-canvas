//
//  CLVisitDebugLogListView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/20.
//


import SwiftUI
import SwiftData

struct CLVisitDebugLogListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CLVisitDebugLog.receivedAt, order: .reverse) private var debugLogs: [CLVisitDebugLog]

    var body: some View {
        List {
            if debugLogs.isEmpty {
                ContentUnavailableView(
                    "CLVisit の受信ログはまだありません",
                    systemImage: "list.bullet.rectangle.portrait",
                    description: Text("OSから滞在検知（到着・出発）の通知が届くと、採用・破棄に関わらずすべての生ログがここに記録されます。")
                )
            } else {
                Section("受信履歴 (\(debugLogs.count)件) - 新しい順") {
                    ForEach(debugLogs) { log in
                        VStack(alignment: .leading, spacing: 6) {
                            // 1. 判定結果バッジ ＆ 受信日時
                            HStack {
                                Text(log.statusSummary)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(statusColor(for: log.statusSummary).opacity(0.15))
                                    .foregroundStyle(statusColor(for: log.statusSummary))
                                    .clipShape(Capsule())

                                Spacer()

                                Text("受信: \(formatDateTime(log.receivedAt))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            // 2. CLVisitの到着・出発時刻
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("到着 (arrival):")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 95, alignment: .leading)
                                    Text(log.isArrivalDistantPast ? "distantPast (不明)" : formatDateTime(log.rawArrivalDate))
                                        .font(.caption.monospaced().bold())
                                        .foregroundStyle(log.isArrivalDistantPast ? .orange : .primary)
                                }

                                HStack {
                                    Text("出発 (departure):")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 95, alignment: .leading)
                                    Text(log.isDepartureDistantFuture ? "distantFuture (滞在中)" : formatDateTime(log.rawDepartureDate))
                                        .font(.caption.monospaced().bold())
                                        .foregroundStyle(log.isDepartureDistantFuture ? .blue : .primary)
                                }
                            }
                            .padding(.vertical, 2)

                            // 3. 判定理由・滞在時間メモ
                            Text(log.detailNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            // 4. 座標と精度
                            HStack {
                                Text(String(format: "📍 %.5f, %.5f", log.latitude, log.longitude))
                                Spacer()
                                Text(String(format: "精度: ±%.1fm", log.horizontalAccuracy))
                            }
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteLogs)
                }
            }
        }
        .navigationTitle("CLVisit 受信ログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !debugLogs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        clearAllLogs()
                    } label: {
                        Label("全消去", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func deleteLogs(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(debugLogs[index])
        }
        try? modelContext.save()
    }

    private func clearAllLogs() {
        for log in debugLogs {
            modelContext.delete(log)
        }
        try? modelContext.save()
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm:ss"
        return formatter.string(from: date)
    }

    private func statusColor(for summary: String) -> Color {
        if summary.contains("✅") { return .green }
        if summary.contains("🔵") { return .blue }
        if summary.contains("⏭️") { return .orange }
        return .red
    }
}
