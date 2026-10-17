//
//  ResolvedPlaceResult.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/17.
//


import Foundation
import MapKit
import CoreLocation

struct ResolvedPlaceResult {
    let primaryName: String
    let primaryCategory: String
    let majorityLifeMode: LifeMode
    let candidates: [PlaceCandidate]
    let isMatchedFromHistory: Bool
}

struct LearnedPlaceSnapshot: Sendable {
    let placeName: String
    let rawCategory: String
    let lifeMode: LifeMode
    let latitude: Double
    let longitude: Double
}

enum PlaceResolver {
    private static let excludedNoiseCategories: [MKPointOfInterestCategory] = [
        .atm,
        .parking,
        .restroom,
        .evCharger,
        .publicTransport,
        .carRental,
        .gasStation
    ]

    /// 0.自宅/仕事の登録判定 → 1.過去の手動修正履歴 → 2.MapKit検索(ノイズ除外+多数決) → 3.住所フォールバック の順で特定する
    @MainActor
    static func resolve(
        coordinate: CLLocationCoordinate2D,
        learnedPlaces: [LearnedPlaceSnapshot] = []
    ) async -> ResolvedPlaceResult {
        // 0. 【最優先】設定で事前登録された「自宅」「仕事」のエリア内か判定
        if let registered = RegisteredPlacesStore.shared.matchRegisteredMode(for: coordinate) {
            let label = registered.mode.rawValue // "自宅" または "仕事"（具体的な住所や店名は出さない）
            let registeredCandidate = PlaceCandidate(
                name: label,
                rawCategory: "登録スポット",
                lifeModeRaw: registered.mode.rawValue,
                distanceMeters: registered.distance,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            return ResolvedPlaceResult(
                primaryName: label,
                primaryCategory: "登録スポット",
                majorityLifeMode: registered.mode,
                candidates: [registeredCandidate],
                isMatchedFromHistory: true
            )
        }

        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // 1. 【学習ロジック】過去に手動修正した場所（半径40m以内）があればチェック
        let matchedLearnedPlace = learnedPlaces
            .map { place -> (place: LearnedPlaceSnapshot, distance: Double) in
                let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                return (place, targetLocation.distance(from: loc))
            }
            .filter { $0.distance <= 40.0 }
            .min { $0.distance < $1.distance }

        // 2. MapKitで周辺60m以内のPOI（ノイズ除外フィルター付き）を検索
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 60.0)
        request.pointOfInterestFilter = MKPointOfInterestFilter(excluding: excludedNoiseCategories)
        
        let search = MKLocalSearch(request: request)
        var mapKitCandidates: [PlaceCandidate] = []

        do {
            let response = try await search.start()
            
            mapKitCandidates = response.mapItems
                .compactMap { item -> PlaceCandidate? in
                    guard let name = item.name else { return nil }
                    if let cat = item.pointOfInterestCategory, excludedNoiseCategories.contains(cat) {
                        return nil
                    }
                    
                    let itemLoc = item.placemark.location ?? targetLocation
                    let dist = targetLocation.distance(from: itemLoc)
                    let rawCat = item.pointOfInterestCategory?.rawValue ?? "カテゴリなし（POI）"
                    let mode = LifeMode.classify(rawCategory: item.pointOfInterestCategory?.rawValue)
                    
                    return PlaceCandidate(
                        name: name,
                        rawCategory: rawCat,
                        lifeModeRaw: mode.rawValue,
                        distanceMeters: dist,
                        latitude: itemLoc.coordinate.latitude,
                        longitude: itemLoc.coordinate.longitude
                    )
                }
                .sorted { $0.distanceMeters < $1.distanceMeters }
        } catch {
            print("POI検索結果なし（または失敗）: \(error.localizedDescription)")
        }

        // 3. 半径40m以内に過去の手動修正履歴があれば1位に採用
        if let learned = matchedLearnedPlace {
            let learnedCandidate = PlaceCandidate(
                name: learned.place.placeName,
                rawCategory: learned.place.rawCategory,
                lifeModeRaw: learned.place.lifeMode.rawValue,
                distanceMeters: learned.distance,
                latitude: learned.place.latitude,
                longitude: learned.place.longitude
            )
            let otherCandidates = mapKitCandidates.filter { $0.name != learned.place.placeName }
            let combinedCandidates = Array(([learnedCandidate] + otherCandidates).prefix(8))
            
            return ResolvedPlaceResult(
                primaryName: learned.place.placeName,
                primaryCategory: learned.place.rawCategory,
                majorityLifeMode: learned.place.lifeMode,
                candidates: combinedCandidates,
                isMatchedFromHistory: true
            )
        }

        // 4. 新規の場所：MapKit候補から上位5件の多数決でライフモードを決定
        let topCandidates = Array(mapKitCandidates.prefix(8))
        if let closest = topCandidates.first {
            let top5Modes = topCandidates.prefix(5).map { $0.lifeMode }
            let majorityMode = calculateMajorityLifeMode(from: top5Modes, fallback: closest.lifeMode)
            
            return ResolvedPlaceResult(
                primaryName: closest.name,
                primaryCategory: closest.rawCategory,
                majorityLifeMode: majorityMode,
                candidates: topCandidates,
                isMatchedFromHistory: false
            )
        }

        // 5. フォールバック：周囲に施設がない場所（未登録の住宅街など）は「その他」として住所を表示
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(targetLocation)
            if let pm = placemarks.first {
                let address = [pm.locality, pm.subLocality, pm.thoroughfare].compactMap { $0 }.joined()
                let finalName = address.isEmpty ? "不明な場所" : "\(address) 付近"
                let fallbackCandidate = PlaceCandidate(
                    name: finalName,
                    rawCategory: "住所（施設なし）",
                    lifeModeRaw: LifeMode.other.rawValue,
                    distanceMeters: 0,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                return ResolvedPlaceResult(
                    primaryName: finalName,
                    primaryCategory: "住所（施設なし）",
                    majorityLifeMode: .other,
                    candidates: [fallbackCandidate],
                    isMatchedFromHistory: false
                )
            }
        } catch {
            print("逆ジオコーディング失敗: \(error.localizedDescription)")
        }

        return ResolvedPlaceResult(
            primaryName: "特定できない場所",
            primaryCategory: "不明",
            majorityLifeMode: .other,
            candidates: [],
            isMatchedFromHistory: false
        )
    }

    private static func calculateMajorityLifeMode(from modes: [LifeMode], fallback: LifeMode) -> LifeMode {
        guard !modes.isEmpty else { return fallback }
        var counts: [LifeMode: Int] = [:]
        for mode in modes {
            counts[mode, default: 0] += 1
        }
        let maxCount = counts.values.max() ?? 0
        if counts[fallback] == maxCount {
            return fallback
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? fallback
    }
}