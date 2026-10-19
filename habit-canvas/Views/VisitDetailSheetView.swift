//
//  VisitDetailSheetView.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import SwiftUI
import MapKit
import SwiftData

struct VisitDetailSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var visit: VisitLog

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapCenterCoordinate: CLLocationCoordinate2D = .init()
    @State private var isSearchingAtNewCenter: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // 1. マップ操作 ＆ ピン位置再検索セクション
                Section {
                    ZStack {
                        Map(position: $cameraPosition) {
                            Marker(visit.placeName, coordinate: visit.coordinate)
                                .tint(.red)
                        }
                        .onMapCameraChange(frequency: .onEnd) { context in
                            mapCenterCoordinate = context.region.center
                        }
                        .frame(height: 220)

                        Image(systemName: "plus.viewfinder")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .allowsHitTesting(false)

                        VStack {
                            Spacer()
                            Button {
                                Task {
                                    await searchCandidatesAtMapCenter()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if isSearchingAtNewCenter {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise.circle.fill")
                                    }
                                    Text("マップ中央の位置で候補を再検索")
                                        .font(.caption.bold())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(radius: 2)
                            }
                            .disabled(isSearchingAtNewCenter)
                            .padding(.bottom, 10)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("位置の確認・マップ操作で補正")
                } footer: {
                    Text("地図をドラッグして中央の照準（＋）を実際の建物に合わせ、「候補を再検索」を押すと下の候補リストが更新されます。")
                }

                // 2. ライフモードの手動切り替えセクション
                Section("ライフモード（タップで直接変更）") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(LifeMode.allCases) { mode in
                                let isSelected = visit.lifeMode == mode
                                Button {
                                    visit.lifeMode = mode
                                    visit.isManuallyEdited = true
                                    try? modelContext.save()
                                } label: {
                                    Text(mode.displayName)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(isSelected ? Color.orange : Color(.tertiarySystemFill))
                                        .foregroundStyle(isSelected ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 3. 近くの建物候補リストから選択セクション
                Section("近くの施設候補から選択（タップで反映）") {
                    if visit.candidates.isEmpty {
                        Text("周辺に候補施設が見つかりませんでした。マップを動かして再検索してみてください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visit.candidates) { candidate in
                            let isCurrentSelection = (visit.placeName == candidate.name)
                            Button {
                                applyCandidate(candidate)
                            } label: {
                                HStack {
                                    Image(systemName: isCurrentSelection ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isCurrentSelection ? .blue : .secondary)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.name)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 6) {
                                            Text(candidate.lifeMode.displayName)
                                                .font(.caption2.bold())
                                                .foregroundStyle(.orange)
                                            Text(candidate.rawCategory)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    Spacer()

                                    Text(String(format: "%.0fm", candidate.distanceMeters))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                // 4. 現在の判定データ・生データ
                Section("記録されている生データ") {
                    LabeledContent("店名・施設名", value: visit.placeName)
                    LabeledContent("MapKitカテゴリ") {
                        Text(visit.rawCategory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                    LabeledContent("緯度 / 経度") {
                        Text(String(format: "%.6f, %.6f", visit.latitude, visit.longitude))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("採用された水平誤差", value: String(format: "±%.1f m", visit.horizontalAccuracy))
                }

                // 5. 削除ボタンセクション
                Section {
                    Button(role: .destructive) {
                        modelContext.delete(visit)
                        try? modelContext.save()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("この滞在ログを削除", systemImage: "trash")
                                .font(.body.bold())
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("滞在ログ詳細・補正")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                let coord = visit.coordinate
                mapCenterCoordinate = coord
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 140,
                    longitudinalMeters: 140
                ))
            }
        }
    }

    private func applyCandidate(_ candidate: PlaceCandidate) {
        visit.placeName = candidate.name
        visit.rawCategory = candidate.rawCategory
        visit.lifeMode = candidate.lifeMode
        visit.latitude = candidate.latitude
        visit.longitude = candidate.longitude
        visit.isManuallyEdited = true
        try? modelContext.save()

        cameraPosition = .region(MKCoordinateRegion(
            center: visit.coordinate,
            latitudinalMeters: 140,
            longitudinalMeters: 140
        ))
    }

    private func searchCandidatesAtMapCenter() async {
        isSearchingAtNewCenter = true
        defer { isSearchingAtNewCenter = false }

        let resolved = await PlaceResolver.resolve(coordinate: mapCenterCoordinate)
        visit.latitude = mapCenterCoordinate.latitude
        visit.longitude = mapCenterCoordinate.longitude
        visit.placeName = resolved.primaryName
        visit.rawCategory = resolved.primaryCategory
        visit.lifeMode = resolved.majorityLifeMode
        visit.candidates = resolved.candidates
        visit.isManuallyEdited = true
        try? modelContext.save()
    }
}