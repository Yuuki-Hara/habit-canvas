# 機能検証用アプリ（habit-canvas-poc）最新詳細設計書（完全版）

## 1. 検証の目的とスコープ

本番アプリ（`habit-canvas`）の開発に向け、コア技術である「実位置情報を用いた滞在検知（`CLVisit`）」「高精度GPSリトライとMapKitによる施設・ライフモード特定」「ユーザーによる直感的な補正と学習サイクル」「週間・月間の回数レポート集計」を実機で検証するためのPoC（概念実証）仕様を定義する。

### 実装済み機能一覧

1. **高精度位置情報取得＆リトライ制御**
   - `CLVisit`（バックグラウンド滞在検知）および検証用の手動現在地記録。
   - 水平誤差（`horizontalAccuracy`）の閾値を **`5.0m`** とし、超過時は**最大3回まで再試行**。5.0mを下回らなかった場合は、試行の中で**最も誤差が小さかった座標**を採用する。
2. **4段階のインテリジェント場所特定＆ライフモード自動分類**
   - **Step 0（事前登録拠点の判定）:** 事前登録された「自宅（半径60m）」「仕事（半径80m）」エリア内であれば、具体的な住所や近隣店舗名を出さず、シンプルに **`自宅`** / **`仕事`** として即確定する（プライバシー保護＆誤爆防止）。
   - **Step 1（過去の手動修正履歴の学習）:** 過去にユーザーが手動で修正した場所から**半径40m以内**であれば、その店舗名・カテゴリ・ライフモードを最優先で1位に採用する。
   - **Step 2（ノイズ除外 ＋ 周辺上位5件の多数決）:** ATM・駐車場・トイレ等のノイズ施設を除外した上で半径60m以内の施設候補（最大8件）を取得。雑居ビル等で1位の店名がズレても、**上位5件のライフモードの多数決**によって大分類（外食・自己投資など）を正確に判定する。
   - **Step 3（逆ジオコーディング・フォールバック）:** 周囲に店舗がない場合は住所（〇〇付近）を取得し、「📦 その他」に分類する。
3. **デイリーログ画面（日付切替・マップ・カード一覧・スワイプ削除）**
   - 日付ごとの滞在ピン表示マップと、時系列の滞在カードリスト。
   - カードの左スワイプ（または詳細画面の最下部ボタン）による不要ログの削除機能。
4. **詳細・補正シート（候補1タップ選択 ＆ マップ照準再検索）**
   - 周辺候補リストからの1タップ切り替え、ライフモードの直接変更、およびマップをドラッグして中央の照準（＋）の位置で候補を再検索する機能。
5. **週間・月間レポート画面（SCR-03）**
   - お出かけ系ライフモード（💪自己投資・🍽️外食・⛺️レジャー・📦その他）の週間・月間「回数（件数）」を棒グラフ（Swift Charts）とカードで可視化。
   - 各ライフモード行のタップによる訪問履歴内訳のアコーディオン展開表示。

---

## 2. ファイル構成（ディレクトリ構造）

- **ターゲット環境:** iOS 17.0以降
- **使用フレームワーク:** SwiftUI, SwiftData, CoreLocation, MapKit, Charts, Combine

```text
HabitCanvasPoC/
├── HabitCanvasPoCApp.swift               # アプリ起動・SwiftData初期化・環境オブジェクト注入
├── Info.plist                            # 位置情報権限・Background Modes定義
│
├── Models/
│   ├── VisitLog.swift                    # 滞在記録モデル（SwiftData）・LifeMode定義・候補構造体
│   └── RegisteredPlacesStore.swift       # 「自宅」「仕事」の事前登録座標管理（UserDefaults）
│
├── Services/
│   ├── LocationService.swift             # CLVisit監視・閾値5m/最大3回リトライ測位・保存処理
│   └── PlaceResolver.swift               # 拠点照合・学習履歴照合・ノイズ除外POI検索・多数決判定
│
└── Views/
    ├── MainTabView.swift                 # 下部タブバー（デイリーログ / レポート）
    ├── DailyLogPageView.swift            # 【タブ1】日付切替＋マップ＋カード一覧（スワイプ削除対応）
    ├── Components/
    │   └── DailyComponents.swift         # DateHeaderView / DailyMapView / VisitCardView
    ├── VisitDetailSheetView.swift        # 【詳細・補正】マップ照準再検索＋候補選択＋生データ確認＋削除
    ├── BaseLocationSettingsSheetView.swift # 【拠点設定】自宅・仕事の事前登録シート
    └── ReportPageView.swift              # 【タブ2】週間・月間のライフモード別回数グラフ＆内訳リスト
```

---

## 3. データモデル設計

### 3.1 6つのライフモード定義 (`LifeMode`)

時間帯による推測は行わず、自宅・仕事は「事前登録座標」、それ以外のお出かけは「MapKitカテゴリ（および手動学習）」から分類する。

| ライフモード                    | アイコン | 判定基準（MapKitカテゴリ / 拠点判定）                                                                                                                      | レポートでの扱い                 |
| :------------------------------ | :------: | :--------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------- |
| **自宅** (`home`)               |    🏠    | 事前登録した「自宅」座標から**半径60m以内**                                                                                                                | ベース拠点（下部枠）             |
| **仕事** (`work`)               |    🏢    | 事前登録した「仕事」座標から**半径80m以内**                                                                                                                | ベース拠点（下部枠）             |
| **自己投資** (`selfInvestment`) |    💪    | `.fitnessCenter`, `.library`, `.museum`, `.planetarium`, `.school`, `.university`, 書店等                                                                  | **お出かけアクション（主集計）** |
| **外食** (`dining`)             |    🍽️    | `.cafe`, `.restaurant`, `.bakery`, `.brewery`, `.foodMarket`, `.winery`, `.distillery`                                                                     | **お出かけアクション（主集計）** |
| **レジャー** (`leisure`)        |    ⛺️    | `.movieTheater`, `.theater`, `.nightlife`, `.park`, `.amusementPark`, `.aquarium`, `.beach`, `.campground`, `.marina`, `.nationalPark`, `.stadium`, `.zoo` | **お出かけアクション（主集計）** |
| **その他** (`other`)            |    📦    | 上記以外のPOI（コンビニ・スーパー・病院・役所等）、または施設なしの住所                                                                                    | **お出かけアクション（主集計）** |

### 3.2 `VisitLog` モデル (`Models/VisitLog.swift`)

SwiftDataの `@Model` マクロで永続化するエンティティ。

| プロパティ名             | 型       | 説明                                                                   |
| :----------------------- | :------- | :--------------------------------------------------------------------- |
| `id`                     | `UUID`   | 一意の識別子                                                           |
| `arrivalDate`            | `Date`   | 到着日時（日付ページおよび週間・月間レポートの集計基準）               |
| `departureDate`          | `Date?`  | 出発日時（滞在中または手動記録時は `nil`）                             |
| `latitude` / `longitude` | `Double` | 採用された緯度・経度                                                   |
| `horizontalAccuracy`     | `Double` | 採用された水平誤差半径（メートル）                                     |
| `placeName`              | `String` | 店名・施設名（自宅/仕事エリア内は `"自宅"` / `"仕事"` と記録）         |
| `rawCategory`            | `String` | MapKitカテゴリ文字列（自宅/仕事エリア内は `"登録スポット"`）           |
| `lifeModeRaw`            | `String` | `LifeMode` の rawValue                                                 |
| `isManuallyEdited`       | `Bool`   | ユーザーが手動修正（または学習データ・登録拠点から確定）したかのフラグ |
| `candidatesData`         | `Data?`  | 周辺の施設候補リスト（`[PlaceCandidate]` をJSONエンコードしたデータ）  |

### 3.3 `RegisteredPlacesStore` (`Models/RegisteredPlacesStore.swift`)

`UserDefaults` を用いて事前登録拠点を永続化するシングルトンストア。

- `homeCoordinate`: 自宅の緯度・経度（判定半径：`60.0m`）
- `workCoordinate`: 仕事の緯度・経度（判定半径：`80.0m`）

---

## 4. サービス（裏側のロジック）詳細設計

### 4.1 `LocationService.swift`（高精度リトライ測位＆永続化）

1. **高精度サンプリング開始 (`startHighAccuracySampling`):**
   - `desiredAccuracy = kCLLocationAccuracyBestForNavigation` を使用。
   - `CLVisit` 検知時または「現在地を記録(検証用)」ボタン押下時に、初期誤差が `5.0m` を超えている場合は連続測位（`startUpdatingLocation`）を開始する。
2. **最大3回リトライと最小誤差の採用:**
   - 受信した新鮮なGPSサンプル（直近5秒以内）を `collectedLocations` 配列に蓄積する。
   - 途中で `horizontalAccuracy <= 5.0m` を満たすサンプルが来たら即座に採用して測位を終了する。
   - `5.0m` を超えている場合は最大3回まで再試行（1試行あたり最大4秒のタイムアウト付き）を行い、3回終了時点で `collectedLocations` の中から **`horizontalAccuracy` が最小の座標**を選んで確定させる。
3. **学習データの抽出と保存 (`finalizeAndSave`):**
   - 保存前にSwiftDataから `isManuallyEdited == true` の過去ログを抽出し、`LearnedPlaceSnapshot` 配列として `PlaceResolver` に渡す。

### 4.2 `PlaceResolver.swift`（4段階の場所・モード特定エンジン）

受け取った座標に対して、以下の優先順位で場所とライフモードを特定する。

1. **Step 0：自宅・仕事の事前登録エリア判定（最優先）**
   - `RegisteredPlacesStore.shared.matchRegisteredMode(for:)` を呼び出す。
   - 自宅（60m以内）または仕事（80m以内）に該当した場合、MapKit通信を行わず、`primaryName = "自宅"`（または `"仕事"`）、`primaryCategory = "登録スポット"` として即座に返却する。
2. **Step 1：過去の手動修正データ（半径40m以内）の検索**
   - `learnedPlaces` の中から現在地との距離が `40.0m` 以内のものを探し、最も近いものを保持する。
3. **Step 2：ノイズ施設を除外したMapKit周辺検索**
   - `MKPointOfInterestFilter(excluding:)` を用い、以下のノイズカテゴリを検索段階から除外する：
     - `.atm`, `.parking`, `.restroom`, `.evCharger`, `.publicTransport`, `.carRental`, `.gasStation`
   - 半径 `60.0m` 以内の施設を取得し、距離の近い順にソートして最大8件の候補リスト（`[PlaceCandidate]`）を生成する。
   - Step 1で学習データがヒットしていた場合は、その学習データを候補先頭および1位として確定して返却する。
   - 新規の場所の場合は、1位の店舗名を仮セットしつつ、**上位5件の候補のライフモードで多数決（`calculateMajorityLifeMode`）**を行い、最多のライフモードを初期値として採用する。
4. **Step 3：逆ジオコーディング（フォールバック）**
   - 周辺にPOIが1件もない場合は `CLGeocoder` で住所（「〇〇区〇〇 付近」）を取得し、ライフモードは `.other`（その他）とする。

---

## 5. 画面（UI）詳細設計

### 5.1 `MainTabView.swift`（下部タブナビゲーション）

- **タブ1（`DailyLogPageView`）:** 「📍 デイリーログ」
- **タブ2（`ReportPageView`）:** 「📊 レポート」

### 5.2 `DailyLogPageView.swift`（デイリーログ画面）

- **ナビゲーションバー右上:** 「⚙️（自宅・仕事設定）」ボタンを配置し、`BaseLocationSettingsSheetView` をモーダル起動する。
- **上部:** 位置情報権限が「常に許可」でない場合の警告バナー、日付切り替えバー（`DateHeaderView`）、その日のピンを表示するマップ（`DailyMapView`）。
- **中部:** 件数表示、「＋ 現在地を記録(検証用)」ボタン、およびリトライ測位中のリアルタイムステータス表示（例：`精度5m超過のため再試行中 (2/3回目)...`）。
- **下部（カード一覧）:**
  - 透過スタイルの `List` 内にカード型UI（`VisitCardView`）を配置。
  - **カードタップ:** `VisitDetailSheetView`（詳細・補正画面）を起動。
  - **左スワイプ（`.swipeActions`）:** 赤い「削除」ボタンを表示し、SwiftDataから該当ログを即座に削除する。

### 5.3 `VisitDetailSheetView.swift`（詳細・補正シート）

1. **マップ操作＆再検索セクション:**
   - マップ中央に固定照準アイコン（`＋`）を表示。地図をドラッグして実際の建物に照準を合わせ、「マップ中央の位置で候補を再検索」ボタンを押すと、その座標で `PlaceResolver` を再実行して候補リストを洗い替える。
2. **ライフモード直接変更セクション:**
   - 6つのライフモードのカプセルボタンを横スクロール配置。1タップでモードを上書きし、`isManuallyEdited = true` として保存する。
3. **近くの施設候補リスト選択セクション:**
   - 保持している周辺候補（最大8件）を距離順に表示。タップすると「店名・MapKitカテゴリ・ライフモード・座標」を一括更新し、次回以降の学習データ（`isManuallyEdited = true`）として保存する。
4. **生データ＆削除セクション:**
   - 店名、MapKitカテゴリ生文字列、緯度・経度（長押しコピー対応）、水平誤差半径（`±〇〇m`）を表示。
   - 最下部に「🗑️ この滞在ログを削除」ボタンを配置。

### 5.4 `BaseLocationSettingsSheetView.swift`（自宅・仕事の事前登録シート）

- 現在の「🏠 自宅（半径60m）」「🏢 仕事（半径80m）」の登録有無・座標確認と個別削除ボタン。
- セグメントピッカーで登録対象（自宅 / 仕事）を選び、地図を動かして中央の照準（＋）を合わせて登録ボタンを押すだけで座標を保存。マップ上には判定半径を示す半透明のサークル（`MapCircle`）を描画する。

### 5.5 `ReportPageView.swift`（週間・月間レポート画面 / SCR-03）

1. **期間スコープ＆ページ送りヘッダー:**
   - 「週間」「月間」のセグメント切り替えと、`＜` `＞` ボタンによる前後の週・月への移動。
2. **お出かけアクション合計 ＆ 棒グラフ（Swift Charts）:**
   - 期間内の「💪 自己投資」「🍽️ 外食」「⛺️ レジャー」「📦 その他」の合計回数を大きく表示し、モード別の回数をカラフルな `BarMark`（棒グラフ）で描画する。
3. **モード別回数リスト（アコーディオン展開）:**
   - 「お出かけモード別の回数（4種）」と「ベース拠点の記録回数（仕事・自宅の2種）」をセクション分けしてカード表示。
   - 各カードをタップするとアコーディオンが開き、その期間に記録された該当モードの「日時・場所名」の履歴一覧を確認できる。

---

## 6. Xcode プロジェクト必須設定 (`Info.plist` / Capabilities)

1. **Signing & Capabilities:**
   - `+ Capability` より **`Background Modes`** を追加し、**`Location updates`** にチェックを入れる。
2. **Info (Custom iOS Target Properties):**
   - `NSLocationWhenInUseUsageDescription` (Privacy - Location When In Use Usage Description)
     - 値: `"滞在場所の店名やカテゴリを特定するために位置情報を使用します。"`
   - `NSLocationAlwaysAndWhenInUseUsageDescription` (Privacy - Location Always and When In Use Usage Description)
     - 値: `"アプリを閉じている間も滞在場所を自動記録するために位置情報を使用します。"`
