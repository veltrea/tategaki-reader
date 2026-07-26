# epub-test-mcp

EpubReaderSpike（Mac Catalyst アプリ）を **computer-use なしで** テストするための MCP サーバー
（stdio / JSONL。`server.py` は標準ライブラリのみ。`axdriver.py` は macOS 同梱の `/usr/bin/python3` に入っている
pyobjc を使う）。座標クリック・frontmost 検査・通知センターの被りに一切依存せず、
Accessibility(AX) とアプリ内 DEBUG テストバスで UI を駆動・検証する。1テストが数秒で終わる。

## 構成
- `server.py` … MCP 本体。ツールを公開。
- `axdriver.py` … AX 駆動 + テストバス接続の実装。CLI としても直接使える。
- `assert_settings_fit.py` … 設定シートの各コントロールが枠に収まっているかを数値でアサートする実例。

`server.py` を編集したら、Claude 側に新ツールを読ませるため **MCP 再接続**（`/mcp` か次セッション）が必要。
`axdriver.py` の CLI は編集即反映。

## ツール一覧

| ツール | 用途 |
|---|---|
| `screenshot(app?)` | ウィンドウを**前面化せず** PNG 取得（`screencapture -l`。隠れていても撮れる） |
| `list_windows()` | オンスクリーンのウィンドウ列挙（アプリ名・サイズ・window id） |
| `ui_tree(app?,max_depth?,grep?)` | AX 要素ツリーをテキストで取得（**スクショ代替**） |
| `ui_find(selector)` | セレクタ一致要素の列挙 |
| `ui_action(selector, action)` | AX アクション実行（AXPress など） |
| `ui_set_value(selector, text)` | TextField 等へ値を設定 |
| `ui_menu(path)` | メニューバー項目実行（`ファイル>開く`） |
| `ui_overflow(selector, outer?, tol?)` | inner が枠(outer, 既定=ウィンドウ)から各辺で何ptはみ出すか。正=はみ出し/負=余白、`inside`で合否 |
| `measure_overlay(...)` | 本文に計りレイヤー（ルーラー+16色帯）を注入し、画像・本文の座標を数値で取得 |
| `app_cmd(...)` | アプリ内 DEBUG テストバスへコマンド送信（下記） |

> `ui_tree`/`ui_find` は各要素の **`pos`(x,y) / `size`(w,h)** を数値で返す（AXPosition/AXSize を AXValueGetValue で取得）。
> レイアウトの数値アサートはこの座標と `ui_overflow` で行う。詳細は `docs/layout-qa-methodology.md`。

### セレクタ（ui_find / ui_action / ui_set_value 共通）
`role` / `title` / `title_contains` / `desc` / `desc_contains` / `value` / `nth` / `focused`

> **重要:** Catalyst ではボタン等のラベルは `AXTitle` でなく **`AXDescription`(desc)** に出る。
> 「保存」「キャンセル」「本を追加」等は `desc='保存'` / `title=null`。必ず `desc`/`desc_contains` で照合する
> （`title` で照合すると一致せず「効かない」と誤認する）。アラート(UIAlertController)のボタンも
> desc 指定で AXPress でき、**アラートは AX で完全駆動できる**。

## AX の唯一の死角と、その回避

SwiftUI の `.contextMenu`（右クリックメニュー）だけは `AXShowMenu` で開けない（no-op）。
これを埋めるのが **アプリ内 DEBUG テストバス**（`Sources/TestBus.swift`, `#if DEBUG`）。
`127.0.0.1:47831` に JSONL TCP サーバを立て、本物のモデル操作の実行＋真の状態取得を提供する。
リリースビルドには含まれない。サンドボックス無効なのでネットワーク権限は不要。

主なコマンドは以下（全一覧は `Sources/TestBus.swift` の `switch` を参照。ページ送り・検索・テーマ・
しおり・書字方向・読み辞書・音声/動画の書き出しなど 30 以上ある）。

| cmd | 説明 |
|---|---|
| `ping` | 疎通確認 |
| `state` | 全書籍の真の状態（title/author/authorYomi/resolvedReading/authorSortKey）を JSON で取得 |
| `setYomi`(`title_contains`,`yomi`) | 作者の読みを設定（右クリック「作者の読みを設定」相当） |
| `clearYomi`(`title_contains`) | 読みをクリア |
| `remove`(`title_contains`) | 書棚から削除 |
| `open`(`title_contains`) | 本を開く |
| `openYomiEditor`(`title_contains`) | 実アラートを開く（以降 AX で入力・保存できる） |

## CLI 例
```bash
python3 axdriver.py trusted                                                  # AX 権限確認
python3 axdriver.py tree --max-depth 12                                      # UI ツリー
python3 axdriver.py act --role AXRadioButton --desc-contains 箇条書き --action AXPress  # インデックス表示へ
python3 axdriver.py act --role AXButton --desc 保存 --action AXPress                    # 保存ボタン
python3 axdriver.py set --role AXTextField --focused --value-str "やまだ たろう"          # 入力
python3 axdriver.py overflow --role AXButton --desc 本を追加                              # はみ出し判定
python3 axdriver.py cmd --json '{"cmd":"state"}'                                         # 状態取得
python3 axdriver.py cmd --json '{"cmd":"setYomi","title_contains":"見本","yomi":"やまだ たろう"}'
```

## 定石: バスで操作 → AX で結果検証
```bash
python3 axdriver.py cmd --json '{"cmd":"setYomi","title_contains":"見本","yomi":"やまだ"}'
python3 axdriver.py act --role AXRadioButton --desc-contains 箇条書き --action AXPress
python3 axdriver.py tree | grep -E "AXHeading|見本"      # → 「や」行に出る
```

## 前提
- `/usr/bin/python3`（pyobjc 同梱）に Accessibility 権限付与済み（`axdriver.py trusted` で確認）。
- `app_cmd` 系は EpubReaderSpike を **DEBUG ビルド**で起動していること。

## メモ
- MCP stdio は JSONL（1行1 JSON、`\n` 区切り）。**Content-Length ヘッダーは付けない**（LSP と混同しない）。
- 前面化せず撮れるので、テスト中にユーザーのフォーカスを奪わない。
