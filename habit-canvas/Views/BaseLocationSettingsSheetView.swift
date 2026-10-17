//
//  BaseLocationSettingsSheetView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import SwiftUI
import MapKit
import CoreLocation

struct BaseLocationSettingsSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RegisteredPlacesStore.shared

    enum TargetType: String, CaseIterable, Identifiable {
        case home = "🏠 自宅"
        case work = "🏢 仕事"
        var id: String { rawValue }
    }

    @State private var selectedTarget: TargetType = .home
    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapCenterCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 35.681236, longitude: 139.767125)

    var body: some View {
        NavigationStack {
            List {
                // 1. 現在の登録ステータス
                Section("現在の登録状態") {
                    registeredRow(
                        title: "🏠 自宅 (半径\(Int(store.homeRadiusMeters))m)",
                        coordinate: store.homeCoordinate,
                        onFocus: { focusMap(on: $0) },
                        onClear: { store.homeCoordinate = nil }
                    )

                    registeredRow(
                        title: "🏢 仕事 (半径\(Int(store.workRadiusMeters))m)",
                        coordinate: store.workCoordinate,
                        onFocus: { focusMap(on: $0) },
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
                        .onMapCameraChange(frequency: .onEnd) { context in
                            mapCenterCoordinate = context.region.center
                        }
                        .frame(height: 280)

                        // 中央の照準（＋）
                        Image(systemName: "plus.viewfinder")
                            .font(.title)
                            .foregroundStyle(.red)
                            .allowsHitTesting(false)

                        // 下部の登録ボタン
                        VStack {
                            Spacer()
                            Button {
                                registerCurrentMapCenter()
                            } label: {
                                Label("マップ中央（＋）を「\(selectedTarget.rawValue)」に登録", systemImage: "mappin.and.ellipse")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                                    .shadow(radius: 2)
                            }
                            .padding(.bottom, 12)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("位置の登録・更新")
                } footer: {
                    Text("登録された範囲内の滞在は、具体的な住所や近隣店舗名を表示せず、シンプルに「自宅」「仕事」として自動記録されます。")
                }
            }
            .navigationTitle("自宅・仕事の事前登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                    .bold()
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
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 250,
            longitudinalMeters: 250
        ))
    }

    private func registerCurrentMapCenter() {
        switch selectedTarget {
        case .home:
            store.homeCoordinate = mapCenterCoordinate
        case .work:
            store.workCoordinate = mapCenterCoordinate
        }
    }
}
