# tategaki-reader 実装仕様書（移植用・完全版）

対象コミット: `961edea` 時点 + 未コミットの対訳機能（`Translation.swift` / `TranslationPane.swift`）
参照実装: Swift 5.9 / SwiftUI / Mac Catalyst（iOS 16 SDK）+ WKWebView + foliate-js

この文書は **「別の言語・別のGUIツールキットでこのアプリを一から作り直す」ための設計資料** である。
参照実装のソースを見なくても同じ挙動を再現できるよう、アルゴリズム・定数・API 契約・
失敗事例（なぜその実装になっているか）まで記述する。

---

## 目次

1. [製品定義](#1-製品定義)
2. [アーキテクチャ](#2-アーキテクチャ)
3. [データモデルと永続化](#3-データモデルと永続化)
4. [起動・ファイル入力](#4-起動ファイル入力)
5. [書棚（ライブラリ）](#5-書棚ライブラリ)
6. [EPUB メタデータ抽出（probe）](#6-epub-メタデータ抽出probe)
7. [表示エンジン契約（ホスト ⇄ レンダラ）](#7-表示エンジン契約ホスト--レンダラ)
8. [組版ロジック（このアプリの中核）](#8-組版ロジックこのアプリの中核)
9. [リーダー UI](#9-リーダー-ui)
10. [読み上げ（TTS）](#10-読み上げtts)
11. [音声ファイル書き出し](#11-音声ファイル書き出し)
12. [朗読動画書き出し](#12-朗読動画書き出し)
13. [対訳（LM Studio）](#13-対訳lm-studio)
14. [測定オーバーレイと QA 基盤](#14-測定オーバーレイと-qa-基盤)
15. [設定項目の完全一覧](#15-設定項目の完全一覧)
16. [ローカライズ](#16-ローカライズ)
17. [ビルド・署名・配布](#17-ビルド署名配布)
18. [既知の落とし穴（移植時に必ず踏む）](#18-既知の落とし穴移植時に必ず踏む)
19. [移植ガイド](#19-移植ガイド)
20. [受け入れテスト項目](#20-受け入れテスト項目)

---

## 1. 製品定義

### 1.1 これは何か

日本語の**縦書き EPUB を「とりあえず無難に読める」状態で表示**し、
**VOICEVOX / AivisSpeech で読み上げる**デスクトップ向け EPUB リーダー。

### 1.2 設計思想（最重要・移植しても捨ててはいけない前提）

| 原則 | 内容 |
|---|---|
| **規格の正しさより「無難に表示されること」** | 実在の EPUB は縦書き指定が欠けている・SVG 表紙が潰れている・目次のリンクが切れている等が常態。厳密に解釈すると読めない。既定モード（`friendly`）はこれを推測で補う |
| **同時に「素直に壊れて見える」モードを持つ** | `raw` モードは補正を全部止め、EPUB の指定どおりに描く。自作 EPUB の検品ツールとして使う |
| **本のデータから決められないことは読み手に決めさせ、本ごとに覚える** | 綴じ方向・見開き・アスペクト比・書字方向。漫画は本文が画像だけなので機械には向きを測れない |
| **読み上げは主機能であって付属品ではない** | 原稿チェック・通勤中の聴読が想定用途。辞書・速度・書き出しまで作り込む |
| **レイアウト品質は数値でアサートする** | 「ずれて見える」ではなく「12.3pt はみ出している」で判定する（14章） |

### 1.3 非目標

- EPUB の編集・作成
- クラウド同期・アカウント
- DRM 付き書籍
- notarize 済み配布（ad-hoc 署名で配る方針）

### 1.4 対応形式

- **EPUB 2 / EPUB 3**（リフロー・固定レイアウト両方）
- **OMF 系の漫画 EPUB**（spine が XHTML を挟まず JPEG を直接指す形式）
- 参照実装のエンジン（foliate-js）は MOBI / FB2 / CBZ / PDF も読めるが、本アプリの UI は EPUB 前提

---

## 2. アーキテクチャ

### 2.1 レイヤ構成

```
┌──────────────────────────────────────────────────────────┐
│ ネイティブ UI 層 (SwiftUI)                                │
│  ShelfView / ReaderScreen / SettingsView / TranslationPane│
├──────────────────────────────────────────────────────────┤
│ モデル層                                                  │
│  AppModel(書棚・設定) / ReaderModel(1冊の状態)             │
│  ReadingDictionary(読み辞書) / TranslationCache           │
├──────────────────────────────────────────────────────────┤
│ サービス層                                                │
│  VoicevoxSpeaker / LMStudioClient / WAV /                 │
│  VideoNarrationRenderer / EpubProbe / TestBus(DEBUG)      │
├──────────────────────────────────────────────────────────┤
│ ブリッジ層 (FoliateEngine)                                │
│  WKWebView + カスタム URL スキーム + JS 双方向呼び出し     │
├──────────────────────────────────────────────────────────┤
│ 組版エンジン層 (WebView 内 / JavaScript)                  │
│  bridge.js（このアプリ固有のロジック 1600行）             │
│  foliate-js（ページネーション・CFI・TTS・検索）           │
└──────────────────────────────────────────────────────────┘
```

**移植時の要点**: 組版エンジン層は「WebView + JS」であることが本質的。CSS の
`writing-mode: vertical-rl` を正しく組めるレンダリングエンジンは実質 WebKit/Blink/Gecko しかない。
自前で縦書き組版を書くのは（このアプリの規模では）非現実的。したがって**どの言語へ移植しても
WebView を埋め込み、bridge.js 相当をそのまま流用する**のが最短かつ唯一の現実解である。
ネイティブ側で書き直すのは「UI・永続化・HTTP・音声/動画処理」の部分だけになる。

### 2.2 プロセス内リソース配信

WebView に `file://` でローカルファイルを読ませると同一オリジン制約で ES モジュールの
相対 import が壊れる。カスタムスキーム `foliate:` を登録して自前で配信する。

| URL | 実体 | MIME |
|---|---|---|
| `foliate:///app/reader.html` | アプリバンドル `Resources/foliate/reader.html` | `text/html; charset=utf-8` |
| `foliate:///app/bridge.js` | 同 `bridge.js` | `text/javascript; charset=utf-8` |
| `foliate:///app/foliate-js/*.js` | 同ディレクトリ配下 | `text/javascript; charset=utf-8` |
| `foliate:///app/narration/harness.html` | 動画レンダラ | `text/html` |
| `foliate:///book/current.epub` | **メモリ上の現在の EPUB のバイト列** | `application/epub+zip` |

- レスポンスヘッダは `Content-Type` / `Content-Length` / `Access-Control-Allow-Origin: *` を返す。
- `/app/` 配下は**ディレクトリトラバーサル防止**（正規化パスが root 配下であることを検査）。
- 拡張子→MIME の対応表: html/htm, js/mjs, css, json, svg, png, jpg/jpeg, gif, webp, woff, woff2, ttf, epub、既定 `application/octet-stream`。

### 2.3 CSP（reader.html に埋める）

```
default-src 'self' foliate:;
script-src 'self' foliate: 'unsafe-eval';
img-src 'self' foliate: blob: data:;
media-src 'self' foliate: blob: data:;
style-src 'self' foliate: 'unsafe-inline' blob:;
frame-src blob: foliate:;
font-src 'self' foliate: blob: data:;
connect-src 'self' foliate: blob:;
```

`'unsafe-eval'` は DEBUG の測定オーバーレイ（`evalInContent`）にのみ必要。外部ホストは一切許可しない。

### 2.4 ホスト ⇄ WebView の呼び出し規約

| 方向 | 手段 | 規約 |
|---|---|---|
| ホスト → JS | `evaluateJavaScript("window.__reader.foo(arg)")` | 戻り値は **JSON 文字列**。ホスト側でデコードする |
| ホスト → JS（非同期） | `callAsyncJavaScript("return await window.__reader.foo()")` | Promise を返す API はこちら。`evaluateJavaScript` は Promise を解決しない |
| JS → ホスト | `webkit.messageHandlers.foliate.postMessage({type, ...})` | `type` キー必須のディクショナリ |

引数は「JSON 文字列を単一引用符リテラルにエスケープして埋め込む」方式。
エスケープ対象: `\` `'` `\n` `\r` `U+2028` `U+2029`。

---

## 3. データモデルと永続化

すべて **UserDefaults（= キー付き KVS）に JSON エンコードして格納**する。
移植先では設定ファイル（JSON/TOML）＋アプリ設定ディレクトリで等価に実装してよい。

### 3.1 BookEntry（書棚の 1 冊）

```
BookEntry {
  id: UUID                    // 必須
  path: String                // EPUB の絶対パス（サンドボックス無効前提でそのまま保存）
  title: String               // 表示タイトル（取得失敗時はファイル名（拡張子なし））
  addedAt: Date
  lastOpenedAt: Date
  locatorJSON: String?        // 最後の読書位置。現在は EPUB CFI 文字列を格納
  coverFileName: String?      // Covers/<uuid>.png のファイル名
  bookmarks: [Bookmark]?      // 旧データ互換のため optional
  customCSS: String?          // この本だけのユーザー CSS
  writingMode: String?        // WritingMode の rawValue。nil = 全体既定に従う
  bindingDirection: String?   // BindingDirection の rawValue
  imageSpread: String?        // SpreadMode の rawValue
  textSpread: String?         // SpreadMode の rawValue
  forcedAspect: String?       // "844:1200" 形式。既定を持たない（本ごとに正解が違う）
  author: String?
  publisher: String?
  authorSort: String?         // opf:file-as / contributor.sortAs
  authorYomi: String?         // ユーザー手動入力（かな）。最優先
  progress: Double?           // 0...1
}
```

**派生値**

- `authorText` = `author ?? ""`、`publisherText` = `publisher ?? ""`
- `resolvedAuthorReading` = `authorYomi`（非空）→ `authorSort`（**かなのみで構成される場合のみ**）→ `nil`
- `authorSortKey` = `resolvedAuthorReading ?? authorText`
- `progressPercent` = `progress > 0` のとき `clamp(round(progress*100), 1, 100)`、それ以外 `nil`
  （**0% と表示すると「未読」と誤読されるので、僅かでも読んだら 1%**）
- `hasStartedReading` = `locatorJSON != nil`
- `fileExists` = パス実在判定

**かな判定 `isKanaString(s)`**: トリム後が空でなく、全文字が次のいずれか:
ひらがな `U+3041–U+3096` / カタカナ `U+30A1–U+30FA` / `ー U+30FC` / `・ U+30FB` / 全角空白 `U+3000` / 半角空白。

### 3.2 Bookmark

```
Bookmark { id: UUID, locatorJSON: String (CFI), progression: Double, excerpt: String, createdAt: Date }
```

- 追加時、**同一 `locatorJSON` が既にあれば無視**（重複防止）。
- 追加後は `progression` 昇順にソートして保持。
- 現行実装では `excerpt` は空文字（UI は「（本文位置）」と表示）。

### 3.3 ReadingSettings（全書籍共通の読書設定）

| フィールド | 型 | 既定 | 範囲/値 |
|---|---|---|---|
| `fontSize` | Double | 1.0 | 0.5–3.0（ツールバー ±0.1）／設定画面は 0.6–2.0 step 0.05 |
| `lineHeight` | Double | 1.8 | 1.0–2.4 step 0.1。0 以下なら本の指定を尊重 |
| `theme` | String | `"light"` | `light` / `sepia` / `dark` / `auto` |
| `language` | String | `"auto"` | `auto` / `ja` / `en` |
| `writingMode` | String | `"auto"` | `auto` / `vertical` / `horizontal` |
| `renderMode` | String | `"friendly"` | `friendly` / `raw` |
| `bindingDirection` | String | `"auto"` | `auto` / `rtl` / `ltr` |
| `imageSpread` | String | `"auto"` | `auto` / `always` / `never` |
| `textSpread` | String | `"auto"` | 同上 |

**デコード規約（全設定構造体で共通）**: 欠損キーは既定値で補う。
設定項目を後から増やしても旧保存データを読めなくてはならない。

### 3.4 列挙型と巡回順

```
RenderMode      : friendly ⇄ raw                （トグル）
WritingMode     : auto | vertical | horizontal   （メニュー選択のみ）
BindingDirection: auto → rtl → ltr → auto        （ボタン押下で巡回）
SpreadMode      : auto → always → never → auto   （ボタン押下で巡回）
```

アイコン（SF Symbols 名。移植先では同義のアイコンに置換）:

| 対象 | auto | 値1 | 値2 |
|---|---|---|---|
| WritingMode | `wand.and.stars` | vertical=`text.append` | horizontal=`text.alignleft` |
| BindingDirection | `arrow.left.arrow.right` | rtl=`arrow.left` | ltr=`arrow.right` |
| SpreadMode（画像） | `photo.on.rectangle` | always=`photo.on.rectangle.angled` | never=`photo` |
| SpreadMode（本文） | `doc.on.doc` | always=`doc.on.doc.fill` | never=`doc.plaintext` |

### 3.5 AspectRatio

```
AspectRatio { width: Double, height: Double }
  isValid       = width > 0 && height > 0
  storageString = "<round(w)>:<round(h)>"     例 "844:1200"
  label         = "844 : 1200"
  parse("844:1200") / parse("3:4") / parse("1.5" → {1.5, 1})
```

プリセット: `2:3`（文庫）, `3:4`（漫画単行本）, `210:297`（A判）, `182:257`（B5）, `1:1`。

### 3.6 ReadingEntry（読み辞書の 1 件）

```
ReadingEntry {
  id: UUID
  surface: String        // 本文中の書き方。kind=pattern なら正規表現
  reading: String        // 読み（かな/カナどちらでも可。適用時にカタカナへ正規化）
  layer: Int = 5         // 1...10。大きいほど先に適用
  kind: word | pattern
  padsBoundary: Bool     // 読みの前後に境界を挿入する
  enabled: Bool = true
}
```

### 3.7 AudioSettings / TranslationSettings

（15章の設定一覧を参照。構造は 3.3 と同じ「欠損キーは既定値」規約。）

### 3.8 永続化キーと保存場所

| キー | 内容 |
|---|---|
| `library.books.v1` | `[BookEntry]` |
| `library.settings.v1` | `ReadingSettings` |
| `library.seeded.v2` | サンプル本の初回シード済みフラグ |
| `reader.userCSS` | 全書籍共通のユーザー CSS |
| `reader.activeCSS` | 「共通 + 本別」を結合した解決済み CSS（内部キャッシュ） |
| `reader.debug.measureGrid` | 測定グリッド表示 |
| `reader.translation.paneWidth` | 対訳ペイン幅（既定 460） |
| `reader.translation.fontScale` | 対訳ペイン文字倍率（既定 1.0） |
| `reader.translation.showSource` | 原文併記（既定 true） |
| `tts.readingDictionary.v2` | `[ReadingEntry]` |
| `tts.readingRules.v1` | **旧形式**（migrate 元。3.9 参照） |
| `audio.settings.v1` | `AudioSettings` |
| `translation.settings.v1` | `TranslationSettings` |
| `tts.saveDirectoryPath` | 音声/動画の保存先ディレクトリのパス文字列 |
| `AppleLanguages` | UI 言語の上書き（OS 機構。移植先では独自実装） |

| ディレクトリ | 内容 |
|---|---|
| `<AppSupport>/EpubReaderSpike/Covers/<uuid>.png` | 表紙キャッシュ（≤400×600 PNG） |
| `<AppSupport>/EpubReaderSpike/translation-cache.json` | 訳文キャッシュ |
| `<AppSupport>/DroppedImports/` | in-place で開けなかったドロップの退避先 |

### 3.9 マイグレーション: 旧「読み替えルール」→ 読み辞書

旧形式 `[{pattern, replacement, enabled}]`（配列順に適用）を読み、
`kind=.pattern`、`layer = max(1, 10 - index)` として変換する（先頭ほど上のレイヤー＝
従来の優先関係を保つ）。変換後は新キーへ保存する。

---

## 4. 起動・ファイル入力

### 4.1 EPUB を開く経路（4 つ）

1. **メニュー「ファイル > 開く…」（⌘O）** → ファイルピッカー（許可型 `.epub`）
2. **ウィンドウへのドラッグ＆ドロップ**（書棚・リーダー表示中の両方で受ける）
3. **Finder で .epub をダブルクリック / アプリアイコンへドロップ**
   （ドキュメント型宣言 `org.idpf.epub-container`, role=Viewer, `LSSupportsOpeningDocumentsInPlace=true`）
4. 書棚のセルをクリック（既に登録済みの本）

### 4.2 ドロップの堅牢ローダ（重要）

macOS Catalyst の Finder ドラッグは `public.file-url` を持たず
`org.idpf.epub-container`（+ `com.apple.finder.node`）で渡ってくる。素朴に file-url を
読もうとすると必ず失敗する。次の順で解決する:

```
1. provider の registeredTypeIdentifiers から
     a) .epub に conform する型
     b) なければ data / fileURL に conform する型
   を選ぶ。無ければ受理しない。
2. loadInPlaceFileRepresentation(型) を試す
     → 得られた URL の拡張子が epub なら、その実パスをそのまま使う（コピーしない）
3. 失敗したら loadFileRepresentation(型)
     → 一時ファイルはクロージャ終了で消えるので、
       <AppSupport>/DroppedImports/ へコピーしてから開く
```

**in-place を優先する理由**: 読書位置の保存先が実パスで一意に決まる。コピーすると
同じ本が二重登録される。

### 4.3 本の登録フロー

```
open(url):
  既存 books に同じ path があれば → lastOpenedAt を更新して開くだけ
  なければ:
    title = ファイル名（拡張子なし）
    probe(url)（6章）が成功したら title/author/authorSort/publisher/cover を上書き
    cover があれば Covers/<新UUID>.png へ書き出し
    books の先頭へ挿入 → 保存 → 開く
```

### 4.4 サンプルのシード

初回起動時（`books` が空 かつ `library.seeded.v2` が false）に、バンドル同梱の
`sample-vertical.epub` と `ruler-measure.epub` を**開かずに登録だけ**する。

---

## 5. 書棚（ライブラリ）

### 5.1 画面構成

```
┌─ ヘッダ ────────────────────────────────────────┐
│ 「書棚」          [⚙設定] [＋本を追加(⌘O)]      │
│ [🔍フィルタ入力][対象▾]  [表示:グリッド|作者別] [並び替え▾] │
├─ 本体 ──────────────────────────────────────────┤
│ ┌ 続きを読む段（最後に開いた本・1冊だけ） ┐      │
│ │ [表紙130×190] タイトル / 作者 / n% 読了 │      │
│ │                [続きを読む|読み始める]  │      │
│ └────────────────────────────────────────┘      │
│ ─────────────────────────────────────           │
│ グリッド（表紙150×220・adaptive min130 max180、  │
│           列間24 行間28、内側 padding 24）        │
└─────────────────────────────────────────────────┘
背景: 最後に開いた本の表紙を blur(20, opaque) opacity 0.55 + 地色 0.3 で敷く
ヘッダ背景: 地色 opacity 0.74（表紙をわずかに透かす）
```

### 5.2 フィルタとソート

- **フィルタ**: クエリを小文字化し、対象（すべて/タイトル/作者/出版社）に対し部分一致。
- **ソート**（グリッドのみ）: `recent`（`lastOpenedAt` 降順。モデルが保持している順）/
  `title` / `author` / `publisher`。文字列比較は**ロケール考慮の自然順**（`localizedStandardCompare` 相当）。

### 5.3 作者別 五十音インデックス

**セクション見出しの決定**（`authorSortKey` の先頭 1 文字から）:

```
先頭文字が
  かな（カタカナは -0x60 でひらがな化）→ 行頭文字（あ/か/さ/た/な/は/ま/や/ら/わ）
      行の判定: 以下の閾値以上の最大のものを採用
      あ:U+3042 か:U+304B さ:U+3055 た:U+305F な:U+306A
      は:U+306F ま:U+307E や:U+3084 ら:U+3089 わ:U+308F
      （小書き「ぁ」等は「あ」行に寄る）
  数字      → "#"
  ASCII 英字 → 大文字1文字（A–Z）
  その他の文字（漢字など＝読み未取得）→ "他"
  文字なし（作者不明）→ "—"
```

**セクションの並び順**: `あ か さ た な は ま や ら わ` → `A…Z` → `#` → `他` → `—`

**セクション内の並び**: `authorSortKey` の自然順 → 同値ならタイトルの自然順。

見出しはスクロール時にピン留めする。

### 5.4 セルの表示

- 表紙 150×220、角丸 6、枠線 `black 12%` 1px、影 `black 18%` r5 y3
- タイトル: **常に 2 行分の高さを予約**（短くても空行を確保＝全セル同一高でカバー位置が揃う）、末尾省略
- 作者: 1 行分を必ず確保（空なら半角空白）
- 左下オーバーレイ: 読了率バッジ（`black 65%` の Capsule、白文字）
- 右上オーバーレイ: ファイル欠損時 `exclamationmark.triangle.fill`（橙）
- 右クリックメニュー: 「作者の読みを設定…」 / 「書棚から削除」

### 5.5 代替表紙

表紙を持たない EPUB は実在する（青空文庫の短編、変換で表紙を落とした本、
画像を 1 枚も含まない本）。無地の矩形で並べると書棚が抜け落ちて見えるので、
**装丁を模した同梱画像（800×1200）にタイトルを白文字で重ねる**。
画像が読めない場合は同系色のグラデーション（`#252F40` → `#12181F` 相当）へフォールバック。

### 5.6 表紙のキャッシュ戦略（性能上の必須要件）

UI フレームワークは再描画のたびに `coverImage(book)` を呼ぶ。素朴にディスクから読むと
絞り込み・並び替えのたびに全冊デコードが走る。

```
1. メモリキャッシュ（LRU 相当、コスト = 幅×高さ ピクセル数）を引く
2. ミスなら ImageIO のサムネイル生成で「最大辺 460px」に**デコード時に**縮小して読む
   （フル解像度に展開してから縮小しない）
3. キャッシュへ格納
表紙を差し替え/削除したらキーを無効化する
```

ディスク上の PNG は 400×600 だが、セル表示は 150×220pt（Retina 300×440px）なので 460px で十分。

### 5.7 メタデータのバックフィル

書棚を開いたとき 1 度だけ実行。対象は「ファイルが存在する」かつ次のいずれか:

- `author == nil && publisher == nil`（メタ未取得）
- `author != nil && authorSort == nil`（読み未取得）
- `coverFileName == nil`（表紙欠落。probe が落ちた本で丸ごと欠ける）

各対象を probe し直し、取得できた項目だけを追記する。
タイトルは「現在の値がファイル名フォールバックのままのとき」のみ上書きする。

### 5.8 作者の読みの手動設定

セルの右クリック → アラートで「かな」を入力 → `authorYomi` に保存（空でクリア）。
五十音インデックスの分類・並びに使われる。

---

## 6. EPUB メタデータ抽出（probe）

書棚登録のために、**表示せずに**タイトル・作者・読み・出版社・表紙を取り出す。

```
probe(url):
  1. EPUB のバイト列を読み、10×10 の非表示 WebView をウィンドウに載せる
  2. reader.html をロード → "bridge-ready" 受信 → window.__reader.probe() 呼び出し
  3. "probe" メッセージを受信:
       { title, author, authorSort, publisher, cover(base64) }
  4. cover を ≤400×600（アスペクト維持・拡大なし）の PNG へ正規化
  5. WebView を破棄
  タイムアウト 15 秒で nil を返す
```

**JS 側 `probeBook()` の仕様**:

- 非表示の `foliate-view` で `open(file)` し、`book.metadata` を読む。
- 多言語辞書（`{ja: "…"}` 形式）は**最初のキーの値**を採る（`flatLang`）。
- 貢献者は配列なら `、` で連結、オブジェクトなら `name` を `flatLang`（`flatContributor`）。
- 読みは `contributor.sortAs`（配列なら先頭）。
- 表紙は `book.getCover()` → **失敗したら `coverFromFirstSection(book)`**:
  - `getCover()` が見るのは ①manifest の `properties="cover-image"` ②EPUB2 の
    `<meta name="cover">` ③guide の `reference[type=cover]` の 3 つだけ。
    OMF 漫画はそのどれも持たないことがある。
  - **spine の先頭が表紙であることはほぼ確実**なので、そこから絵を取る:
    先頭 section の media-type が `image/*` ならロード結果そのものが絵。
    XHTML なら中の最初の `img`/`image`（`src` / `xlink:href`）を fetch する。
- **`view.close()` は「一度も描画していない view」で必ず例外を投げる**
  （paginator.destroy がページ生成時にしか作られない内部 view を触るため）。
  probe は描画しないので毎回踏む。**必ず try-catch で握り潰し、remove() で後始末する。**
  ここで例外を外へ出すと、取得済みのメタデータごと失敗扱いになる（実際に表紙が全損した）。

---

## 7. 表示エンジン契約（ホスト ⇄ レンダラ）

移植の際、**この契約さえ満たせばネイティブ側は同じコードで動く**。

### 7.1 ホスト → エンジン（`window.__reader.*`）

| API | 引数 | 戻り | 同期性 |
|---|---|---|---|
| `open(json)` | `{cfi?, fraction?, writingMode, renderMode, binding, imageSpread, textSpread, aspect?}` | — | 非同期（完了は `ready` メッセージ） |
| `probe()` | — | — | 非同期（`probe` メッセージ） |
| `setRenderMode(mode)` | `"friendly"｜"raw"` | `{renderMode}` | 同期 |
| `renderMode()` | — | `{renderMode}` | 同期 |
| `next()` / `prev()` | — | — | 非同期 |
| `goLeft()` / `goRight()` | — | — | 非同期 |
| `goToFraction(f)` | 0…1 | — | 非同期 |
| `goTo(target)` | CFI または href | — | 非同期 |
| `setStyle(json)` | `{theme, fontScale, lineHeight, userCSS}` | — | 同期 |
| `setWritingMode(mode, cfi)` | — | `{writingMode, reopened, cfi}` | **await 必須** |
| `setDisplay(json)` | `{binding?, imageSpread?, textSpread?, aspect?}`（部分更新） | `displayState()` | 同期 |
| `displayState()` | — | `{binding, bookDir, imageSpread, textSpread, aspect, detectedAspect}` | 同期 |
| `toggleSpread()` | — | `{spreadOffset}` | 同期 |
| `spreadState()` | — | `{log, spreadOffset, imagePage, index}` | 同期（デバッグ用） |
| `getTOC()` | — | `[{id, label, href, subitems}]` | 同期 |
| `getSelection()` | — | `{text}` | 同期 |
| `runSearch(q)` | — | — | 非同期（逐次メッセージ） |
| `clearSearch()` | — | — | 同期 |
| `ttsStart(mode)` | `"visible"｜"selection"｜"resume"` | `[{mark, text}]` または `null` | **await 必須** |
| `ttsNextBlock()` | — | 同上 | **await 必須** |
| `ttsMark(name)` | — | — | 同期 |
| `ttsStop()` | — | — | 同期 |
| `ttsCollectSection()` | — | `[文字列]` | **await 必須** |
| `getVisiblePassages()` | — | `{passages:[{cfi,text,heading}], index, hadRange}` または `{passages:[], reason}` | 同期 |
| `evalInContent(js)` | — | 評価結果の JSON | 同期（DEBUG 用） |

### 7.2 エンジン → ホスト（メッセージ）

| type | ペイロード | 意味 |
|---|---|---|
| `bridge-ready` | — | JS 側の初期化完了。ホストはここで `open()` を呼ぶ |
| `ready` | `{title, author, dir, vertical, bookDir, writingMode, bookWritingHint, fixedLayout, ...displayState()}` | 本を開き終えた |
| `display` | `...displayState()` | 開いた後に表示状態が更新された（判型を画像から拾い直した等） |
| `relocate` | `{fraction, cfi, isImagePage, vertical, dir, bookDir, tocHref}` | 表示位置が確定した（**位置保存・状態同期の主経路**） |
| `load` | `{index}` | セクションの文書がロードされた |
| `dblclick` | — | 本文がダブルクリックされた |
| `selection` | `{text}` | 選択が変わった（100ms デバウンス） |
| `shortcut` | `{action: "playPause"｜"stop"}` | 本文上でのキー操作 |
| `searchHit` | `{cfi, pre, match, post}` | 検索ヒット（逐次） |
| `searchDone` | `{count}` | 検索終了 |
| `probe` | `{title, author, authorSort, publisher, cover}` または `{error}` | メタ抽出結果 |
| `error` | `{message}` | エラー |

### 7.3 起動シーケンス

```
ホスト                     WebView(bridge.js)
  │ 本のバイト列を provider へ格納
  │ WebView 生成（--page-bg を documentStart で注入）
  │ reader.html ロード ──────────►
  │                          モジュール読込完了
  │ ◄──────────────────────── bridge-ready
  │ open({cfi, writingMode, renderMode, binding, imageSpread, textSpread, aspect})
  │                          fetch(foliate:///book/current.epub)
  │                          foliate-view 生成・open
  │                          書字方向/綴じ方向の初期決定 → applyStyles()
  │                          cfi があれば goTo、無ければ最初のページ
  │ ◄──────────────────────── ready {...}
  │ setStyle({theme,fontScale,lineHeight,userCSS})
  │ getTOC()
  │ ◄──────────────────────── relocate {...}（以後ページが動くたび）
```

**重要**: 書字方向・表示モード・綴じ方向は **`open()` の引数として渡さなければならない**。
後から `setStyle` で入れても、既に組まれたページの縦横は変わらない
（paginator が iframe ロード直後の computed `writing-mode` で縦横を決め打ちするため）。

---

## 8. 組版ロジック（このアプリの中核）

参照実装 `bridge.js`（約 1600 行）の全アルゴリズム。**移植時はこのファイルをほぼそのまま
流用できる**が、ロジックの意図を以下に文書化する。

### 8.1 表示モード

```
friendly（既定）: 画像を面いっぱいに出し、画像だけの面は自前で描き、続く画像は見開きに組む。
                  SVG の潰れを直し、ぶら下げインデントを直し、目次のリンク切れを推測で救済する。
raw            : 上記の補正を全部止める。EPUB の指定どおりにエンジンが描いた姿を見る。
                  配色・文字サイズ・行間・ユーザー CSS は raw でも効く
                  （これらは読書設定であって EPUB の解釈ではないため）。
```

`raw` へ切り替えるときは、`friendly` が付けた DOM 変更を戻す:
- 画像に入れた `height/max-height/width/max-width/object-fit` を除去
- `preserveAspectRatio` を元の値へ復元
- 画像レイヤーを隠す
- `applyStyles()` → `renderer.render()` で再計算

### 8.2 テーマ CSS

```css
@namespace epub "http://www.idpf.org/2007/ops";
html { color-scheme: <dark|light>; background: <bg>; color: <fg>; font-size: <pct>%; }
body { background: <bg>; color: <fg>; }
/* lineHeight > 0 のときだけ */
body, p, li, div { line-height: <lh> !important; }
a:link, a:visited { color: <link>; }
aside[epub|type~="footnote"], aside[epub|type~="endnote"] { display: none; }
/* friendly のときだけ */
img, picture, svg { max-width: 100% !important; max-height: 95vh !important; object-fit: contain; }
```

パレット:

| theme | bg | fg | link |
|---|---|---|---|
| light | `#ffffff` | `#1a1a1a` | `#2563eb` |
| sepia | `#f4ecd8` | `#5b4636` | `#8a5a2b` |
| dark | `#1c1c1e` | `#e6e6e6` | `#7fb2ff` |
| auto | システムの light/dark に解決 | | |

`pct = round(fontScale * 100)`。

**CSS の適用順**（`renderer.setStyles([pre, post])`。配列は head の先頭/末尾へ振り分けられる）:

```
pre  = 書字方向の「弱い」指定（EBPAJ クラスの既定 + OPF メタ由来の補い）
post = テーマ CSS + ユーザー CSS + 書字方向の「強制」指定（!important）
```

### 8.3 書字方向の決定（縦書き問題の中核）

日本語 EPUB の縦書き指定は当てにならない。3 つの情報源を重みづけて使う。

**情報源**

1. **本の CSS の `writing-mode`**（最も正しいが、変換で落ちていることがある）
2. **EBPAJ 制作ガイドの組み方向クラス** `html.vrtl / vltr / hltr / hrtl`
   日本の商業 EPUB は html 要素にこのクラスを付け、`writing-mode` 自体は本の CSS で当てる約束。
   変換を経た本ではクラスだけ残って定義が落ちていることがある
   （実測: 手元 26 冊中 5 冊。うち 3 冊は OPF メタも無く、縦書きの痕跡がこのクラスだけ）。
3. **OPF の `<meta name="primary-writing-mode" content="vertical-rl">`**
   EPUB 標準ではないが、calibre 変換本で縦書きの意思がここにしか残らないことがある。

**注入する CSS**

```css
/* pre: クラスの既定（本の CSS より前・詳細度は低い） */
html.vrtl { writing-mode: vertical-rl; -webkit-writing-mode: vertical-rl; -epub-writing-mode: vertical-rl; }
html.vltr { writing-mode: vertical-lr; ... }
html.hltr { writing-mode: horizontal-tb; ... }
html.hrtl { writing-mode: horizontal-tb; ... }

/* pre: OPF メタ由来の補い。**クラスを持たない文書にだけ**効かせる */
html:not(.vrtl):not(.vltr):not(.hltr):not(.hrtl),
html:not(...) > body { writing-mode: vertical-rl; ... }

/* post: 強制モード（本の指定に必ず勝たせる） */
html, body { writing-mode: vertical-rl !important; ... }
```

**注意点（設計理由）**

- クラス CSS を `body` でなく **`html` にだけ**当てる。`writing-mode` は継承するので body へ届くが、
  body に直接当てると本が body に書いた指定を詳細度で踏み潰してしまう。
- OPF メタ由来の補いはクラスを持たない文書に限定する。**縦書き本でも前付け・奥付は
  `hltr`（横組み）のことがあり、本全体を縦書きにすると壊れる。**
- 強制モード（vertical/horizontal）は `!important` 付きで post に置く。

**書字方向の切り替え（`setWritingMode`）**

CSS を差し替えるだけでは既に組まれたページは変わらない。
**現在位置（CFI）を保ったまま本を開き直して組み直す。**
CFI は「ホスト側が relocate で受けている最新値」を優先する（JS の `lastLocation` は
画像面を自前描画しているページで欠けることがある）。

### 8.4 綴じ方向（bookDir）の決定 — 最も繊細なロジック

**なぜ難しいか**

- `spine@page-progression-direction`（ppd）は、横組みへ変換された本でも `rtl` のまま残る。
  信じると横組みの本でページ送りだけが逆を向く。
- しかし ppd を捨てると多数の本が「本文を一度描くまで縦書きか分からない」状態になる
  （実測: 書棚 37 冊で ppd は 37 冊全部が持つのに対し、primary-writing-mode は 14 冊のみ）。
- 表紙・前付けは横組みで作られていることが非常に多い。開いた直後に測ると誤判定する
  （青空文庫由来の本 10 冊すべてで、表紙は縦書き指定なしの `cover.css` のみを読み、
  本文は `nsepub-v.css` で縦書きにしていた）。
- 漫画・写真集は**全ページが画像 1 枚**で、向きの手がかりが原理的に存在しない。
  OMF では spine が JPEG を直接指すので、iframe に載るのは WebKit が画像用に作る文書。
  その body は必ず `horizontal-tb / ltr` になる——本の綴じ方とは無関係の値である。

**アルゴリズム**

```
状態: bookDir ∈ {ltr, rtl}, bookDirConfirmed: Bool

【本を開くとき】
  forcedBinding != auto → bookDir = forcedBinding, confirmed = true
  else if writingMode == vertical または (auto かつ OPF hint == vertical)
                        → bookDir = rtl, confirmed = true
  else if writingMode == horizontal または (auto かつ OPF hint == horizontal)
                        → bookDir = ltr, confirmed = true
  else                  → bookDir = (ppd == "rtl" ? rtl : ltr), confirmed = false  ← 暫定値

【章が表示されるたび（relocate）】noteSectionDirection(doc):
  vertical = isVerticalDoc(doc)
  if forcedBinding != auto:
      bookDir = forcedBinding; confirmed = true
      return { vertical, dir: forcedBinding }        ← 章ごとの dir も強制値で返す
  dir = pageDirection(doc)
  if dir == rtl:
      bookDir = rtl; confirmed = true                ← 縦書き/RTL を一度でも見たら確定
  else if !confirmed && !isFrontOrBackMatter(doc) && hasDirectionEvidence(doc):
      bookDir = ltr; confirmed = true                ← 本文が横組みなら ppd は残骸だった
  return { vertical, dir }
```

**補助判定**

```
isVerticalDoc(doc)   = getComputedStyle(doc.body).writingMode ∈ {vertical-rl, vertical-lr}
                       （documentElement ではなく **body** を見る）

pageDirection(doc)   = isVerticalDoc → "rtl"
                       else body の computed direction / body.dir / html.dir が rtl → "rtl"
                       else "ltr"
                       （**ppd は見ない**）

isFrontOrBackMatter(doc):
  documentElement / body / body の最初の子 / 最初の section|div のいずれかの
  epub:type（名前空間付き属性も見る）または role が次にマッチしたら true:
    cover|toc|landmarks|frontmatter|backmatter|titlepage|halftitlepage|colophon|
    copyright-page|imprint|dedication|acknowledgments|bibliography|index

hasDirectionEvidence(doc):
  doc.contentType が image/* なら false
  body の textContent から空白（半角/全角）を除いた長さ > 10 なら true
```

**実害の記録**: 章ごとの向きでページ送りの左右を決めると、縦書きの本でも横組みの前付けに
いる間だけ左右の意味が反転し、**表紙と本文 1 ページ目を往復するだけで奥付へ到達できなくなる**
（青空文庫『吾輩は猫である』上篇自序で発生）。したがって:

- **章ごとの `dir` / `vertical`** … 「いま画面に組まれているもの」。朗読動画の縦横など
  描画そのものを合わせたい用途にだけ使う。
- **本単位の `bookDir`** … 進捗スライダーの鏡像、左右タップ・矢印キーの向きに使う。

### 8.5 ページ送りの解決

```
pageStep(side):
  left     → forward = bookIsRTL
  right    → forward = !bookIsRTL
  next(下) → forward = true
  previous(上) → forward = false
  forward ? next() : prev()
```

**入力とページ送りの対応表**

| 入力 | 経路 | 動作 |
|---|---|---|
| 左端タップゾーン（幅 15%） | ネイティブ → `pageStep(.left)` | 書字方向で解決 |
| 右端タップゾーン（幅 15%） | ネイティブ → `pageStep(.right)` | 同上 |
| ←/→ キー（本文にフォーカスあり） | bridge.js の keydown → `goLeft()`/`goRight()` | foliate が解決 |
| ←/→ キー（フォーカスなし） | ネイティブ keyCommand → `pageStep(.left/.right)` | 書字方向で解決 |
| ↓/↑ キー | どちらの経路も 進む/戻る | 向きに依らない |
| ホイール 1 ノッチ | bridge.js（250ms ロック・閾値 |delta| ≥ 4・X/Y の大きい方を採用） | 正→進む / 負→戻る |

### 8.6 画像だけのページの直接描画

**なぜ必要か**: 画像だけの面を列レイアウトに載せると、本の CSS が付けたラッパ・
SVG 包みの癖・縦組み判定に振り回されて拡大も見開きも安定しない。
**位置の管理（進捗・しおり・CFI）はエンジンに任せたまま、描画だけ引き取る。**

```
画像レイヤー（DOM 上の固定オーバーレイ）:
  position: fixed; inset: 0; display: flex;
  align-items: center; justify-content: center; gap: 0;
  z-index: 3; pointer-events: none; overflow: hidden;
  flex-direction: bookDir == rtl ? row-reverse : row
  background: テーマの地色
  各 img: display:block; height:100%; width:auto;
          max-height:100%; max-width: floor(100 / 枚数)%; object-fit: contain
表示中は foliate-view 自体を visibility:hidden にする
```

**画像面の判定**

```
detectImagePage(doc) = body に img|svg|image があり、
                       かつ body の textContent（空白除去）の長さ ≤ 10
isImageSection(index) = spine 項目の media-type が image/* → true
                        else 章の XHTML を読んで detectImagePage
                        （結果は index ごとにキャッシュ）
```

**spine が画像を直接指す本（OMF）への対応**（見落とすと画像章が全部テキスト扱いになる）:

```
sectionMediaType(index) = book.resources.manifest から
                          href == sections[index].id の item の mediaType
sectionImageSrc(index)  = 画像 spine 項目なら section.load() の戻り（それ自体が絵）
                          else 章 XHTML の最初の img/image の
                               src | xlink:href | "xlink:href" 属性
```

### 8.7 見開きの組み立て（Kindle と同じ考え方）

固定レイアウトでなくても、画像だけのページが続いたら 2 枚ずつ組にして見せる。

```
spreadGroupOf(index) -> { first, partner|null }

  imageSpread == "never"            → 単独
  画像面でない                       → 単独

  ① 本が page-spread-left/right を申告しているか（spine itemref）
     imageSpread != "always" のとき:
       side == leadSide かつ 次面が trailSide かつ次も画像 → { index, index+1 }
       side == trailSide かつ 前面が leadSide かつ前も画像 → { index-1, index }
       それ以外 → 単独（相方のいない面）
     ※ 漫画 EPUB はこれを全面に持っていることが多く、持っているなら組の正解はこれ。
       透明ページの入れ忘れを疑って数え直す必要がない。

  ② 申告が無い本は区間の先頭から数え上げる
     spreadBase(index):
        画像面が連続している区間の開始 index を求め、
        spine 先頭から続く区間なら +1（**表紙は単独**）、
        さらに spreadOffset(0|1) を足す
     base から順に:
        forced = (imageSpread == "always")
        現在の面と次の面が両方「画像」かつ（forced または両方が横長でない）
            → 2 枚組（span=2）
        そうでなければ単独（span=1）
        index が現在の組に入るまで i += span
     ※ 横長画像（縦横比 > 1）は、それ自体が既に見開き 1 枚として描かれている。
       2 枚並べても意味が無いので単独で 1 見開きを占める。
       ただし「常に見開き」指定時は横長かどうかを見ない（粗い本の救済が目的なので機械的に 2 枚ずつ）。

leadSide()  = bookDir == rtl ? "right" : "left"   // 右綴じは右ページが先
trailSide() = 反対側
```

**組の 2 枚目へ直接着地したときの跳ね返し**（しおり・検索から飛んだ場合）:

```
redirectIfSecondPage(index):
  組の 2 枚目なら index-1 へ移動する。
  ただしエンジンはページ送り中の goTo を黙って捨てる（内部ロック）ので、
  最大 12 回・60ms 間隔で粘る。
```

**前後移動の補正**

```
goNext(): friendly かつ 画像レイヤーに partner が出ているなら
            renderer.goTo({index: partner+1})  ← 左ページとして出ている章を飛ばす
          else view.next()
goPrev(): view.prev() したあと、着地先が「組の 2 枚目」ならもう一度 prev()
          （跳ね返しを goTo でやるとページ送りのロックに食われる）
```

**見開きのずらし（`toggleSpread`）**: `spreadOffset` を 0⇄1 でトグルし、組を丸ごと 1 ページずらす。
透明ページの入れ忘れで組がずれた本の救済。

### 8.8 画像のフィット（`fitImages`）

エンジンの `setImageSize` は render のたびに `max-*` を `!important` で入れ直すので、
**こちらも `!important` で、かつ render の後（relocate 時）に上書きする。**

```
pageBox(doc):
  documentElement の computed style から
    colSize = columnWidth
    縦書き → { h: colSize, w: clientWidth - paddingLeft - paddingRight }
    横書き → { h: clientHeight - paddingTop - paddingBottom, w: colSize }
  ※ iframe は全ページ分に引き伸ばされるので innerHeight/Width は使えない

fitImages(doc):
  h = round(pageBox.h)、ホスト表示枠の高さ cap があれば h = min(h, cap)
  各 img/svg について:
    img で未ロードなら load を待って再実行
    isFigureImage(el) でなければスキップ
    ratio = forcedAspect ? (w/h) : naturalRatio(el)
    target = ratio > 0 && pageW > 0 ? min(h, round(pageW / ratio)) : h
    height / max-height = target px !important
    forcedAspect あり:
        width = round(target * ratio) px !important, max-width = 100%, object-fit: fill
        （**収めるのではなく引き伸ばす**。この機能の目的そのもの）
    なし:
        width = (ratio > 0 ? auto : 100%) !important, max-width = 100%, object-fit: contain
        （viewBox の無い svg は固有サイズを持たず width:auto で潰れるので枠いっぱいにする）
  既に同じ target を入れてあるなら何もしない（無限ループ防止）

isFigureImage(el):
  IMG  : naturalWidth/Height が取れており min(w,h) ≥ 200
  SVG  : 描画済み矩形の min(w,h) ≥ 200
  かつ「同じ親の中で自分と行を共有しうるもの（テキストノード + display:inline* な要素）」の
      テキストが空白のみであること（本文中の記号・ロゴを拡大しないため）
  ※ 兄弟のブロック要素は行を共有しないので数えない

naturalRatio(el) = naturalWidth/naturalHeight、無ければ viewBox の w/h、無ければ 0
```

### 8.9 強制アスペクト比

**用途**: 元データの比率がページごとに揃っていない本を揃える。収めるのではなく**引き伸ばす**
（`object-fit: fill`）ので、比率の違う面は歪む——それを承知で揃えたいときの機能。

**既定値の検出**（UI のメニューに「この本の判型」として出すためだけ。表示には影響しない）

```
detectBookAspect(book):
  OPF の meta で property|name が "viewport" で終わるものを探し、
  content/textContent から /width\s*=\s*(\d+(\.\d+)?)/ と /height\s*=\s*.../ を抜く
  （OMF は omf:viewport、EPUB3 固定レイアウトは rendition:viewport に
    "width=844, height=1200" の形で入る）

無ければ fillAspectFromFirstImage():
  先頭 8 章までを走査し、最初に見つかった画像章の実寸（naturalWidth/Height）を採る
  取れたら display メッセージでホストへ追って通知する
```

画像レイヤー側の適用（`layoutImageLayer`）:

```
強制なし: width:auto; height:100%; max-width: floor(100/枚数)%; max-height:100%; object-fit:contain
強制あり: boxW = layer.clientWidth / 枚数, boxH = layer.clientHeight
          ratio = ar.w / ar.h
          w = boxH * ratio, h = boxH
          if w > boxW: w = boxW, h = boxW / ratio
          width/height を px で固定、max-* を none、object-fit: fill
※ CSS の aspect-ratio だけで当てると、幅の上限に当たったとき高さが追従せず比率が崩れる。
  枠を実測して px で入れる。window resize で再計算する。
```

### 8.10 本文の見開き

**横書きと縦書きで効かせるところがまったく違う。**

```
横書き: 列数で決まる。paginator は既定で「横長の画面なら 2 列・縦長なら 1 列」に切り替える。
        auto   → 何もしない（エンジンに任せる）
        always → max-column-count = 2 かつ max-column-count-portrait = 2
        never  → 両方 1
        ※ どちらの向きでも固定したいので portrait 用の変数も一緒に倒す。

縦書き: 列数を増やしても見開きにならない。CSS の多段組は列を inline 方向へ積むので、
        縦書き（inline = 上下）では列が上下に並び、「上段が1ページ・下段が次のページ」という
        紙とは似ても似つかない形になる。
        縦書きの 1 ページは block 方向（右→左）の幅で決まるので、
        **本文ブロックの幅そのものを広げる**:
        always → max-block-size = 2880px（paginator 既定 1440px の 2 倍＝紙の見開き 1 面ぶん）
        never/auto → 既定に戻す（縦書きの既定は元々 1 ページぶんの幅）
        画面より広ければ paginator のグリッドが頭打ちにするので、狭い窓でも破綻しない。
```

適用は「`textSpread` と章の縦横」の組をキーにして、変化したときだけ行う
（`render()` を呼び直すと組版がやり直しになるため）。

### 8.11 SVG 表紙の潰れ補正

calibre 変換 EPUB の表紙は
`<svg width="100%" height="100%" preserveAspectRatio="none"><image .../></svg>` が定番。
`none` は「比率を無視してボックスいっぱいに伸ばせ」の意味なので、エンジンは指示どおりに
描いて表紙が縦に潰れる。**CSS では直せない**（`preserveAspectRatio` は CSS プロパティではなく、
`object-fit` は SVG 要素に効かない）。

```
normalizeSVGImages(doc):
  svg[preserveAspectRatio], image[preserveAspectRatio] のうち
  値が /^none\b/i にマッチするもの（"none slice" のような meetOrSlice 付きも対象）を
  "xMidYMid meet" に書き換える。元の値は要素に退避しておき、raw モードで復元する。
```

### 8.12 ぶら下げインデントの補正

日本語の本は章見出しを `text-indent: -5.2em` と `padding-top: 5.2em` の対で組むことが多い。
縦書きでは `padding-top` が行の先頭側なので負のインデントをちょうど打ち消すが、
**横書きで描くと `text-indent` は左へ効くのに padding は上のままなので、打ち消しが外れて
見出しが枠の外へ飛び出す**（実本の章扉で 79px はみ出すのを実測）。

```
fixHangingIndent(doc):   // 1 文書につき 1 回だけ。書字方向が確定した後（relocate）に呼ぶ
  vertical = isVerticalDoc(doc)
  body の全要素について:
    indent = computed textIndent
    indent >= -4px なら対象外
    need = -indent
    start = vertical ? "Top" : (direction == rtl ? "Right" : "Left")   // 行の先頭側
    padding[start] が need ± 2px 以内なら既に正しい → 何もしない
    他の 3 辺のうち need ± 2px のものを探す（= 対になっている物理 padding）
    見つかれば padding-<start> に need px !important を入れる
  対の padding を持たない負インデントは本来のぶら下げ組みなので触らない
```

逆向き（横書き前提の本を縦書きで読む）にも効く。

### 8.13 目次

```
tocToJSON(items, prefix=""):
  id = 階層位置（"0.2.1"）        ← href は本の中で重複しうるので識別子に使わない
  label = 文字列 or 多言語辞書の最初の値、トリム
  href
  subitems = 再帰
```

**リンク切れの救済**（friendly のみ）: 変換を経た本では、spine から外れたファイルを目次が
指したまま残ることがある（calibre が表紙を差し替えると目次の「表紙」だけ古い `c0.xhtml` を
指し続ける等）。そのままだとその項目だけ黙って反応しない。

```
goToTarget(target):
  view.goTo(target) が成功したら終わり
  失敗して friendly なら guessSectionFor(target):
    ① href のファイル名（クエリ/フラグメント除去）と一致する section があればその index
    ② 目次内での位置 pos を求め、
       pos == 0 なら spine 先頭（たいてい表紙）
       それ以外は pos-1 から遡り、解決できる項目が見つかったら「その次の章」へ送る
    ③ 見つからなければ 0
  renderer.goTo({index, anchor: 0})
```

### 8.14 検索

```
runSearch(query):
  実行中の検索があれば中断フラグを立てる
  view.search({query, matchCase:false, matchDiacritics:false, matchWholeWords:false})
  結果は非同期イテレータ。subitems の各 {cfi, excerpt} を
    searchHit { cfi, pre, match, post } として逐次ホストへ送る
  **上限 500 件**で打ち切る
  終了時 searchDone { count }
```

ハイライトは検索実行時にエンジンが張る（`clearSearch()` で消す）。

### 8.15 注釈のハイライト色

```
TTS のハイライト  : rgba(255, 235, 59, 0.5)   （黄）
検索のハイライト  : rgba(66, 133, 244, 0.4)   （青）
```

### 8.16 位置の保存

- `relocate` で受けた `cfi` を最新値として保持し、`fraction` を進捗に反映する。
- 位置保存は `relocate` のたび＋リーダーを閉じるときに行う。
- 保存内容: `locatorJSON = cfi`、`lastOpenedAt = 現在時刻`、`progress = clamp(fraction, 0, 1)`。
- `fraction` は稀に NaN や 0…1 外になる。**スライダーへ渡す前に有限値へ丸めてクランプする**
  （そのまま渡すとアサーション失敗でクラッシュする）。

---

## 9. リーダー UI

### 9.1 画面構成

```
┌─────────────────────────────────────────────────────────────┐
│[しおり]│[目次]│  ┌─ 本文（常にウィンドウ全面）─┐  │ 対訳ペイン │
│ 260pt │280pt│  │                              │  │ 可変(既定460)│
│       │     │  │  ← 上下バーはこの上に重ねる  │  │ 280–900     │
└─────────────────────────────────────────────────────────────┘
```

**本文は常に全面**。操作パネル（上下バー）は重ねるだけで、出入りしても本文が
再レイアウトされない（＝ページ割・文字の流し直しが起きない）。これは必須要件。

### 9.2 操作パネルの自動表示（Kindle 風）

```
定数:
  上バーの反応帯   = 本文ビュー上端から 72pt
  下バーの反応帯   = 本文ビュー下端から 110pt
  非表示時のホバー帯 = 6pt（ネイティブのホバー認識が主経路。これは補助）
  消すまでの遅延   = 220ms
  アニメーション   = 0.18s（バー）/ 0.2s（サイドバー・ペイン）

状態: pointerTop/pointerBottom（本文上のポインタ）, hoverTop/hoverBottom（パネル自身の上）
  出す: いずれかが true になったら即座
  消す: 両方 false になってから 220ms 待ち、その時点の最新状態で再判定
        （本文からパネルへポインタが移る一瞬、どちらのホバーも切れるため）
  音声/動画の保存中は下バーを出したままにする（進捗表示が要る）
```

### 9.3 上バー

```
[< 書棚] ……… タイトル ……… [操作アイコン列]
```

操作アイコン列（左から）:

| アイコン | 動作 | ツールチップ |
|---|---|---|
| `wand.and.sparkles` / `chevron.left.forwardslash.chevron.right` | 表示モード往復 | 現在のモードを表示 |
| 綴じ方向アイコン | 押下=次の値へ巡回 / 長押し=メニュー | 「綴じ方向: 自動（いまは右綴じ）」等 |
| 画像見開きアイコン | 同上 | 「画像ページの見開き: 自動」 |
| 本文見開きアイコン | 同上 | 「本文の見開き: 自動」 |
| 比率アイコン | 押下=「本の判型で固定」⇄「解除」/ 長押し=判型メニュー | 「比率を 844:1200 に固定中」 |
| `rectangle.lefthalf.inset.filled` | 見開きをずらす（固定レイアウトまたは画像ページのときだけ表示） | |
| `magnifyingglass` | 検索シート | |
| `character.bubble` | 対訳ペイン開閉 | |
| `character.book.closed` | 読み上げ辞書シート | |
| `bookmark` | しおり追加 | |
| `list.bullet` | しおりサイドバー | |
| `list.bullet.indent` | 目次サイドバー | |
| 書字方向アイコン | メニュー（auto/vertical/horizontal） | |
| `textformat.size` | 文字サイズ・配色・カスタム CSS・音声保存のメニュー | |
| `gearshape` | 設定シート | |
| `ruler` | 測定グリッド切替 | |

**「押下で巡回・長押しでメニュー」の二段構え**は、本のデータから決められない値
（綴じ方向・見開き・比率）に共通の操作系。値は本ごとに記憶する。

サイドバーはしおりと目次が排他（片方を開くともう片方を閉じる）。

### 9.4 下バー

```
┌ 進捗 ────────────────────────────────────┐
│ [────────●─────────]  42%                │  ← RTL の本では鏡像化
├ 読み上げ ────────────────────────────────┤
│      [▶/⏸] [⏹] [🎵保存] [🎬動画]   status │
└──────────────────────────────────────────┘
```

- スライダーの鏡像は **本単位の `bookIsRTL`** で決める（章ごとの値だと前付けと本文を
  行き来するたび摘みが左右へ飛ぶ）。
- ドラッグ中は値を反映せず、**離した時点でシーク**する。
- ボタン群は中央固定。status を同じ行に入れると文字数の増減でアイコンの中心がずれるので、
  **レイアウトに影響しないオーバーレイ**として右端に置く（最大幅 260、1 行、末尾省略）。
- 各ボタンは進捗表示に差し替わっても外形が変わらないよう固定サイズ。

**ボタンの活性条件**

| ボタン | disabled 条件 |
|---|---|
| 再生/一時停止 | エンジン未準備 |
| 停止 | 停止対象なし（`canStop == false`） |
| 音声保存 | エンジン未準備 or 音声保存中 or 動画保存中 or 読み上げ中 |
| 動画保存 | 同上 |

### 9.5 左右タップゾーン

```
幅 = ビュー幅の 15%（左右それぞれ）
ホバー時: chevron（pointSize 32, semibold, secondaryLabel 色）を alpha 0.9 で 0.15s フェード表示
押下時  : 背景 = label 色の 5%
ホバー位置は親へ転送する（操作パネルの自動表示に使う）
```

### 9.6 キーボードショートカット

| キー | 動作 |
|---|---|
| ⌘O | ファイルを開く |
| ← / → | ページ送り（書字方向で解決） |
| ↓ / ↑ | 進む / 戻る |
| Space | 読み上げ 再生/一時停止 |
| Return / Esc | 読み上げ 停止 |

Space/Return/Esc は **bridge.js の keydown（本文にフォーカスあり）とネイティブの
レスポンダチェーン（フォーカスなし）の両方から届く**。同じアクションが 0.3 秒以内に
続けて来たら 2 回目を捨てる。

### 9.7 右クリックメニュー

本文で語を選択して右クリックすると、システムのメニュー（コピー等）の先頭に
**「読み上げ辞書に登録」**を挿入する。選択が空のときは項目を出さない。
判定には JS 往復ではなく `selectionchange` で同期しておいた値を使う（メニュー構築は同期呼び出しのため）。

### 9.8 しおりサイドバー（幅 260）

```
「しおり」 [閉じる]
[現在地をしおり]  ← 幅いっぱいの主要ボタン
一覧（行 = 「42% / （本文位置） / 作成日」、タップで移動、スワイプ/メニューで削除）
空のとき: 「しおりはありません。」
```

### 9.9 目次サイドバー（幅 280）

- 階層は折りたたみ可能。**現在読んでいる章を含む枝は最初から開いておく。**
- 現在章の行はアクセント色 + セミボールド。
- 子を持つ項目も見出し自体をタップで飛べる。
- ラベルが空なら「（無題）」、最大 3 行。

### 9.10 検索シート

最小 460×500。テキスト欄（0.3 秒後に自動フォーカス）、実行は Enter。
結果行は「前文脈（薄色）+ 一致（太字）+ 後文脈（薄色）」、最大 2 行。
選択すると位置へジャンプしてシートを閉じる。

### 9.11 カスタム CSS エディタ

- スコープ切替: 「この本だけ」/「全書籍」（セグメント）
- 本別 CSS は共通 CSS の**後**に注入されるので共通を上書きできる
- 定型スニペットをボタンで挿入できる（合成入力が効かない環境でも無タイプで編集可）:
  行間広め / 字間 / 本文色 / 明朝→ゴシック / 段落間
- 「保存」で永続化 + 現在ページへ即反映、「クリア」で空に、「閉じる」で破棄

### 9.12 読み上げ辞書シート

```
一覧: レイヤー降順にセクション分け（= 実際に適用される順）
      同レイヤー内は表記の長い順
行  : 表記 → 読み  [境界マーク][パターン][無効]  （無効な行は 50% 不透明）
末尾: [＋語を追加]
      説明: 「上のレイヤーから順に置き換え、置き換えた部分は下のレイヤーでは触りません。
              長い語を上に置けば、1文字の語に食われません。読み上げにだけ効き、
              画面表示は変わりません。」
テスト欄: 文を入れるとその場で適用結果を表示
```

編集フォーム:

| 項目 | 内容 |
|---|---|
| 照合 | 語 / パターン（セグメント） |
| 表記 | 語なら「本文中の書き方（例: 斎ひとし）」、パターンなら正規表現。不正な正規表現は警告（その行は無視される） |
| 読み | 語なら「カタカナで入力（ひらがな可）」、パターンなら「$1 で捕捉を参照」 |
| レイヤー | 1…10 のステッパー |
| 前後に区切りを入れる | トグル |
| 有効 | トグル |
| 操作 | 登録/保存（表記・読みが両方必須）、既存なら削除 |

---

## 10. 読み上げ（TTS）

### 10.1 全体像

```
本文（エンジン）
   │ SSML（mark 区切り）
   ▼
文リスト [{mark, text}]
   │ 読み辞書を適用（表示は原文のまま）
   ▼
PreparedSpeech { text, injectedGaps }
   │ audio_query → (speed/pause 適用 + 挿入境界の無音化) → synthesis
   ▼
WAV → 再生 / 連結して保存 / 動画の音声トラック
```

### 10.2 読み辞書（このアプリ独自の中核機能）

**なぜ音声エンジンのユーザー辞書を使わないか**

エンジンの辞書は形態素解析のコストで語を選ぶため、**短い登録語が長い熟語を食い荒らす**。
「斎」1 文字の読みを登録すると「斎藤」まで巻き添えで読み替わる。優先度を指定しても、
それは解析コストの調整であって「置換する順番」ではないので、この事故は原理的に防げない。

**解法: レイヤー付きの前処理**

```
ReadingDictionary の構築:
  enabled かつ surface が非空のエントリだけを採る
  並び順 = レイヤー降順 → 同レイヤーは surface の文字数の降順
  各エントリをコンパイル:
    kind=word    → surface を正規表現エスケープ、読みもテンプレートエスケープ
                    （$ を含んでも捕捉参照と誤解させない）
    kind=pattern → surface をそのまま正規表現、読みをそのままテンプレート（$1 が使える）
    読みは**ひらがな→カタカナ変換**しておく（U+3041–U+3096 に +0x60）
  コンパイルに失敗するエントリは黙って除外する（適用時に落ちない）

適用 prepare(raw):
  segments = [{text: trim(raw), locked: false}]
  各エントリについて（上の順で）:
    locked でない断片だけを走査し、一致部分を「読みに置換して locked=true」、
    非一致部分は locked=false のまま。
    padsBoundary が true なら読みの前後に境界マーカー U+E000 を挿入する
  → 一度置換した領域は以降のレイヤーで決して触られない
```

**境界マーカーと無音化**

境界に空白を入れると隣接語との結合解析は断ち切れるが、代わりに約 0.45 秒の無音が入って
朗読が途切れる。そこで「挿入した境界だけを無音化」する。

```
1. 置換の途中では私用領域文字 U+E000 を使う（普通の空白にすると原文由来の空白と区別できない）
2. 連結後、gapRuns() で「ポーズを生む区切りの範囲」を先頭から順に列挙し、
   その中で「境界マーカーを含み、かつ全体が空白類だけ」の run の**序数**を記録する
   （読点などが隣接していたらそちらのポーズを尊重して無音化しない）
3. マーカーを半角空白へ置換して最終文字列にする
   （マーカーも空白として数えていたので、置換しても区切りの並びは変わらない）
4. audio_query の応答で、pause_mora を持つ accent_phrase を先頭から数え、
   記録した序数に一致するものの vowel_length を 0 にする
   ※ 数え方が食い違ったら（pause 数 ≠ gapRun 数）何もしない（無音が残るだけで読みは壊れない）
```

**区切りの数え方（VOICEVOX 0.25.1 で実測した癖）**

```
区切り文字: 、 。 ！ ？ … ‥ ― — 全角空白 半角空白 U+E000
無視文字  : \n \r \t（ポーズも生まず、読む文字でもない）

gapRuns(text):
  区切り文字の連続を 1 つの run にまとめる（連続した区切りは 1 つのポーズに潰れる）
  その run より前と後の**両方**に「読み上げられる字」があるときだけ run を採用する
  （前後どちらかに読む文字が無い区切りはポーズを生まない＝文頭・文末の句点）
```

### 10.3 VOICEVOX / AivisSpeech API 契約

両者は API 互換。**baseURL のポートを変えるだけで両対応**（VOICEVOX `:50021` / AivisSpeech `:10101`）。

| API | メソッド | 用途 |
|---|---|---|
| `GET /version` | — | 接続確認（JSON 文字列で版数） |
| `GET /speakers` | — | `[{name, styles:[{name, id}]}]` を平坦化して「四国めたん / ノーマル」の形にする |
| `POST /audio_query?text=…&speaker=…` | ボディなし | クエリ JSON |
| `POST /synthesis?speaker=…` | クエリ JSON（Content-Type: application/json） | WAV バイト列 |

**合成の手順**

```
1. audio_query を取る
2. query.speedScale = 設定値
   query に pauseLengthScale キーがあれば = 設定値（無いエンジン版もあるので存在確認する）
   挿入境界の pause_mora.vowel_length を 0 にする（10.2）
3. その JSON を synthesis へ POST
4. 返った WAV を再生 or 保存
   ※ 動画生成では **synthesis に送ったのと同一の query** も返す（字幕タイミングと音声が一致する）
```

**平文 HTTP への接続許可**が要る（macOS の App Transport Security では
`NSAllowsLocalNetworking = true`）。

### 10.4 再生ループ

```
startTTS(mode):
  最新の音声設定を読み直す（設定シートの変更を再起動なしで効かせる）
  block = await ttsStart(mode)          // mode: "visible" | "selection" | "resume"
  while not cancelled:
      block が配列でなければ終了（null = 本の終わり）
      各文について:
          text をトリム、空ならスキップ
          mark があれば ttsMark(mark)   // ハイライト + 画面外なら自動送り
          読み辞書を適用して合成・再生し、**再生完了まで待つ**
          エラー時は status に「読み上げエラー: … （VOICEVOX起動確認）」を出して終了
      200ms の段落間休止
      block = await ttsNextBlock()
  ttsStop() でハイライトを消す
```

**モードの意味**

| mode | 開始位置 |
|---|---|
| `visible` | いま表示しているページの可視範囲の先頭（再生ボタン） |
| `selection` | 選択範囲の先頭。選択が無ければ本の先頭（ダブルクリック） |
| `resume` | 一時停止位置 |

**ダブルクリックからの開始**: WKWebView の単語選択が確定するのを **250ms 待ってから** 開始する。

**一時停止/再開**: 再生中のタスクがあれば、プレイヤーの pause/resume だけを行う
（文の途中位置が保持される）。タスクが無ければ `visible` で新規開始。

### 10.5 SSML → 文リスト

```
ssmlToSentences(ssml):
  XML としてパース。パース失敗なら []
  文書を走査:
    テキストノード/CDATA → 現在の文へ追記
    <mark name="…">      → 現在の文が非空なら確定して出力し、新しい文を name で始める
    <break>              → 改行を追記して中を再帰
    その他の要素          → 中を再帰
  末尾の文を確定
  各文の連続空白を 1 個の空白へ正規化してトリムし、空の文を捨てる
```

---

## 11. 音声ファイル書き出し

### 11.1 セクション（章）単位の書き出し

```
1. ttsCollectSection() で現在章の全文を収集する
   （tts.start() → tts.next() で SSML を列挙するだけ。setMark を呼ばず view.next() も
     呼ばないので、ハイライトも自動送りも起きず**表示ページは動かない**）
2. 各文に読み辞書を適用して合成（進捗を「音声を合成中… 3 / 128」で表示）
3. WAV を連結して 1 本にする
4. 保存先へ書き出す
```

ファイル名: `<本のタイトル（60文字まで・/\:*?"<>| を _ に置換）> <yyyyMMdd-HHmmss>.<ext>`

保存先: 設定の保存先ディレクトリ、未設定なら `~/Downloads`（存在しなければ作成）。

### 11.2 WAV の連結

```
parse(wav): RIFF/WAVE を検査し、チャンクを走査して `fmt ` と `data` の本体を取り出す
            チャンクは偶数境界に整列（奇数サイズなら 1 バイトのパディングを飛ばす）
concatenate(wavs): 最初の fmt を採用し、全 data を連結して RIFF を組み直す
build(fmt, pcm):
  riffSize = 4 + (8 + fmtSize) + (8 + dataSize)
  "RIFF" <riffSize LE32> "WAVE" "fmt " <fmtSize LE32> <fmt> "data" <dataSize LE32> <pcm>
```

### 11.3 WAV のタイムライン合成（動画の音声トラック用）

連結と違い、**各行を指定の開始秒に配置する**（行間の無音ぶんを開ける）。
これにより動画の字幕掃引（同じ開始秒を使う）と音声がぴったり合う。

```
compose(lines: [(wav, start)], totalDuration, tail = 0.4):
  最初の WAV の fmt から channels / sampleRate / bits を読む（**16bit PCM 前提**）
  出力フレーム数 = (totalDuration + tail) * sampleRate + 1
  Int16 バッファをゼロ初期化し、各行の PCM を start*sampleRate*channels の位置へ加算
  （範囲外は捨てる。重なりは飽和クランプ）
  fmt を流用して RIFF を組み直す
```

---

## 12. 朗読動画書き出し

「読んでいる箇所だけが発光する縦書きの朗読動画」を MP4 で出力する。

### 12.1 役割分担（この分割は制約から必然的に決まる）

| 工程 | 担当 | 理由 |
|---|---|---|
| VOICEVOX 通信 | **ネイティブ** | ブラウザから `foliate://` オリジンで fetch すると CORS(403)/ATS で弾かれる |
| Canvas 2D 描画 | **WebView（オフスクリーン）** | 縦書きの字形配置を Canvas で自前に組む |
| 動画エンコード | **ネイティブ** | 素の WKWebView は `MediaRecorder` / `canvas.captureStream` を持たない |
| 音声の配置・mux | **ネイティブ** | 音声を WebView へ往復させない |

**この方式はオフライン（リアルタイム録画不要）で決定的**である。

### 12.2 パイプライン

```
1. ttsCollectSection() で章の全文を収集
2. 各行に読み辞書を適用（再生・音声保存と同じ読みになる）
3. 各行をネイティブで合成 → (queryJSON, wav) を得る
4. harness に prepare(payload) を投げる
     payload = { lines:[{text, query}], orientation, fontSize, width, height,
                 bg, fg, accent, fontFamily }
     戻り    = { ok, totalDuration, lineStarts:[各行の開始秒] }
5. 各行の WAV を lineStarts に配置して 1 本の WAV に合成（11.3）
6. frame(t) を fps ぶん呼び、JPEG data URL を受け取り、
   デコード → ピクセルバッファ → H.264 で無音動画を書き出す
7. 無音動画 + WAV を mux して MP4 にする
8. 保存先へ書き出す
```

**性能上の必須要件**: エンコード処理をメインスレッドで回すと、書き出し中ずっと UI が固まる。
**メインスレッドに乗せてよいのは「1 フレーム 1 回の JS 呼び出し」だけ**にし、
デコード・ピクセルバッファ生成・エンコード投入はバックグラウンドで行う。

### 12.3 パラメータ

```
向き    : 本文が縦書きなら縦動画、横書きなら横動画（章ごとの vertical を使う）
サイズ  : 縦 720×1280 / 横 1280×720
fontSize: 48
fps     : 24
行間無音 GAP = 0.15 秒（**ネイティブの音声配置と JS のタイムラインで同じ値を使うこと**）
フレーム数 = max(1, (totalDuration + 0.3) * fps)
JPEG 品質 = 0.92
フォント  = 'Hiragino Mincho ProN', 'YuMincho', serif
```

配色:

| theme | bg | fg | accent |
|---|---|---|---|
| dark（既定） | `#0a0a0f` | `#f5f5f5` | `#00d0ff` |
| light | `#ffffff` | `#1a1a1a` | `#e0a020` |
| sepia | `#f4ecd8` | `#5b4636` | `#c0803a` |

### 12.4 タイムライン計算

```
1 モーラの尺 = consonant_length + vowel_length（consonant は無いことがある）

computeLineDuration(query):
  sum = prePhonemeLength + postPhonemeLength
  各 accent_phrase について:
     全 mora の尺を加算
     pause_mora があれば その尺 × pauseLengthScale を加算
  return sum / speedScale

computeMoraTimings(query):
  t = prePhonemeLength / speed から開始し、各モーラの [start, end] を積む
  pause_mora の分は t を進めるだけ

assignCharTimings(chars, query):
  speech0 = 最初のモーラの start（モーラが無ければ prePhonemeLength）
  speech1 = 最後のモーラの end（無ければ行の尺）
  span = max(1e-3, speech1 - speech0)
  n = max(1, 文字数)
  i 番目の文字 → [speech0 + span*i/n, speech0 + span*(i+1)/n]
  ※ 原文（漢字混じり）とモーラ（カナ読み）は 1:1 対応しないので、
     「行の発話区間を可視文字数で線形に割る」——カラオケ字幕の王道。

タイムライン全体:
  cursor = 0
  各行: start = cursor, 尺 = computeLineDuration, 文字時刻を cursor でオフセット
        cursor += 尺 + GAP
  totalDuration = cursor
```

### 12.5 縦書きレイアウト（Canvas には縦書き機能が無いので自前で組む）

**文字分類**

| 種別 | 対象 | 処理 |
|---|---|---|
| 句読点 | `、。，．､｡,.` | 回転せず、セル**右上**へ寄せる（dx +0.28em, dy −0.34em） |
| 小書き仮名 | `ぁぃぅぇぉっゃゅょゎゕゖ` とカタカナ対応 | 右上へ少しずらす（dx +0.12em, dy −0.12em） |
| 回転 | 長音・各種ダッシュ・波ダッシュ・各種括弧・三点リーダ・`=` | **90° 回転** |
| 通常 | それ以外 | そのまま |

**行頭禁則**（列の先頭に置いてはいけない約物）:
`、。，．」』）)】〕］｝〉》！？!?ー…‥・ゝゞ` + 小書き仮名。
列頭に来る場合は直前列の末尾へぶら下げる（1 文字だけの簡易対応）。

**座標計算**

```
cell   = fontSize * 1.02   （文字送り）
colW   = fontSize * 1.9    （列送り / 横書きなら行送り）
margin = fontSize * 1.2
行（文）の間に空ける列 = 0.6 列

縦書き: rowsPerColumn = floor((viewH - 2*margin) / cell)
        列は右→左（ワールド座標は colX が大きいほど右へ進む。描画時に反転）
        グリフ: colX = globalCol * colW
                rowY = margin + r * cell + cell/2
横書き: colsPerRow = floor((viewW - 2*margin) / cell)
        グリフ: colX = margin + k*cell + cell/2（実座標）
                rowY = globalRow * colW
空行は 1 列（行）ぶんの余白として消費する
```

### 12.6 発光描画

```
readingHead(glyphs, t) → 読み位置（グリフ index の実数）
  t が最初の start 以前 → 0
  t が最後の end 以降   → 最終 index
  あるグリフの [start,end] 内なら i + 進行率
  グリフ間のギャップなら i + ギャップ内の進行率（滑らかに移動させる）

スクロール:
  縦書き: 画面 x = 画面幅 - (colX - scrollX)、読み位置を画面幅の 60% に置く
          scrollX = headX - 画面幅 * (1 - 0.6)
  横書き: scrollY = headY - 画面高 * 0.6

各グリフの描画:
  d = グリフ index - 読み位置
  intensity = exp(-(d²) / (2 * 1.9²))            ← ガウス減衰
  readPast  = 既読なら 1
  opacity   = 0.26 + (1 - 0.26) * max(intensity, readPast * 0.18)
  色        = intensity > 0.15 ? accent : fg
  intensity > 0.04 なら shadowColor=accent, shadowBlur = 22 * intensity
  座標へ translate、回転指定があれば +90°、オフセット（em 相対）を掛けて fillText
  画面外（±colW を超える）は間引く
```

---

## 13. 対訳（LM Studio）

### 13.1 方針

**本文（原文）はそのまま左に残し、訳を右のペインに出す。**
foliate の列レイアウトへ訳文を割り込ませると、画像ページ・見開き・縦書きの組みと
衝突して破綻するため。結果として「左＝原書 / 右＝訳」というレイアウトになる。

翻訳リクエストは**必ずネイティブから出す**（WebView からローカル LLM へは
CSP(connect-src) でも CORS でも届かない。VOICEVOX で実証済みの制約）。

### 13.2 段落抽出

```
セレクタ: p, h1..h6, li, blockquote, dd, dt, figcaption, td, th, pre
入れ子（li の中の p 等）は**内側だけ**採る（両方採ると同じ文を二度訳す）
可視範囲の判定: lastLocation.range と交差するものだけ（TTS の visible と同じ根拠）
テキストは連続空白を 1 個に正規化してトリム。空はスキップ
各段落の CFI を取る（取れなくても訳は出せる）
重複キー（CFI、無ければ連番+本文）を除去
上限 40 段落（1 画面に収まる段落は普通 10 前後。これに掛かるのは抽出がおかしいときだけ）
画像だけのページは { passages: [], reason: "image-page" } を返す
```

**翻訳の単位をブロック要素にする理由**: 文で切ると代名詞・主語が消えて訳が壊れ、
セクション丸ごとだとローカル LLM には長すぎて待ち時間が読めなくなる。

### 13.3 翻訳の実行

```
1. 段落を抽出。空なら「このページには訳す本文がありません」/「このページは画像です」
2. モデルを決める: 設定値 → 前回使ったモデル → /v1/models の先頭
   （ページを送るたびに /v1/models を叩かない）
   決まらなければ「LM Studio に接続できません。設定 →「翻訳（LM Studio）」で
   URL とモデルを確認してください。」
3. キャッシュから即座に埋める（force 指定時は無視）
4. 残りを concurrency（1–8、既定 2）ずつ束ねて投げ、終わった行から順にペインへ出す
5. 全件が接続エラーならページ全体のエラーとして表示する
ページ送りのたびに 400ms のデバウンスをかけて取り直す（連打で毎回 LLM を叩かない）
```

### 13.4 API 契約（OpenAI 互換）

```
GET  <base>/v1/models        timeout 8s
     → data[].id を集め、"embed" を含む id を除外（埋め込み専用モデルは翻訳に使えない）
POST <base>/v1/chat/completions   timeout 300s
     {
       model, temperature: 0.2, stream: false,
       max_tokens: min(4096, max(512, ユーザープロンプトの文字数)),
       messages: [{role: system, ...}, {role: user, ...}],
       chat_template_kwargs: { enable_thinking: false }   // disableThinking のとき
     }
     → choices[0].message.content
base URL は末尾が "v1" なら二重に付けない
```

### 13.5 プロンプト

システム（**指示は英語で書く**。モデルの追従率が素直に高い）:

```
You are a professional literary translator. Translate the given passage from <source> into <target>.

Rules:
- Output ONLY the translation. No preface, no notes, no romanization, no quotation marks around the whole output.
- Translate the passage as a whole; keep the author's tone, register and paragraph structure.
- Keep proper nouns consistent. Do not add or drop information.
- If the passage is a heading or a fragment, translate it as such — do not turn it into a sentence.
```

ユーザー（文脈ありのとき）:

```
[Context — the preceding passage. Do NOT translate this part.]
<直前の段落>

[Passage to translate]
<対象段落>
```

### 13.6 応答のクリーニング

```
1. <think>…</think> を除去（閉じタグが無いまま切れていたら、開始タグ以降を全部落とす）
2. 行頭のラベルを 1 つだけ剥がす:
   "translation:", "translated:", "japanese:", "訳:", "日本語訳:", "翻訳:"（先頭一致・小文字比較）
3. 全体を囲む引用符を外す（"" 「」 “”。内側に閉じ記号が出てこない場合だけ）
4. トリム。空になったらエラー扱い
```

### 13.7 キャッシュ

```
キー = SHA256("<model>|<targetLang>|<原文>") の 16 進表現
上限 4000 件（超えたら挿入順に古いものから落とす）
書き込みは 2 秒のデバウンスで束ねる（段落ごとに数百件の I/O を出さない）
保存先: <AppSupport>/EpubReaderSpike/translation-cache.json
```

### 13.8 対訳ペイン UI

```
┌ ハンドル(8pt・ドラッグで幅変更) ┬ ヘッダ ─────────────────┐
│                                │ 「対訳」[進捗] … [原文表示][A-][A+][再訳][設定][×] │
│                                │ "12 / 18 段落 · <モデルid>"                        │
│                                ├───────────────────────────┤
│                                │ 行: 幅 ≥ 520 なら「原文 | 訳」左右、狭ければ上下   │
│                                │ 状態: 順番待ち / 翻訳中… / 訳文 / エラー(橙)       │
│                                │ 行をダブルクリック → 本文をその段落へ移動          │
└────────────────────────────────┴───────────────────────────┘
幅: 既定 460、最小 280、最大 900（右側にあるので左へ引くほど広くなる）
文字倍率: 0.7–2.0（±0.1）。見出しは原文16pt/訳17pt・セミボールド、本文は14/15pt
```

---

## 14. 測定オーバーレイと QA 基盤

このプロジェクトは **computer-use に頼らない E2E 自動テスト**をコンセプトの一つとしている。
移植先でも同じ仕組みを持たせることを推奨する。

### 14.1 16 色 2 レーンの絶対座標リボン（この符号化が肝）

```
セルサイズ = 10（pt / px）
パレット（16 色・互いに識別しやすい配色）:
  #E6194B #F58231 #FFE119 #BFEF45 #3CB44B #469990 #42D4F4 #4363D8
  #000075 #911EB4 #F032E6 #FABED4 #9A6324 #FFFAC8 #AAFFC3 #A9A9A9

上辺に X 座標、左辺に Y 座標のリボンを敷く:
  下位レーン（0–10px）  色 = palette[cell % 16]        （1 の位）
  上位レーン（10–20px） 色 = palette[(cell / 16) % 16] （16 の位）
  → 端の 2 セルの色を読めば「上位 × 16 + 下位」で絶対セル番号、× 10 で絶対座標が分かる
16 セル（=160px）ごとに黒 60% の境界線を引く（周回の切れ目を分かりやすく）
```

**この符号化の意味**: AI（あるいは人間）がスクリーンショットを見るだけで、
定規を当てずに絶対座標を読み取れる。色帯（目で読む）と数値（コードで測る）の
両方で裏が取れる。

### 14.2 オーバーレイの構成要素

```
・16 色 2 レーンのリボン（上辺 X / 左辺 Y）
・10% 刻みのグリッド線（灰 35%）
・外周枠（ピンク 90%・2px）と四辺の 10% 目盛り（長さ 12）
・中央十字（緑 90%・±24）
・ビューポート寸法テキスト "viewport 1000x680 pt / cell=10pt"
・凡例（0–F の 16 スウォッチ・黒帯の上に白文字）
・原点マーカー（左上に 16px の L 字）
```

**2 実装が同じ配色・同じ符号化を共有する**:

1. **ネイティブ層のグリッド**（WebView の上に半透明で重ねる。非インタラクティブ。
   リリースビルドにも含める＝AI と組み合わせた効率がよいため）
2. **WebView 本文への注入**（DEBUG のみ。canvas で描き、座標を数値で取り出せる）

### 14.3 WebView への注入で踏む罠（WebKit 縦書きの既知バグ）

**WebKit は縦書き RTL のとき `position:fixed; left:0` を「視覚ビューポート原点」ではなく
レイアウトビューポート原点（html 左端。縦書きでは右に寄っている）に固定する。**

回避策:

```
1. まず left:0; top:0 で canvas を置く
2. getBoundingClientRect() で実際の着地点を測る
3. その分だけ負にシフトする（left = -land.left, top = -land.top）
→ canvas ピクセル (x,y) が getBoundingClientRect の (x,y) と一致する
```

また、縦書き横スクロールでは `window.innerWidth` がレイアウト幅（大きい値）を返すので、
**`window.visualViewport.width/height` を使う**。

canvas 自身にも `writing-mode: horizontal-tb; direction: ltr;` を明示する。
`z-index: 2147483647; pointer-events: none;` で最前面かつ透過。

### 14.4 測定 API の戻り値

```json
{
  "viewport": {"w":1000,"h":680,"centerX":500,"centerY":340},
  "imageOnlyPage": true,
  "body": {"x":0,"y":0,"w":1000,"h":680},
  "images": [{
    "tag":"img","x":12.5,"y":0,"w":975,"h":680,
    "right":987.5,"bottom":680,
    "gapLeft":12.5,"gapRight":12.5,"gapTop":0,"gapBottom":0,
    "centerX":500,"centerY":340,
    "leftBand":{"cell":1,"low":1,"high":0},
    "rightBand":{"cell":99,"low":3,"high":6}
  }]
}
```

数値は小数第 1 位に丸める。`band(v) = {cell: round(v/10), low: cell%16, high: floor(cell/16)%16}`。

### 14.5 アプリ内テストバス（DEBUG 限定）

```
プロトコル: 127.0.0.1:<port> に JSONL over TCP
            1 リクエスト = 1 行の JSON、1 レスポンス = 1 行の JSON
既定ポート : 47831。環境変数 EPUB_TEST_BUS_PORT で上書き（1024 以上）
            ワークツリー並行作業のため、パスの SHA1 から 47800–47899 に振り分ける運用
リリースビルドには一切含めない（含まれていないことをビルドスクリプトで検査する）
```

**なぜ必要か**: Accessibility API の唯一の死角が「右クリックの文脈メニュー」で、
これは AX から開けない。加えて、内部状態（判定結果・辞書の適用結果）を
真値で取り出したい。UI テストの本質は「本物のアクションを実行して真の状態を検証する」ことなので、
モデル層に直結したコマンドバスを持たせる。

**コマンド一覧（30 以上）**

| 分類 | コマンド |
|---|---|
| 疎通・書棚 | `ping` / `state` / `open` / `remove` / `setYomi` / `clearYomi` / `openYomiEditor` |
| ページ | `seek` / `goForward` / `goBackward` / `tapLeft` / `tapRight` / `tapDown` / `tapUp` |
| 表示 | `display`（binding/imageSpread/textSpread/aspect の取得・変更）/ `spreadState` / `toggleRenderMode` / `renderMode` / `setTheme` |
| 書字方向 | `writingMode` / `writingModeAuto` / `writingModeVertical` / `writingModeHorizontal` |
| 目次 | `toc` / `toggleTOC` / `tocOn` / `tocOff` / `tocJump` |
| 検索 | `search` / `searchState` / `jumpFirstHit` |
| 辞書 | `setRules` / `applyRules` / `dictList` / `dictAdd` / `dictUpdate` / `dictDelete` / `openDictForm` |
| 対訳 | `translateOn` / `translateOff` / `translateRefresh` / `translateState` / `setTranslation` / `translatePassages` |
| 書き出し | `saveSection` / `saveVideo` / `saveVideoH` / `saveVideoV` / `setSaveDir` |
| 測定・UI | `overlayOn` / `overlayOff` / `measureImage` / `eval` / `pointer` / `chromeState` / `selection` / `addBookmark` / `openSettings` |

**設計上の注意**

- 変更を伴うコマンドは「JS へ投げた変更が返ってくるまで待つ」（例: `display` は 400ms、
  `writingMode` は 1500ms、`tocJump` は 1200ms）。テストが次のアサートへ進む前に確定させる。
- 本の特定は `id` / `title` / `title_contains` のいずれか。
- ハンドラは UI スレッドで実行する。

### 14.6 MCP テストサーバ

| ツール | 用途 |
|---|---|
| `screenshot(app?)` | ウィンドウを**前面化せず** PNG 取得（ユーザーのフォーカスを奪わない） |
| `list_windows()` | オンスクリーンのウィンドウ列挙 |
| `ui_tree(app?, max_depth?, grep?)` | AX 要素ツリー（スクショの代替） |
| `ui_find(selector)` | 一致要素の列挙（pos/size を数値で返す） |
| `ui_action(selector, action)` | AX アクション実行 |
| `ui_set_value(selector, text)` | テキスト欄へ入力 |
| `ui_menu(path)` | メニューバー項目実行（`ファイル>開く`） |
| `ui_overflow(selector, outer?, tol?)` | 枠から各辺で何 pt はみ出すか（正=はみ出し / 負=余白） |
| `measure_overlay(on/off/measure)` | 計りレイヤーの注入と測定 |
| `app_cmd(...)` | テストバスへコマンド送信 |

セレクタ: `role` / `title` / `title_contains` / `desc` / `desc_contains` / `value` / `nth` / `focused`。

### 14.7 基準フィクスチャ（測定用 EPUB）

四辺に目盛りを焼き込んだ画像を持つ EPUB を用意する（`test-assets/ruler/`）。
既知寸法の型紙に対して測ることで、「だいたい合ってる」を
「x=913.2、期待 24±8pt で PASS」という数値と合否に置き換える。

---

## 15. 設定項目の完全一覧

### 15.1 設定シート（保存で確定・閉じるで破棄）

```
┌ エンジン ────────────────────────────────────┐
│ 読み上げエンジン  [VOICEVOX (:50021) ▾]       │  ← 切替で URL を既定ポートへ差し替え+再問い合わせ
│ URL              [http://127.0.0.1:50021    ] │  ← Enter で再問い合わせ
│ エンジン状態      ● 接続済み (v"0.25.1")  [↻] │
├ 音声 ────────────────────────────────────────┤
│ 話者              [四国めたん / ノーマル ▾]    │  ← /speakers から。一覧に無ければ先頭へ寄せる
│ 話速              [────●────] 1.00           │  0.5–2.0 step 0.05
│ 無音の長さ        [──●──────] 1.5            │  0.0–3.0 step 0.1
├ 保存 ────────────────────────────────────────┤
│ 音声の保存先      ~/Downloads        [参照…]  │
├ 表示 ────────────────────────────────────────┤
│ 文字サイズ 0.6–2.0 / 行間 1.0–2.4              │
│ テーマ [自動|ライト|セピア|ダーク]              │
│ 言語 [Auto|日本語|English]                     │
│ 書字方向 / 表示モード / 綴じ方向 /              │
│ 画像ページの見開き / 本文の見開き               │
├ 翻訳（LM Studio）────────────────────────────┤
│ URL / 接続状態 / 翻訳モデル                    │
│ 原文の言語 / 訳文の言語                        │
│ 直前の段落を文脈として渡す [ON]                │
│ 推論（thinking）を止めるよう頼む [ON]          │
│ 同時に投げる段落数: 2   (1–8)                  │
│ 訳のキャッシュ  1234 段落  [消去]              │
└──────────────────────────────────────────────┘
ツールバー: [テスト再生（未保存の設定で1文合成）] [保存] / [閉じる]
```

### 15.2 保存時の反映

```
saveAndApply():
  テスト再生を停止
  AudioSettings / TranslationSettings / ReadingSettings を永続化
  保存先ディレクトリを設定（空なら既定へ戻す）
  UI 言語の上書きを設定（反映はアプリ再起動後）
  開いている本があれば:
    表示設定（テーマ・フォント・行間・ユーザー CSS）を即反映
    表示モードを反映
    書字方向の既定を反映（本ごとの上書きが無い本だけ・組み直しが要るので別経路）
    綴じ方向・見開きの既定を反映（同上）
    対訳を開いていれば作り直す（前のモデルの訳が混ざらないよう）
```

### 15.3 「全体既定」と「本ごとの上書き」の関係

```
値の解決: 本ごとの指定があればそれ、無ければ全体既定
値の記憶: 設定しようとした値が全体既定と同じなら、本ごとの指定は**持たない**
          （あとで既定を変えたときに追従させるため）
例外: 強制アスペクト比は本ごとにしか持たない（正解が本によって違うため）
```

### 15.4 AudioSettings / TranslationSettings

| フィールド | 既定 |
|---|---|
| `engine` | `"voicevox"`（`"aivis"` で `:10101`） |
| `baseURLString` | `"http://127.0.0.1:50021"` |
| `speaker` | 2（四国めたん ノーマル） |
| `speedScale` | 1.0 |
| `pauseLengthScale` | 1.5 |
| `baseURLString`(LM) | `"http://127.0.0.1:1234"` |
| `model` | `""`（一覧の先頭を使う） |
| `targetLanguage` | `"ja"` |
| `sourceLanguage` | `"auto"` |
| `useContext` | true |
| `concurrency` | 2 |
| `temperature` | 0.2 |
| `disableThinking` | true |

対訳の対応言語: 日本語(ja/Japanese) / English(en) / 中文(zh/Chinese) / 한국어(ko/Korean) /
Français(fr/French) / Deutsch(de/German) / Español(es/Spanish)。
**プロンプトには英語名で渡す。**

---

## 16. ローカライズ

- 開発言語は日本語。対応言語は ja / en。
- 実装は「日本語の文字列そのものをキーにする」方式（`Localizable.strings` の
  `"書棚" = "Library";`）。移植先でも同じ方式が使える（gettext 相当）。
- 書式指定子は `%@`（文字列）/ `%lld`（整数）/ `%d` / `%1$d` を使用。
- OS 言語に追従し、設定で `ja` / `en` に固定できる（反映は再起動後）。
- 新規開発では**最初から i18n 対応で作る**こと（コミットメッセージも英語で書く）。

主な文字列は `Resources/en.lproj/Localizable.strings` を参照（約 110 エントリ）。

---

## 17. ビルド・署名・配布

### 17.1 プロジェクト設定

```
bundle id      : com.veltrea.EpubReaderSpike
platform       : iOS 16.0 / Mac Catalyst（SUPPORTS_MACCATALYST=YES）
署名           : ad-hoc（CODE_SIGN_IDENTITY = "-", CODE_SIGN_STYLE = Manual）
Info.plist:
  NSAppTransportSecurity.NSAllowsLocalNetworking = true   ← VOICEVOX/LM Studio は平文 http
  CFBundleDevelopmentRegion = ja / CFBundleLocalizations = [ja, en]
  CFBundleDocumentTypes = [{ EPUB, Viewer, org.idpf.epub-container }]
  LSSupportsOpeningDocumentsInPlace = true                ← 開いた本をコピーせず元の場所で読む
リソース:
  foliate/ は**フォルダ参照**でバンドルする（ES モジュールのディレクトリ構造を保つため。
  平坦化すると reader.html の `./foliate-js/view.js` の相対 import が解決できない）
```

### 17.2 開発ビルド時の注意

同じ bundle id の `.app` が複数の場所に散らばると、Finder のダブルクリックが
どれを起こすか不定になる（**古いビルドが起動して「変更が反映されない」と誤認する**）。
ビルドスクリプトで:

1. 他パスに残っている同名アプリの LaunchServices 登録を剥がす
2. いまビルドした `.app` を登録し直す
3. `.epub` の既定アプリが自アプリに解決されるか表示する

### 17.3 リリース

```
1. **HEAD を書き出してからビルドする**（作業ツリーから直接ビルドすると
   未コミットの実装が入った .app を配ってしまう）
2. Release 構成でビルド
3. **テストバスが混ざっていないことを実物で検査**（バイナリに EPUB_TEST_BUS_PORT の
   文字列が無いこと）
4. 同梱物を全部配置し終えたあとに ad-hoc で deep sign:
     codesign --sign - --deep --force --timestamp=none <App>.app
   （順番を逆にすると署名シールが壊れ、macOS が権限要求を登録しなくなる）
5. 検証は**浅い** verify で判断する（--deep --strict は framework の symlink で警告が出るが、
   TCC が見るのは主実行ファイルの署名）
6. ZIP は ditto を使う（zip コマンドはリソースフォークとシンボリックリンクを壊す）
     ditto -c -k --sequesterRsrc --keepParent <App>.app <zip>
7. GitHub Releases へアップロード
```

ビルド木は**リポジトリと同じボリューム**に置く（`$TMPDIR` は起動ディスクにあり、
数 GB のビルドが入らず ENOSPC で落ちる）。

**ad-hoc 配布は実用上問題ない**: 開発中はリビルドのたびに cdHash が変わるが、
配布物は一度署名すれば cdHash 固定なので、受け取った人は一度許可すれば保持される。

### 17.4 サードパーティ

- foliate-js（MIT）— 組版・CFI・TTS・検索
- pdf.js、fflate — foliate-js の依存
- 本体は MIT

---

## 18. 既知の落とし穴（移植時に必ず踏む）

| # | 症状 | 原因 | 対策 |
|---|---|---|---|
| 1 | 縦書き本が横書きで開く | 本の CSS に `writing-mode` が無く、EBPAJ クラスか OPF メタにしか意思が残っていない | 8.3 の 3 段構え |
| 2 | 表紙と 1 ページ目を往復するだけで奥付へ行けない | 章ごとの向きでページ送りの左右を決めていた（前付けは横組み） | 本単位の `bookDir` を使う（8.4） |
| 3 | 右綴じ漫画が必ず左綴じになる | 画像だけの面の body は必ず `horizontal-tb/ltr`（WebKit が画像用に作る文書） | 絵だけの面を向きの証拠にしない（`hasDirectionEvidence`） |
| 4 | 漫画の見開きが 1 ページずれる | 透明ページの入れ忘れ | `page-spread-left/right` の申告を優先＋手動ずらし |
| 5 | 表紙が縦に潰れる | `preserveAspectRatio="none"` | 属性を DOM で書き換える（CSS では直せない） |
| 6 | 横書き表示で章扉が枠外へ飛ぶ | 縦書き前提の `text-indent:-5.2em` + `padding-top` の対 | `padding-inline-start` へ入れ直す（8.12） |
| 7 | 縦書きで見開きにならない | 多段組は inline 方向に積むので縦書きでは上下に並ぶ | ブロック方向の幅を広げる（8.10） |
| 8 | 測定オーバーレイが右にずれる | WebKit の縦書き RTL で `position:fixed;left:0` がレイアウトビューポート原点に固定される | 実着地点を測って負シフト（14.3） |
| 9 | 縦書きで `innerWidth` が異常に大きい | レイアウト幅を返す | `visualViewport` を使う |
| 10 | 書棚の表紙が丸ごと欠ける | 未描画 view の `close()` が必ず例外を投げ、取得済みメタごと catch に落ちていた | try-catch で握り潰す（6章） |
| 11 | 本を開いた瞬間に白が光る | WebView の背景・`underPageBackgroundColor` の既定がシステム色 | 生成時にテーマ色を渡し、`atDocumentStart` で `--page-bg` を注入 |
| 12 | ブラウザから VOICEVOX / LM Studio に届かない | カスタムスキーム origin は CORS(403) / ATS で弾かれる | HTTP は必ずネイティブから出す |
| 13 | 動画が録画できない | 素の WKWebView は `MediaRecorder` / `captureStream` を持たない | フレームを 1 枚ずつ吸い出してネイティブでエンコード |
| 14 | 動画書き出し中に UI が固まる | デコード・エンコードがメインスレッドに乗っていた | メインスレッドは JS 呼び出しだけにする |
| 15 | 設定シートの最下行が切れる | Catalyst の `.sheet` は ≈478×524 に丸められ、`.frame` も detents も効かない | 提示ホストの `preferredContentSize` を直接指定（**0.77 倍で表示されるので逆数を掛ける**。例: 実寸 478×616 が欲しければ 620×800 を渡す） |
| 16 | 並行作業でテストが別のアプリに当たる | テストバスが固定ポートを取り合う | ワークツリーのパスからポートを決め、ファイルに記録して両者で共有 |
| 17 | 変更が反映されない（ダブルクリック起動） | 同一 bundle id の古い `.app` が LaunchServices に残っている | ビルド時に登録を張り替える |
| 18 | 進捗スライダーでクラッシュ | `fraction` が NaN / 範囲外 | 有限値へ丸めてクランプ |
| 19 | 目次の一部だけ反応しない | 変換で spine から外れたファイルを指している | ファイル名・目次順から推測して飛ばす（friendly のみ） |
| 20 | 短い語が熟語を食い荒らす | 音声エンジンの辞書は解析コストで語を選ぶ | アプリ側のレイヤー付き前処理に一本化（10.2） |
| 21 | 辞書の境界挿入で朗読が間延びする | 空白が約 0.45 秒の無音を生む | 挿入した境界の `pause_mora` だけを無音化（10.2） |
| 22 | 推論モデルで対訳が実用にならない | 1 段落の訳に思考を数百トークン費やす（実測: 2 語に約 100 秒） | `enable_thinking: false` を渡す + 非推論モデルを推奨 |
| 23 | EPUB の XHTML に style/script を注入すると壊れる | 厳密 XML では `<` `>` `&` が構文エラー | CDATA でガードする |

---

## 19. 移植ガイド

### 19.1 レイヤ別の移植コスト

| レイヤ | 移植方針 | 労力 |
|---|---|---|
| 組版エンジン層（bridge.js + foliate-js） | **そのまま流用**。JS のまま動かす | ほぼゼロ |
| ブリッジ層 | WebView 埋め込み + カスタムスキーム + JS 双方向呼び出し | 小（各 WebView に同等 API あり） |
| サービス層 | HTTP・WAV・動画・SHA256 は標準/一般ライブラリで書き直す | 中 |
| モデル層 | 純ロジック。この文書の擬似コードをそのまま実装できる | 中 |
| UI 層 | ツールキット依存。全面的に書き直す | 大 |

### 19.2 ツールキット別の対応表

| 必要な機能 | macOS(参照) | Windows | Linux | クロス |
|---|---|---|---|---|
| WebView | WKWebView | WebView2 (Chromium) | WebKitGTK | Tauri / Qt WebEngine / Electron |
| カスタムスキーム | `WKURLSchemeHandler` | `AddWebResourceRequestedFilter` | `webkit_web_context_register_uri_scheme` | 各フレームワークの API |
| JS 呼び出し | `evaluateJavaScript` / `callAsyncJavaScript` | `ExecuteScriptAsync` | `webkit_web_view_evaluate_javascript` | — |
| JS→ホスト | `messageHandlers` | `WebMessageReceived` | `webkit_user_content_manager` | — |
| 音声再生 | AVAudioPlayer | WASAPI / miniaudio | ALSA / PulseAudio | miniaudio / rodio |
| 動画エンコード | AVAssetWriter | Media Foundation | ffmpeg | ffmpeg（推奨） |
| 画像デコード/縮小 | ImageIO | WIC | GdkPixbuf | image crate / stb_image |

**注意**: WebView2 / WebKitGTK は `MediaRecorder` を持つ可能性があるが、
**縦書き組版の正しさは WebKit/Blink どちらでも問題ない**。Gecko は
`-epub-writing-mode` 系のベンダプレフィックスの扱いが異なるので検証が要る。

### 19.3 移植で最初に作るべきもの（推奨順）

```
1. WebView + カスタムスキーム + bridge.js のロード → "bridge-ready" が届くこと
2. 書棚の永続化（BookEntry の CRUD）と probe → 表紙が出ること
3. リーダーの最小構成（open / relocate / next / prev / 位置保存）
4. 書字方向・綴じ方向の解決（8.3–8.5）→ **縦書き本で左タップが「進む」になること**
5. テーマ・フォント・ユーザー CSS
6. TTS（辞書 → audio_query → synthesis → 再生）
7. 画像ページの直接描画と見開き（8.6–8.9）
8. 測定オーバーレイとテストバス（以降の回帰をここで守る）
9. 音声保存 → 動画保存
10. 対訳
```

### 19.4 純ロジックとして先に単体テストできるもの

移植先の言語で**先にテストを書ける**（GUI 不要）:

- 読み辞書の適用（`prepare`）と `gapRuns` の序数計算
- WAV の parse / concatenate / compose
- 五十音インデックスのセクションキー決定
- `AspectRatio` のパースと文字列化
- LM Studio 応答のクリーニング（`cleanCompletion`）
- 動画タイムライン（`computeLineDuration` / `assignCharTimings`）
- 縦書き文字分類（`classifyChar` / `wrapColumns`）

---

## 20. 受け入れテスト項目

### 20.1 表示

- [ ] 縦書き EPUB が縦書きで開く（CSS 指定あり / EBPAJ クラスのみ / OPF メタのみ の 3 種）
- [ ] 縦書き本で左タップ = 進む、右タップ = 戻る（**表紙にいる間も**）
- [ ] 横書き本で左タップ = 戻る、右タップ = 進む
- [ ] 進捗スライダーが RTL の本で鏡像になり、章をまたいでも摘みが飛ばない
- [ ] 書字方向を強制切替すると現在位置を保ったまま組み直る
- [ ] `raw` にすると SVG 表紙が潰れて見え、`friendly` に戻すと直る
- [ ] 画像だけのページが画面いっぱいに出る
- [ ] 漫画で表紙が単独、以降が 2 枚ずつ組になる（右綴じは先のページが右）
- [ ] 横長の見開き画像が単独で 1 面を占める
- [ ] 「見開きをずらす」で組が 1 ページずれる
- [ ] 強制アスペクト比を指定すると画像が指定比率へ引き伸ばされる
- [ ] 本文の見開きが横書き（2 列）と縦書き（幅 2 倍）の両方で効く
- [ ] 目次のリンク切れ項目が friendly では飛べる
- [ ] 章扉の見出しが横書き表示で枠外へ飛ばない

### 20.2 書棚

- [ ] D&D / ダブルクリック / ピッカーの 3 経路で本が開く
- [ ] 同じ本を二重登録しない
- [ ] 表紙・作者・出版社・読みが取れる（OMF 漫画でも表紙が出る）
- [ ] 表紙の無い本に代替表紙が出る
- [ ] 五十音インデックスで作者が正しい行に入る（手動読みが最優先）
- [ ] フィルタ・ソートが 4 種すべて効く
- [ ] 読了率バッジが 1% 以上で出る

### 20.3 読み上げ

- [ ] 「斎藤ひとし」をレイヤー 6、「斎」をレイヤー 5 に登録すると、
      「斎藤ひとし」が壊れず、単独の「斎」だけが置換される
- [ ] パターン `第(\d+)話` → `ダイ$1ワ` が効く
- [ ] 境界挿入を有効にしても朗読が間延びしない
- [ ] ダブルクリックした位置から読み上げが始まる
- [ ] Space / Return / Esc が本文フォーカスの有無に関わらず効く
- [ ] 読み上げ中の文がハイライトされ、画面外なら自動送りされる
- [ ] エンジン未起動のときエラーが status に出る

### 20.4 書き出し

- [ ] 章の音声が 1 本の WAV で保存され、再生時と同じ読みになる
- [ ] 音声保存中も表示ページが動かない
- [ ] 縦書き章 → 縦動画（720×1280）、横書き章 → 横動画（1280×720）
- [ ] 動画の字幕掃引と音声が同期している
- [ ] 動画書き出し中にページ送り・スライダーが操作できる

### 20.5 対訳

- [ ] ページを送るたびに訳が追従する（400ms デバウンス）
- [ ] 一度訳した段落がキャッシュから即座に出る
- [ ] LM Studio 未接続時に案内が出る
- [ ] 行のダブルクリックで本文が該当段落へ動く

### 20.6 レイアウト（数値アサート）

- [ ] 設定シートの全コントロールがシート枠に収まる（はみ出し ≤ 0pt）
- [ ] 「本を追加」ボタンがウィンドウ右上の期待レンジ内にある
- [ ] 定規 EPUB で画像の左右余白が対称（gapLeft ≈ gapRight、±1pt）
- [ ] ポインタ y=10 で上バーが出る、y=height-10 で下バーが出る、中央で両方消える

---

## 付録 A: 定数一覧

```
UI
  上バー反応帯 72pt / 下バー反応帯 110pt / ホバー帯 6pt / 消去遅延 220ms
  バーのアニメーション 0.18s / サイドバー 0.2s
  しおりサイドバー 260pt / 目次サイドバー 280pt
  タップゾーン幅 = ビュー幅の 15% / chevron 32pt
  対訳ペイン 既定460 / 最小280 / 最大900 / 左右並び閾値 520 / 文字倍率 0.7–2.0
  書棚セル 150×220 / 続き段の表紙 130×190 / グリッド adaptive 130–180 / 間隔 24,28

組版
  画像面の判定しきい値（本文文字数） 10
  拡大対象とみなす画像の最小辺 200px
  縦書き見開きのブロック幅 2880px（既定 1440px の 2 倍）
  ホイールのロック 250ms / 最小 delta 4
  検索の上限 500 件 / 対訳の段落上限 40 / 判型検出の走査章数 8
  組の 2 枚目からの跳ね返し 最大 12 回 × 60ms

TTS
  レイヤー範囲 1–10 / 境界マーカー U+E000
  段落間の休止 200ms / ダブルクリック後の待ち 250ms / ショートカット重複除去 0.3s
  既定 speaker 2 / speedScale 1.0 / pauseLengthScale 1.5

動画
  縦 720×1280 / 横 1280×720 / fontSize 48 / fps 24 / JPEG 0.92
  行間 GAP 0.15s / 末尾余白 0.4s / フレーム数 = (total + 0.3) × fps
  cellRatio 1.02 / colRatio 1.9 / marginRatio 1.2 / lineGapCols 0.6
  baseOpacity 0.26 / sigma 1.9 / maxBlur 22 / headTargetRatio 0.6
  既読の下駄 0.18 / 発光色の閾値 intensity > 0.15 / 影の閾値 > 0.04

翻訳
  models timeout 8s / chat timeout 300s / temperature 0.2
  max_tokens = min(4096, max(512, プロンプト文字数))
  concurrency 1–8（既定 2） / デバウンス 400ms
  キャッシュ上限 4000 / 保存デバウンス 2s

測定
  セル 10pt / パレット 16 色 / グリッド 10% / 目盛り長 12 / 中央十字 ±24
  境界線 16 セルごと

その他
  probe タイムアウト 15s / narration harness ready タイムアウト 15s
  表紙 PNG 上限 400×600 / サムネイル最大辺 460px
  テストバス既定ポート 47831 / 割り当て範囲 47800–47899
```

## 付録 B: ファイル対応表（参照実装 → 本仕様書の章）

| ファイル | 行数 | 対応章 |
|---|---|---|
| `Sources/EpubReaderSpikeApp.swift` | 137 | 4 |
| `Sources/Library.swift` | 697 | 3, 5 |
| `Sources/ShelfView.swift` | 549 | 5 |
| `Sources/FoliateReader.swift` | 294 | 2, 6 |
| `Sources/ReaderView.swift` | 2803 | 7, 9, 11, 14 |
| `Sources/ReadingRules.swift` | 291 | 10.2 |
| `Sources/VoicevoxTTSEngine.swift` | 224 | 10.3 |
| `Sources/TTSAudioSaver.swift` | 219 | 11, 15 |
| `Sources/VideoNarrationRenderer.swift` | 371 | 12 |
| `Sources/Translation.swift` | 374 | 13 |
| `Sources/TranslationPane.swift` | 381 | 13 |
| `Sources/SettingsView.swift` | 414 | 15 |
| `Sources/TestBus.swift` | 542 | 14.5 |
| `Resources/foliate/bridge.js` | 1612 | 7, 8 |
| `Resources/foliate/narration/harness.mjs` | 131 | 12 |
| `narration-video/lib/*.mjs` | 462 | 12.4–12.6 |
| `mcp/epub-test-mcp/*.py` | 1012 | 14.6 |
