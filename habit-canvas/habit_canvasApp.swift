//
//  habit_canvasApp.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//

import SwiftUI
import SwiftData

@main
struct HabitCanvasPoCApp: App {
    let container: ModelContainer
    @StateObject private var locationService: LocationService

    init() {
        do {
            let schema = Schema([VisitLog.self])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
            self.container = modelContainer
            
            let service = LocationService(modelContext: modelContainer.mainContext)
            _locationService = StateObject(wrappedValue: service)
        } catch {
            fatalError("SwiftDataの初期化に失敗しました: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView() // ← ここを MainTabView() に変更
                .environmentObject(locationService)
        }
        .modelContainer(container)
    }
}