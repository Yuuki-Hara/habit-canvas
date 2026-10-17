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
    let isMatchedFromHistory: Bool // 過去の学習履歴から一致したかどうか
}

/// 過去の「手動修正済みログ」をPlaceResolverに渡すための軽量構造体
struct LearnedPlaceSnapshot: Sendable {
    let placeName: String
    let rawCategory: String
    let lifeMode: LifeMode
    let latitude: Double
    let longitude: Double
}

enum PlaceResolver {
    /// 滞在目的になりにくい「ノイズ施設」の除外リスト
    private static let excludedNoiseCategories: [MKPointOfInterestCategory] = [
        .atm,               // ATM
        .parking,           // コインパーキング・駐車場
        .restroom,          // 公衆トイレ
        .evCharger,         // EV充電器
        .publicTransport,   // バス停・駅の出口など（店舗を優先するため除外）
        .carRental,         // レンタカーポート
        .gasStation         // ガソリンスタンド
    ]

    /// 過去の手動修正データを最優先し、新規の場所ではノイズ除外＋多数決で特定する
    static func resolve(
        coordinate: CLLocationCoordinate2D,
        arrivalDate: Date = .now,
        learnedPlaces: [LearnedPlaceSnapshot] = []
    ) async -> ResolvedPlaceResult {
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // 1. 【学習ロジック】過去に手動修正した場所（半径40m以内）があれば最優先でチェック
        let matchedLearnedPlace = learnedPlaces
            .map { place -> (place: LearnedPlaceSnapshot, distance: Double) in
                let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
                return (place, targetLocation.distance(from: loc))
            }
            .filter { $0.distance <= 40.0 } // 半径40m以内
            .min { $0.distance < $1.distance } // 複数あれば一番近い学習データ

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
                    // 念のため、フィルターをすり抜けたノイズカテゴリも二重チェックで弾く
                    if let cat = item.pointOfInterestCategory, excludedNoiseCategories.contains(cat) {
                        return nil
                    }
                    
                    let itemLoc = item.placemark.location ?? targetLocation
                    let dist = targetLocation.distance(from: itemLoc)
                    let rawCat = item.pointOfInterestCategory?.rawValue ?? "カテゴリなし（POI）"
                    let mode = LifeMode.classify(rawCategory: item.pointOfInterestCategory?.rawValue, arrivalDate: arrivalDate)
                    
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

        // 3. もし半径40m以内に「過去の手動修正履歴」が見つかっていた場合は、それを無条件で1位に採用！
        if let learned = matchedLearnedPlace {
            print("✨ 過去の学習データにヒットしました: \(learned.place.placeName) (距離: \(Int(learned.distance))m)")
            let learnedCandidate = PlaceCandidate(
                name: learned.place.placeName,
                rawCategory: learned.place.rawCategory,
                lifeModeRaw: learned.place.lifeMode.rawValue,
                distanceMeters: learned.distance,
                latitude: learned.place.latitude,
                longitude: learned.place.longitude
            )
            
            // 候補リストの先頭に学習データを入れ、残りにMapKitの候補（重複除く）を並べる
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

        // 4. 学習データにない新規の場所：MapKitの候補リストから上位5件の多数決で決定
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

        // 5. フォールバック：周囲に店舗がない場合（住宅街など）は逆ジオコーディングで住所を取得
        let geocoder = CLGeocoder()
        let heuristicMode = LifeMode.classifyByTimeHeuristics(arrivalDate: arrivalDate)
        
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(targetLocation)
            if let pm = placemarks.first {
                let address = [pm.locality, pm.subLocality, pm.thoroughfare].compactMap { $0 }.joined()
                let finalName = address.isEmpty ? "不明な場所" : "\(address) 付近"
                let fallbackCandidate = PlaceCandidate(
                    name: finalName,
                    rawCategory: "住所（施設なし）",
                    lifeModeRaw: heuristicMode.rawValue,
                    distanceMeters: 0,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                )
                return ResolvedPlaceResult(
                    primaryName: finalName,
                    primaryCategory: "住所（施設なし）",
                    majorityLifeMode: heuristicMode,
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
            majorityLifeMode: heuristicMode,
            candidates: [],
            isMatchedFromHistory: false
        )
    }

    /// ライフモード配列の中から最も多いものを返す（同数の場合は1位の店舗のモードを優先）
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