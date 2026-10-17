# 機能検証用アプリ（habit-canvas-poc）詳細設計書

## 1. 検証の目的とスコープ

本番アプリ（`habit-canvas`）の開発に先立ち、コア技術である「実位置情報を用いた滞在検知（`CLVisit`）」および「座標からの店名・カテゴリ特定（`MapKit`）」の精度を実機で検証するための最小構成アプリ（PoC）を定義する。

### 実装する検証機能

- 実際の位置情報（GPS / `CLVisit`）を取得し、滞在場所を端末内に記録する。
- 日付ごとのページ切り替え機能を持つ。
- 選択した日付の滞在場所をマップ上のピンとして表示する。
- 選択した日付の滞在場所一覧をカード形式で縦に並べて表示する。
- カードを押下すると詳細画面（モーダル）が立ち上がり、「店名」「MapKitカテゴリ」「緯度・経度」などの生データを確認できる。

---

## 2. ファイル構成（ディレクトリ構造）

- **ターゲット環境:** iOS 17.0以降
- **使用フレームワーク:** SwiftUI, SwiftData, CoreLocation, MapKit

```text
HabitCanvasPoC/
├── HabitCanvasPoCApp.swift          # アプリのエントリーポイント・SwiftData初期化
├── Info.plist                       # 位置情報・バックグラウンド権限の定義
│
├── Models/
│   └── VisitLog.swift               # 滞在記録のデータモデル（SwiftData）
│
├── Services/
│   ├── LocationService.swift        # CLVisitの監視・現在地取得の制御
│   └── PlaceResolver.swift          # 緯度経度から店名・MapKitカテゴリを特定する処理
│
└── Views/
    ├── DailyLogPageView.swift       # 【メイン画面】日付切替 ＋ マップ ＋ カード一覧
    ├── Components/
    │   ├── DateHeaderView.swift     # 日付切り替えバー（＜ 2026/10/16 ＞）
    │   ├── DailyMapView.swift       # その日の滞在ピンを表示するマップビュー
    │   └── VisitCardView.swift      # 縦に並ぶ滞在場所のカードUI
    └── VisitDetailSheetView.swift   # 【詳細画面】カード押下時に立ち上がるシート
```

---

## 3. データモデル設計 (`Models/VisitLog.swift`)

SwiftDataの `@Model` マクロを使用し、取得した滞在履歴を端末内に永続化する。

| プロパティ名         | 型       | 説明                                                    |
| :------------------- | :------- | :------------------------------------------------------ |
| `id`                 | `UUID`   | 一意の識別子（初期値: `UUID()`）                        |
| `arrivalDate`        | `Date`   | 到着日時（※日付ごとのページ絞り込み基準に使用）         |
| `departureDate`      | `Date?`  | 出発日時（滞在中で未確定の場合は `nil`）                |
| `latitude`           | `Double` | 緯度                                                    |
| `longitude`          | `Double` | 経度                                                    |
| `horizontalAccuracy` | `Double` | 位置情報の誤差半径（メートル）※精度検証用               |
| `placeName`          | `String` | MapKitから取得した店名・施設名                          |
| `rawCategory`        | `String` | MapKitの公式カテゴリ文字列（例: `"MKPOICategoryCafe"`） |

---

## 4. サービス（裏側のロジック）詳細設計

### 4.1 `LocationService.swift`（位置情報・滞在検知エンジン）

`CLLocationManager` を管理し、バックグラウンドでの滞在検知と検証用の手動記録を行う。

- **権限リクエスト処理:**
  - 初回起動時に `requestWhenInUseAuthorization()`（使用中のみ許可）を実行。
  - 許可された後、`requestAlwaysAuthorization()`（常に許可）への昇格をリクエストする。
- **本番用の滞在監視 (`startMonitoringVisits`):**
  - `manager.startMonitoringVisits()` を呼び出し、OSによる省電力の滞在監視を開始する。
  - `locationManager(_:didVisit:)` デリゲートが発火したら、受け取った `CLVisit` の座標を `PlaceResolver` に渡して店名・カテゴリを取得し、`VisitLog` として `ModelContext`（SwiftData）へ保存する。
  - ※ `CLVisit.departureDate` が `Date.distantFuture` と等しい場合は `departureDate = nil` として保存する。
- **検証用の即時記録機能 (`recordCurrentLocationForTest`):**
  - 実際の `CLVisit` は15〜20分以上の滞在がないと発火しないため、移動中や開発中に即座にテストできるよう、`requestLocation()` で現在のGPS座標を1回取得し、擬似的に滞在ログとして保存するデバッグ用メソッドを用意する。

### 4.2 `PlaceResolver.swift`（MapKit 店名・カテゴリ特定）

緯度・経度から、最も近い施設の「店名」と「MapKitカテゴリ」を非同期（`async/await`）で取得する。

- **POI（施設）検索ステップ:**
  1. 受け取った緯度・経度を中心に、半径50mの `MKLocalPointsOfInterestRequest` を生成する。
  2. `MKLocalSearch(request:)` を実行し、周辺の `MKMapItem` 配列を取得する。
  3. 取得した候補の中から、元の滞在座標との距離（`CLLocation.distance(from:)`）が最も近い `MKMapItem` を1つ選択する。
  4. そのアイテムの `name`（店名）と `pointOfInterestCategory?.rawValue`（カテゴリ文字列）を返却する。
- **フォールバック処理（周辺に店舗がない場合）:**
  - 半径50m以内にPOIが見つからなかった場合（自宅や住宅街など）は、`CLGeocoder().reverseGeocodeLocation()` を実行する。
  - 取得した住所（例: `"〇〇区〇〇"`）を `placeName` にセットし、`rawCategory` には `"カテゴリなし（住宅・その他）"` をセットして返却する。

---

## 5. 画面（UI）詳細設計

### 5.1 `DailyLogPageView.swift`（日付ごとページ・メイン画面）

1画面で選択日の「地図」と「滞在カード一覧」を確認できる画面。

- **レイアウト構成:**

```text
+---------------------------------------+
|  [＜]    2026年10月16日 (金)    [＞]  |  <-- DateHeaderView（日付切替）
+---------------------------------------+
|                                       |
|        🗺️ マップビュー (高さ240pt)     |  <-- DailyMapView（滞在ピン表示）
|           [📍]       [📍]             |
|                                       |
+---------------------------------------+
|  📋 滞在場所一覧 (2件)    [+ 現在地記録]|  <-- デバッグ用即時記録ボタンを配置
|  +---------------------------------+  |
|  | 10:15 - 11:30                   |  |
|  | スターバックス 〇〇店         ＞|  |  <-- VisitCardView（カード一覧）
|  | 🏷️ MKPOICategoryCafe            |  |
|  +---------------------------------+  |
|  | 12:00 - 13:10                   |  |
|  | 〇〇食堂                      ＞|  |
|  | 🏷️ MKPOICategoryRestaurant      |  |
|  +---------------------------------+  |
+---------------------------------------+
```

- **状態管理とフィルタリング:**
  - `@State private var selectedDate: Date = .now` を保持する。
  - `Calendar.current.startOfDay(for: selectedDate)` から翌日0時までの範囲に `arrivalDate` が含まれる `VisitLog` を到着時刻順（昇順）で抽出し、マップとカード一覧に渡す。
- **各コンポーネントの役割:**
  - **`DateHeaderView`:** 左右のボタンで `selectedDate` を1日ずつ増減させる。日付テキスト部分を `DatePicker` にし、カレンダーから任意の日付へ移動可能にする。
  - **`DailyMapView`:** SwiftUIの `Map` を使用。抽出された `VisitLog` の座標に `Marker(visit.placeName, coordinate: ...)` をピン表示する。
  - **`VisitCardView`:** 到着〜出発時刻、店名、`rawCategory` をカード形式で表示する。タップ時に `selectedVisit` に自身をセットし、詳細シート（`.sheet(item: $selectedVisit)`）を起動する。

### 5.2 `VisitDetailSheetView.swift`（カード押下時の詳細画面）

カード押下時にモーダル表示され、取得データの精度を検証するための詳細画面。

- **表示項目:**
  1. **個別ズームマップ:** 選択された滞在場所の座標を中心にズームした `Map`（高さ200pt）を表示し、実際の建物とGPS座標のズレを確認できるようにする。
  2. **基本情報セクション:**
     - **店名 (`placeName`):** 取得された施設名
     - **MapKitカテゴリ (`rawCategory`):** `MKPointOfInterestCategory` の生文字列
  3. **位置情報・日時セクション:**
     - **緯度 (`latitude`) / 経度 (`longitude`):** 小数点以下6桁まで表示（長押しでコピー可能にする）
     - **水平精度 (`horizontalAccuracy`):** `±〇〇 m` の形式で誤差半径を表示
     - **滞在日時:** 到着日時 〜 出発日時（および滞在分数の計算値）

---

## 6. Xcode プロジェクト必須設定 (`Info.plist` / Capabilities)

1. **Signing & Capabilities:**
   - `+ Capability` より **`Background Modes`** を追加し、**`Location updates`** にチェックを入れる。
2. **Info (Custom iOS Target Properties):**
   - `NSLocationWhenInUseUsageDescription` (Privacy - Location When In Use Usage Description)
     - 値: `"滞在場所の店名やカテゴリを特定するために位置情報を使用します。"`
   - `NSLocationAlwaysAndWhenInUseUsageDescription` (Privacy - Location Always and When In Use Usage Description)
     - 値: `"アプリを閉じている間も滞在場所を自動記録するために位置情報を使用します。"`
