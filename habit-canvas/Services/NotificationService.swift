//
//  NotificationService.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/20.
//


import Foundation
import UserNotifications
import SwiftData
import Combine

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    var modelContext: ModelContext?

    /// 「アプリで修正」または通知本体をタップした際に、詳細シートを直接開くためのトリガーID
    @Published var visitIDToOpenInSheet: UUID? = nil

    private enum ActionID {
        static let keep = "ACTION_KEEP"
        static let selectCandidate1 = "ACTION_CANDIDATE_1"
        static let selectCandidate2 = "ACTION_CANDIDATE_2"
        static let openMapEdit = "ACTION_OPEN_MAP_EDIT"
        static let ignore = "ACTION_IGNORE"
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 通知権限のリクエスト
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("通知権限リクエストエラー: \(error.localizedDescription)")
            } else {
                print("通知権限ステータス: \(granted)")
            }
        }
    }

    /// 滞在ログ保存時にインタラクティブ通知（第2・第3候補の選択ボタン付き）を送信する
    func sendVisitRecordedNotification(for visit: VisitLog) async {
        // 自宅・仕事で通知オフ設定の場合はスキップ
        if (visit.lifeMode == .home || visit.lifeMode == .work) && !RegisteredPlacesStore.shared.notifyForBaseLocations {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        // この滞在ログ専用の動的カテゴリID（候補の店名をボタンに表示するため）
        let categoryID = "VISIT_CATEGORY_\(visit.id.uuidString)"
        var actions: [UNNotificationAction] = []

        // 1. そのまま記録ボタン
        actions.append(UNNotificationAction(
            identifier: ActionID.keep,
            title: "✅ このまま記録（\(visit.placeName)）",
            options: []
        ))

        // 2. 第2候補・第3候補があればボタンに追加（アプリを開かずに1タップ変更可能）
        let allCandidates = visit.candidates
        if allCandidates.count > 1 {
            let second = allCandidates[1]
            actions.append(UNNotificationAction(
                identifier: ActionID.selectCandidate1,
                title: "🔄 「\(second.name)」に変更",
                options: []
            ))
        }
        if allCandidates.count > 2 {
            let third = allCandidates[2]
            actions.append(UNNotificationAction(
                identifier: ActionID.selectCandidate2,
                title: "🔄 「\(third.name)」に変更",
                options: []
            ))
        }

        // 3. アプリを開いてマップで修正ボタン（.foreground でアプリを起動）
        actions.append(UNNotificationAction(
            identifier: ActionID.openMapEdit,
            title: "🗺️ アプリを開いてマップで修正...",
            options: [.foreground]
        ))

        // 4. 登録しない（破棄）ボタン（赤文字・バックグラウンド処理）
        actions.append(UNNotificationAction(
            identifier: ActionID.ignore,
            title: "🗑️ 登録しない（この滞在を破棄）",
            options: [.destructive]
        ))

        let dynamicCategory = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // 既存カテゴリを維持しつつ新しい動的カテゴリを登録
        let existingCategories = await center.notificationCategories()
        var updatedCategories = existingCategories
        updatedCategories.insert(dynamicCategory)
        center.setNotificationCategories(updatedCategories)

        // 通知コンテンツの作成
        let content = UNMutableNotificationContent()
        content.title = "📍 \(visit.placeName) に滞在中"
        content.subtitle = "\(visit.lifeMode.displayName)（\(visit.timeRangeString)）"
        content.body = "このまま自動で記録されます。変更や破棄をする場合は通知を長押ししてください。"
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = ["visitID": visit.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "VISIT_NOTIF_\(visit.id.uuidString)",
            content: content,
            trigger: nil // 即時配信
        )

        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// アプリがフォアグラウンド表示中でも画面上部に通知バナーを出す
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound]
    }

    /// 通知のアクションボタンまたは通知本体がタップされたときの処理
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let idString = userInfo["visitID"] as? String,
              let visitUUID = UUID(uuidString: idString) else {
            return
        }
        let actionIdentifier = response.actionIdentifier

        await MainActor.run {
            handleNotificationAction(actionID: actionIdentifier, visitID: visitUUID)
        }
    }

    private func handleNotificationAction(actionID: String, visitID: UUID) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<VisitLog>(
            predicate: #Predicate { $0.id == visitID }
        )
        guard let visit = try? context.fetch(descriptor).first else { return }

        switch actionID {
        case ActionID.keep:
            // 現在の1位店舗で確定（学習対象にする）
            visit.isManuallyEdited = true
            try? context.save()

        case ActionID.selectCandidate1:
            if visit.candidates.count > 1 {
                applyCandidate(visit.candidates[1], to: visit, context: context)
            }

        case ActionID.selectCandidate2:
            if visit.candidates.count > 2 {
                applyCandidate(visit.candidates[2], to: visit, context: context)
            }

        case ActionID.ignore:
            // 「登録しない」を選択：破棄フラグを立てて一覧・レポートから除外し、出発通知での復活も防ぐ
            visit.isIgnored = true
            try? context.save()

        case ActionID.openMapEdit, UNNotificationDefaultActionIdentifier:
            // 「マップで修正」または通知本体のタップ：アプリを開いて該当ログの詳細シートを直接表示
            visitIDToOpenInSheet = visit.id

        default:
            break
        }
    }

    private func applyCandidate(_ candidate: PlaceCandidate, to visit: VisitLog, context: ModelContext) {
        visit.placeName = candidate.name
        visit.rawCategory = candidate.rawCategory
        visit.lifeMode = candidate.lifeMode
        visit.latitude = candidate.latitude
        visit.longitude = candidate.longitude
        visit.isManuallyEdited = true
        try? context.save()
    }
}
