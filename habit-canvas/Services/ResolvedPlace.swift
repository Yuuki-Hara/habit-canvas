//
//  ResolvedPlace.swift
//  habit-canvas
//
//  Created by 原裕貴 on 2026/10/16.
//


import Foundation
import MapKit
import CoreLocation

struct ResolvedPlace {
    let name: String
    let category: String
}

enum PlaceResolver {
    /// 緯度・経度から半径50m以内の最も近い施設名とMapKitカテゴリを取得する
    static func resolve(coordinate: CLLocationCoordinate2D) async -> ResolvedPlace {
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        // 1. 半径50m以内のPOI（興味のある地点・施設）をリクエスト
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: 50.0)
        let search = MKLocalSearch(request: request)
        
        do {
            let response = try await search.start()
            
            // 最も距離が近い施設（MKMapItem）を探す
            let closestItem = response.mapItems.min { itemA, itemB in
                let locA = itemA.location
                let locB = itemB.location
                return targetLocation.distance(from: locA) < targetLocation.distance(from: locB)
            }
            
            if let item = closestItem, let name = item.name {
                let rawCat = item.pointOfInterestCategory?.rawValue ?? "カテゴリなし（POI）"
                return ResolvedPlace(name: name, category: rawCat)
            }
        } catch {
            // 周辺に店舗が1件もない場合やエラー時は下のフォールバックへ進む
            print("POI検索結果なし、住所検索へフォールバックします: \(error.localizedDescription)")
        }
        
        // 2. フォールバック：周囲50mにお店がない場合（自宅・住宅街など）は住所を取得
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(targetLocation)
            if let pm = placemarks.first {
                let locality = pm.locality ?? ""
                let subLocality = pm.subLocality ?? ""
                let thoroughfare = pm.thoroughfare ?? ""
                let address = [locality, subLocality, thoroughfare].joined()
                let finalName = address.isEmpty ? "不明な場所" : "\(address) 付近"
                return ResolvedPlace(name: finalName, category: "カテゴリなし（住宅・その他）")
            }
        } catch {
            print("逆ジオコーディング失敗: \(error.localizedDescription)")
        }
        
        return ResolvedPlace(name: "特定できない場所", category: "不明")
    }
}
