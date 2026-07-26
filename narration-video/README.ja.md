# 朗読動画メーカー（VOICEVOX + 縦書き発光）

テキストを入れると、VOICEVOX で朗読音声を作り、**読み上げている箇所だけがドロップシャドウで光る**縦書き（横書きも可）の朗読動画を、ブラウザ内で **MP4 として一発保存**できるツール。

YouTube でよく見る「文字が流れて、読まれているところが発光する」キネティック・タイポグラフィ／カラオケ字幕系の動画を、録画ソフトも動画編集も使わずに作る。

## 仕組み

1. **VOICEVOX**（`:50021`）に行ごと `audio_query` → モーラ(consonant/vowel)長から**正確な発話タイムライン**を算出（強制アライメント不要）→ `synthesis` で WAV。
2. **Canvas** に縦書き組版して描画。読み位置をガウス分布のスポットライトで発光（アクセント色＋`shadowBlur`）、他を減光、現在列を中心に右→左スクロール。
3. **録画**は `canvas.captureStream()` の映像 + `AudioContext` の音声を `MediaRecorder` で合成し、**MP4(H.264+AAC)** をダウンロード（非対応環境は自動で WebM）。

## 使い方

前提: VOICEVOX を起動しておく（既定 `http://127.0.0.1:50021`）。

```bash
cd narration-video
node serve.mjs         # http://localhost:8123/ を開く
```

ブラウザで開いたら:

1. テキストを入力（**改行＝行分割、空行＝ポーズ**）
2. 話者・向き（縦/横）・文字サイズ・色（背景/文字/発光＝テーマ色）を選ぶ
3. **① 音声＋タイムライン生成** → **② プレビュー**で確認 → **③ 録画して MP4 保存**

> ⚠ 録画は再生時間ぶんリアルタイムで行われる（5 分の朗読なら録画に 5 分）。録画中はタブを前面に保つこと。

## 縦書きの約物処理

canvas に縦書き機能は無いので、1 文字ずつセルに置き、文字種で描画を変える（`lib/verticalText.mjs`）:

- 句読点 `、。，．` … セル右上へ寄せる（正立）
- 長音・ダッシュ・波・各種括弧 `ー―（）「」『』【】〜` … 90°回転
- 小書き仮名 `ぁぃっゃゅょ…` … 右上へ軽くオフセット
- 行頭禁則 … 列頭に来る約物は前列末尾へぶら下げ

## 構成（テスタビリティ重視）

ロジックは DOM/HTTP から分離し、node で単体実行できる。

| ファイル | 役割 | 依存 |
|---|---|---|
| `lib/voicevox.mjs` | タイムライン数理（DI で fetch 注入） | 純 JS |
| `lib/verticalText.mjs` | 縦書き分類・折り返し・禁則 | 純 JS |
| `lib/render.mjs` | Canvas レイアウト・発光描画 | Canvas 2D |
| `lib/audio.mjs` | WAV デコード＆結合・再生 | AudioContext |
| `lib/vvClient.mjs` | ブラウザ用 VOICEVOX fetch | fetch |
| `app.mjs` / `index.html` | UI 統合 | — |
| `serve.mjs` | 依存なし静的配信 | node |

テスト:

```bash
node lib/timeline.test.mjs   # 純ロジック＋VOICEVOX実機結合
```

英語版は [README.md](README.md)。
