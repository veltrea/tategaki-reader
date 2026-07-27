#!/usr/bin/env bash
# EpubReaderSpike を Mac Catalyst 向けにビルドし、Finder のダブルクリックが必ず
# 「今ビルドした .app」を開くよう LaunchServices を張り直す。
#
# なぜ張り直すのか:
#   .epub の既定アプリはバンドル ID (com.veltrea.EpubReaderSpike) で記録される。ところが
#   同じバンドル ID の .app が複数の DerivedData（Xcode GUI 用・xcodebuild 用・一時ディレクトリ）に
#   散らばっていると、LaunchServices がどれを起こすかは不定で、古いビルドが起動しうる。
#   実際それで「ダブルクリックしても本が開かない（onOpenURL の無い旧バイナリが起動していた）」が起きた。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../spike-readium" && pwd)"
APP="$PROJECT_DIR/DerivedData/Build/Products/Debug-maccatalyst/EpubReaderSpike.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

cd "$PROJECT_DIR"
xcodegen generate
xcodebuild -project EpubReaderSpike.xcodeproj -scheme EpubReaderSpike \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath ./DerivedData build | tail -3

[ -d "$APP" ] || { echo "ビルド成果物が見つからない: $APP" >&2; exit 1; }

# 他パスに残っている同名アプリの登録を剥がしてから、今ビルドした .app を登録し直す。
while IFS= read -r stale; do
  [ -z "$stale" ] && continue
  [ "$stale" = "$APP" ] && continue
  echo "登録解除(旧ビルド): $stale"
  "$LSREGISTER" -u "$stale" || true
done < <("$LSREGISTER" -dump | sed -n 's/^path: *\(.*EpubReaderSpike\.app\) (0x.*/\1/p')

"$LSREGISTER" -f "$APP"
echo "登録: $APP"

# 実際に .epub がこのアプリに解決されるかを表示（既定アプリ未設定なら空になる）。
handler=$(plutil -p ~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist 2>/dev/null \
  | grep -A4 '"LSHandlerContentType" => "org.idpf.epub-container"' | sed -n 's/.*"LSHandlerRoleAll" => "\(.*\)"/\1/p' | tail -1)
if [ "$handler" = "com.veltrea.epubreaderspike" ]; then
  echo ".epub の既定アプリ: EpubReaderSpike（ダブルクリックで開きます）"
else
  echo ".epub の既定アプリ: ${handler:-未設定} → Finder で .epub を右クリック→情報を見る→"
  echo "  「このアプリケーションで開く」で EpubReaderSpike を選び「すべてを変更…」"
fi
