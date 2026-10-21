//
//  MainTabView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var locationService: LocationService

    var body: some View {
        TabView {
            DailyLogPageView()
                .tabItem {
                    Label("デイリーログ", systemImage: "mappin.and.ellipse")
                }

            ReportPageView()
                .tabItem {
                    Label("レポート", systemImage: "chart.bar.fill")
                }
        }
        // ここで下位のタブ全体に伝播させる
        .environmentObject(locationService)
    }
}
