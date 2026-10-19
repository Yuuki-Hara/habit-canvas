//
//  BaseLocationSettingsSheetView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import SwiftUI
import MapKit
import CoreLocation
import SwiftData

struct BaseLocationSettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RegisteredPlacesStore.shared
    @Query(sort: \CLVisitDebugLog.receivedAt, order: .reverse) private var debugLogs: [CLVisitDebugLog]
    @FocusState private var isMinutesFieldFocused: Bool

    enum TargetType: String, CaseIterable, Identifiable {
        case home = "🏠 自宅"
        case work = "🏢 仕事"
        var id: String { rawValue }
    }

    @State private var selectedTarget: TargetType = .home
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapCenterCoordinate: CLLocationCoordinate2D? = nil
    @State private var duplicateWarningMessage: String? = nil

    var body: some View {
        NavigationStack {
            List {
                // 0. 【追加】デバッグ設定 ＆ CLVisit生ログ確認セクション
                Section {
                    HStack {
                        Label("最小滞在時間", systemImage: "timer")
                            .font(.subheadline.bold())

                        Spacer()

                        TextField("分", value: $store.minimumStayMinutes, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 55)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(.tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .focused($isMinutesFieldFocused)

                        Text("分以上")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Stepper("", value: $store.minimumStayMinutes, in: 0...180, step: 1)
                            .labelsHidden()
                    }

                    NavigationLink {
                        CLVisitDebugLogListView()
                    } label: {
                        HStack {
                            Label("CLVisit 受信ログを確認", systemImage: "list.bullet.rectangle.portrait")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(debugLogs.count)件")
                                .font(.caption.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                } header: {
                    Text("デバッグ・滞在判定設定")
                } footer: {
                    Text("現在設定: \(store.minimumStayMinutes)分（\(Int(store.minimumStayDurationSeconds))秒）未満の立ち止まりは自動記録から除外されます。0分にするとすべての確定滞在を記録します。")
                }

                // 1. 現在の登録ステータス
                Section("自宅・仕事の登録状態") {
                    registeredRow(
                        title: "🏠 自宅 (半径\(Int(store.homeRadiusMeters))m)",
                        coordinate: store.homeCoordinate,
                        onFocus: {
                            selectedTarget = .home
                            focusMap(on: $0)
                        },
                        onClear: { store.homeCoordinate = nil }
                    )

                    registeredRow(
                        title: "🏢 仕事 (半径\(Int(store.workRadiusMeters))m)",
                        coordinate: store.workCoordinate,
                        onFocus: {
                            selectedTarget = .work
                            focusMap(on: $0)
                        },
                        onClear: { store.workCoordinate = nil }
                    )
                }

                // 2. マップ操作で登録するセクション
                Section {
                    Picker("登録する対象", selection: $selectedTarget) {
                        ForEach(TargetType.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                    .onChange(of: selectedTarget) { _, newTarget in
                        duplicateWarningMessage = nil
                        switch newTarget {
                        case .home:
                            if let home = store.homeCoordinate { focusMap(on: home) }
                        case .work:
                            if let work = store.workCoordinate { focusMap(on: work) }
                        }
                    }

                    ZStack {
                        Map(position: $cameraPosition) {
                            UserAnnotation()

                            if let home = store.homeCoordinate {
                                Marker("自宅", coordinate: home)
                                    .tint(.green)
                                MapCircle(center: home, radius: store.homeRadiusMeters)
                                    .foregroundStyle(.green.opacity(0.2))
                            }

                            if let work = store.workCoordinate {
                                Marker("仕事", coordinate: work)
                                    .tint(.blue)
                                MapCircle(center: work, radius: store.workRadiusMeters)
                                    .foregroundStyle(.blue.opacity(0.2))
                            }
                        }
                        .onMapCameraChange(frequency: .continuous) { context in
                            mapCenterCoordinate = context.region.center
                        }
                        .frame(height: 280)

                        Image(systemName: "plus.viewfinder")
                            .font(.title)
                            .foregroundStyle(selectedTarget == .home ? .green : .blue)
                            .allowsHitTesting(false)

                        VStack {
                            if let center = mapCenterCoordinate {
                                Text(String(format: "照準座標: %.5f, %.5f", center.latitude, center.longitude))
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .padding(.top, 8)
                            }
                            Spacer()

                            Button {
                                registerCurrentMapCenter()
                            } label: {
                                Label(
                                    "マップ中央（＋）を「\(selectedTarget.rawValue)」に登録",
                                    systemImage: "mappin.and.ellipse"
                                )
                                .font(.caption.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(selectedTarget == .home ? Color.green : Color.blue)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                                .shadow(radius: 3)
                            }
                            .buttonStyle(.plain)
                            .disabled(mapCenterCoordinate == nil)
                            .padding(.bottom, 12)
                        }
                    }
                    .listRowInsets(EdgeInsets())

                    if let warning = duplicateWarningMessage {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("位置の登録・更新（現在選択中: \(selectedTarget.rawValue)）")
                } footer: {
                    Text("1. 上のタブで「🏠 自宅」か「🏢 仕事」を選びます。\n2. 地図を動かして中央の「＋」を実際の建物に合わせ、下の登録ボタンを押してください。")
                }
            }
            .navigationTitle("設定・デバッグ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        isMinutesFieldFocused = false
                        dismiss()
                    }
                    .bold()
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") {
                        isMinutesFieldFocused = false
                    }
                }
            }
            .onAppear {
                if let home = store.homeCoordinate {
                    focusMap(on: home)
                } else {
                    cameraPosition = .userLocation(fallback: .automatic)
                }
            }
        }
    }

    @ViewBuilder
    private func registeredRow(
        title: String,
        coordinate: CLLocationCoordinate2D?,
        onFocus: @escaping (CLLocationCoordinate2D) -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                if let coord = coordinate {
                    Text(String(format: "登録済 (%.5f, %.5f)", coord.latitude, coord.longitude))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green)
                } else {
                    Text("未登録")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let coord = coordinate {
                Button("地図で見る") {
                    onFocus(coord)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    onClear()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func focusMap(on coordinate: CLLocationCoordinate2D) {
        mapCenterCoordinate = coordinate
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 250,
            longitudinalMeters: 250
        ))
    }

    private func registerCurrentMapCenter() {
        guard let center = mapCenterCoordinate else { return }
        duplicateWarningMessage = nil

        switch selectedTarget {
        case .home:
            if let work = store.workCoordinate {
                let dist = CLLocation(latitude: center.latitude, longitude: center.longitude)
                    .distance(from: CLLocation(latitude: work.latitude, longitude: work.longitude))
                if dist < 30 {
                    duplicateWarningMessage = "⚠️ 「仕事」の登録位置と非常に近い場所（\(Int(dist))m）が登録されました。"
                }
            }
            store.homeCoordinate = center

        case .work:
            if let home = store.homeCoordinate {
                let dist = CLLocation(latitude: center.latitude, longitude: center.longitude)
                    .distance(from: CLLocation(latitude: home.latitude, longitude: home.longitude))
                if dist < 30 {
                    duplicateWarningMessage = "⚠️ 「自宅」の登録位置と非常に近い場所（\(Int(dist))m）が登録されました。地図を動かして職場の位置に合わせてください。"
                }
            }
            store.workCoordinate = center
        }
    }
}
