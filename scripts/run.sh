#!/usr/bin/env bash
# ビルド済みの EpubReaderSpike を、このワークツリー専用のテストバス・ポートで起動する。
#
# なぜポートを分けるのか:
#   TestBus は 127.0.0.1 の固定ポートに待ち受ける。ワークツリーを分けて並行に作業すると、
#   両方のビルドが同じポートを取り合い（allowLocalEndpointReuse を立てているので後から
#   起動した側が黙って奪う）、片方のテストがもう片方のアプリに当たる。実際それで
#   「変更したはずの機能が unknown cmd で返ってくる」という混線が起きた。
#   ワークツリーのパスからポートを決めれば、設定を書かなくても必ず別の口になる。
#
# 決めたポートは <repo>/.testbus-port に置く。テスト側（scripts/bus.py・
# mcp/epub-test-mcp/axdriver.py）はこのファイルを読むので、両者は自動で揃う。
# 環境変数 EPUB_TEST_BUS_PORT を先に立てておけばそちらが優先される。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/spike-readium/DerivedData/Build/Products/Debug-maccatalyst/EpubReaderSpike.app"

[ -d "$APP" ] || { echo "ビルド成果物が見つからない: $APP（先に scripts/build.sh）" >&2; exit 1; }

PORT="${EPUB_TEST_BUS_PORT:-}"
if [ -z "$PORT" ]; then
  # 47800〜47899 の範囲へ、ワークツリーのパスから振り分ける。
  PORT=$(/usr/bin/python3 -c \
    'import hashlib,sys; print(47800 + int(hashlib.sha1(sys.argv[1].encode()).hexdigest(), 16) % 100)' \
    "$REPO")
fi
printf '%s\n' "$PORT" > "$REPO/.testbus-port"

# 既に別プロセスがこのポートを掴んでいたら、起動しても奪い合いになる。先に知らせる。
if /usr/bin/nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "警告: ポート $PORT は既に誰かが待ち受けている（このワークツリーのアプリが起動済みかも）" >&2
fi

open --env "EPUB_TEST_BUS_PORT=$PORT" -a "$APP"
echo "起動: $APP"
echo "テストバス: 127.0.0.1:$PORT（$REPO/.testbus-port に記録）"
