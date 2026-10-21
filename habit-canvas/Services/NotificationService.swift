//
//  NotificationService.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/20.
//


import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    enum ActionID {
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

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendVisitRecordedNotification(for visit: VisitLog) async {
        if (visit.lifeMode == .home || visit.lifeMode == .work) && !RegisteredPlacesStore.shared.notifyForBaseLocations {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let categoryID = "VISIT_CATEGORY_\(visit.id.uuidString)"
        var actions: [UNNotificationAction] = []

        actions.append(UNNotificationAction(identifier: ActionID.keep, title: "✅ このまま記録（\(visit.placeName)）", options: []))

        let allCandidates = visit.candidates
        if allCandidates.count > 1 {
            let second = allCandidates[1]
            actions.append(UNNotificationAction(identifier: ActionID.selectCandidate1, title: "🔄 「\(second.name)」に変更", options: []))
        }
        if allCandidates.count > 2 {
            let third = allCandidates[2]
            actions.append(UNNotificationAction(identifier: ActionID.selectCandidate2, title: "🔄 「\(third.name)」に変更", options: []))
        }

        actions.append(UNNotificationAction(identifier: ActionID.openMapEdit, title: "🗺️ アプリを開いてマップで修正...", options: [.foreground]))
        actions.append(UNNotificationAction(identifier: ActionID.ignore, title: "🗑️ 登録しない（この滞在を破棄）", options: [.destructive]))

        let dynamicCategory = UNNotificationCategory(identifier: categoryID, actions: actions, intentIdentifiers: [], options: [])
        let existingCategories = await center.notificationCategories()
        var updatedCategories = existingCategories
        updatedCategories.insert(dynamicCategory)
        center.setNotificationCategories(updatedCategories)

        let content = UNMutableNotificationContent()
        content.title = "📍 \(visit.placeName) に滞在中"
        content.subtitle = "\(visit.lifeMode.displayName)（\(visit.timeRangeString)）"
        content.body = "このまま自動で記録されます。変更や破棄をする場合は通知を長押ししてください。"
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.userInfo = ["visitID": visit.id.uuidString]

        let request = UNNotificationRequest(identifier: "VISIT_NOTIF_\(visit.id.uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound]
    }

    /// 通知のアクションが押されたとき（NotificationCenterで安全にメインスレッドへブロードキャスト）
    @MainActor
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let idString = userInfo["visitID"] as? String,
              let visitUUID = UUID(uuidString: idString) else {
            return
        }
        let actionIdentifier = response.actionIdentifier

        NotificationCenter.default.post(
            name: NSNotification.Name("DidReceiveNotificationAction"),
            object: nil,
            userInfo: ["actionID": actionIdentifier, "visitID": visitUUID]
        )
    }
}
