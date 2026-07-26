#!/bin/bash
# EpubReaderSpike のウィンドウを「前面化せず」に撮る。
# screencapture -l <windowID> はウィンドウサーバーから直接キャプチャするので、
# 非アクティブ・他ウィンドウに隠れていても撮れる（ユーザーの操作を邪魔しない）。
#
# 使い方: scripts/shot.sh [出力先.png] [アプリ名]
set -euo pipefail
OUT="${1:-/tmp/epub-shot.png}"
APP="${2:-EpubReaderSpike}"

WID="$(/usr/bin/python3 - "$APP" <<'PY'
import sys, Quartz
app = sys.argv[1]
wins = Quartz.CGWindowListCopyWindowInfo(
    Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID
)
best = None
for w in wins:
    if w.get('kCGWindowOwnerName') != app:
        continue
    if w.get('kCGWindowLayer', 0) != 0:  # 通常ウィンドウ層のみ
        continue
    b = w.get('kCGWindowBounds', {})
    area = b.get('Width', 0) * b.get('Height', 0)
    if best is None or area > best[1]:
        best = (int(w['kCGWindowNumber']), area)
print(best[0] if best else '')
PY
)"

if [ -z "$WID" ]; then
  echo "window not found for app: $APP" >&2
  exit 1
fi

# -o: 影を除く / -x: 効果音なし / -l: window id 指定
screencapture -o -x -l "$WID" "$OUT"
echo "$OUT (window $WID)"
