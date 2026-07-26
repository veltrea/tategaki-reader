#!/usr/bin/env bash
# VOICEVOX / AivisSpeech 疎通 & TTS要件スモークテスト
#
# 目的: Swift/Rust を書く前に、curl だけで以下を検証する。
#   - エンジンに繋がるか（/version）
#   - 再生速度調整      → audio_query.speedScale
#   - 改行/句読点の待ち → audio_query.pauseLengthScale
#   - 読み上げ辞書＋優先度 → ユーザー辞書に「斎藤=サイトウ」を高優先で登録し
#                          「斎ひとし問題」（斎藤が誤読される）が直るか before/after で聴き比べ
#
# 依存: curl, jq, afplay(macOS標準)
# 使い方:
#   ./scripts/voicevox-smoke-test.sh                 # 既定文で実行 (VOICEVOX :50021)
#   VOICEVOX_PORT=10101 ./scripts/voicevox-smoke-test.sh   # AivisSpeech
#   SPEAKER=3 ./scripts/voicevox-smoke-test.sh "任意の文"

set -euo pipefail

PORT="${VOICEVOX_PORT:-50021}"     # VOICEVOX=50021 / AivisSpeech=10101
HOST="127.0.0.1"
SPEAKER="${SPEAKER:-2}"             # 既定=四国めたん ノーマル(2)  他: あまあま0 / ツンツン6 / セクシー4
BASE="http://${HOST}:${PORT}"
TEXT="${1:-斎藤さんは今日ひとしと会う}"

# --- 依存チェック ---------------------------------------------------------
for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "✗ '$cmd' が必要です (brew install $cmd)"; exit 1; }
done

# --- 1) 疎通 --------------------------------------------------------------
echo "▶ 疎通確認: ${BASE}/version"
if ! curl -sf "${BASE}/version" >/dev/null 2>&1; then
  echo "✗ ${BASE} に繋がりません。エンジンを起動してください。"
  echo "  - VOICEVOX    : https://voicevox.hiroshiba.jp/  (既定ポート 50021)"
  echo "  - AivisSpeech : https://aivis-project.com/       (既定ポート 10101 → VOICEVOX_PORT=10101 で再実行)"
  exit 1
fi
echo "✓ version: $(curl -s "${BASE}/version")"

WORKDIR="$(mktemp -d)"
trap 'echo "  生成物: ${WORKDIR}"' EXIT

# text をURLエンコードして audio_query→(speed/pause書換)→synthesis
synth () { # $1=text $2=out [speed=1.0] [pause=1.0]
  local text="$1" out="$2" speed="${3:-1.0}" pause="${4:-1.0}"
  local enc; enc="$(jq -rn --arg t "$text" '$t|@uri')"
  curl -s -X POST "${BASE}/audio_query?text=${enc}&speaker=${SPEAKER}" \
    | jq --argjson s "$speed" --argjson p "$pause" \
         '.speedScale=$s | (if has("pauseLengthScale") then .pauseLengthScale=$p else . end)' \
    > "${WORKDIR}/q.json"
  curl -s -X POST "${BASE}/synthesis?speaker=${SPEAKER}" \
    -H 'Content-Type: application/json' -d @"${WORKDIR}/q.json" -o "$out"
}

# --- 2) 辞書登録『前』 ----------------------------------------------------
echo "▶ 辞書登録『前』: 「${TEXT}」(speed=1.0, pause=1.0)"
synth "$TEXT" "${WORKDIR}/before.wav"
afplay "${WORKDIR}/before.wav" 2>/dev/null || true

# --- 3) ユーザー辞書に「斎藤=サイトウ」を高優先(固有名詞)で登録 ----------
echo "▶ ユーザー辞書へ登録: 斎藤 → サイトウ (word_type=PROPER_NOUN, priority=9)"
enc_s="$(jq -rn '"斎藤"|@uri')"; enc_p="$(jq -rn '"サイトウ"|@uri')"
DICT_ID="$(curl -s -X POST \
  "${BASE}/user_dict_word?surface=${enc_s}&pronunciation=${enc_p}&accent_type=1&word_type=PROPER_NOUN&priority=9" \
  | tr -d '"')"
echo "  登録ID: ${DICT_ID:-（登録レスポンス空。/docs で user_dict_word の仕様を確認）}"

# --- 4) 辞書登録『後』＋速度1.2＋ポーズ1.5 --------------------------------
echo "▶ 辞書登録『後』: 「${TEXT}」(speed=1.2, pause=1.5)"
synth "$TEXT" "${WORKDIR}/after.wav" 1.2 1.5
afplay "${WORKDIR}/after.wav" 2>/dev/null || true

echo "✓ 完了。before.wav / after.wav を聴き比べ、『斎藤』の読みが直ったか確認してください。"
echo "  辞書を消すには: curl -s -X DELETE \"${BASE}/user_dict_word/${DICT_ID}\""
