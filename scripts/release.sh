#!/usr/bin/env bash
# release.sh — 配布用の .app を作り、ZIP にして GitHub Releases へ上げる。
#
# 配布物は「コミット済みの HEAD」から作る。作業ツリーから直接ビルドすると、
# 未コミットの実装が入った .app を配ってしまう（公開スクリプトと同じ理由）。
#
# 署名は ad-hoc（Apple Developer アカウントを使わない）。ad-hoc でも
# 一度署名すれば cdHash は固定なので、受け取った人は一度許可すれば保持される。
# 逆に、パッケージし終えたあとに deep sign し直さないと署名シールが壊れ、
# macOS がマイク等の権限要求を登録しなくなる（設定の一覧にすら出なくなる）。
#
# 使い方:
#   bash scripts/release.sh                # ビルド → 署名 → ZIP（dist/ に置くだけ）
#   UPLOAD=1 bash scripts/release.sh       # 上に加えて GitHub Releases を作成
#   TAG=v0.2.0 UPLOAD=1 bash scripts/release.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_REPO="veltrea/tategaki-reader"
APP_NAME="EpubReaderSpike"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; }

VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' "$REPO/spike-readium/project.yml")"
[ -n "$VERSION" ] || { err "MARKETING_VERSION を project.yml から読めません"; exit 1; }
TAG="${TAG:-v$VERSION}"

EXPORT="$(mktemp -d "${TMPDIR:-/tmp}/tategaki-release.XXXXXX")"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

cleanup() {
    # 一時ビルドの .app を LaunchServices から剥がす。放っておくと、同じバンドル ID の
    # .app が増えて .epub のダブルクリックがどれを起こすか不定になる（実際に踏んだ罠）。
    local built="$EXPORT/spike-readium/DerivedData/Build/Products/Release-maccatalyst/$APP_NAME.app"
    [ -e "$LSREGISTER" ] && "$LSREGISTER" -u "$built" 2>/dev/null || true
    if [ "${KEEP_TMP:-0}" = "1" ]; then
        ok "ビルド木を残しました: $EXPORT"
    else
        rm -rf "$EXPORT"
    fi
}
trap cleanup EXIT

# --- 1. HEAD を書き出す ---------------------------------------------------
say "HEAD を書き出し: $(git -C "$REPO" log -1 --format='%h %s')"
dirty="$(git -C "$REPO" status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
[ "$dirty" != "0" ] && warn "未コミットの変更が $dirty 件あります。配布物には入りません。"
git -C "$REPO" archive --format=tar HEAD | tar -x -C "$EXPORT"

# --- 2. Release 構成でビルド ----------------------------------------------
# Debug ではなく Release。TestBus（#if DEBUG）は 127.0.0.1 で待ち受けるので、
# 配布物に入れてはいけない。
say "ビルド（Release / Mac Catalyst）"
cd "$EXPORT/spike-readium"
xcodegen generate >/dev/null
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath ./DerivedData build 2>&1 | tail -3

APP="$EXPORT/spike-readium/DerivedData/Build/Products/Release-maccatalyst/$APP_NAME.app"
[ -d "$APP" ] || { err "ビルド成果物が見つかりません: $APP"; KEEP_TMP=1; exit 1; }

# TestBus が Release に混ざっていないことを実物で確かめる。
if strings "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null | grep -q "EPUB_TEST_BUS_PORT"; then
    err "Release ビルドにテストバスが含まれています（#if DEBUG の囲いを確認）"
    KEEP_TMP=1; exit 1
fi
ok "テストバスなし"

# --- 3. ad-hoc で deep sign -----------------------------------------------
# 同梱物を全部配置し終えたあとに署名する。順番を逆にすると署名シールが壊れる。
say "ad-hoc 署名"
codesign --sign - --deep --force --timestamp=none "$APP"
# 検証は浅い verify で判断する（--deep --strict は framework の symlink で警告が出るが、
# TCC が見るのは主実行ファイルの署名）。
codesign --verify "$APP" && ok "署名の検証を通過"

# --- 4. ZIP ---------------------------------------------------------------
DIST="$REPO/dist"
mkdir -p "$DIST"
ZIP="$DIST/$APP_NAME-$VERSION-maccatalyst.zip"
rm -f "$ZIP"
say "ZIP を作成"
# ditto を使う（zip コマンドはリソースフォークとシンボリックリンクを壊す）。
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
ok "$(basename "$ZIP") — $(du -h "$ZIP" | awk '{print $1}') / sha256 $(shasum -a 256 "$ZIP" | cut -c1-16)…"

# --- 5. GitHub Releases ---------------------------------------------------
if [ "${UPLOAD:-0}" != "1" ]; then
    say "UPLOAD=1 を付けると GitHub Releases に上げます（今回は dist/ に置くだけ）"
    exit 0
fi

command -v gh >/dev/null 2>&1 || { err "gh CLI がありません"; exit 1; }

NOTES="$(cat <<EOF
macOS（Mac Catalyst）向けのビルド済みアプリです。Apple Developer アカウントを使わない
**ad-hoc 署名**なので、初回だけ macOS の警告を越える操作が要ります。

### 使い方
1. ZIP を展開して \`$APP_NAME.app\` を \`/Applications\` へ入れる
2. **右クリック →「開く」**（ダブルクリックでは開けません）→ もう一度「開く」
   - または システム設定 → プライバシーとセキュリティ →「このまま開く」
   - コマンドでよければ: \`xattr -dr com.apple.quarantine /Applications/$APP_NAME.app\`
3. 読み上げを使うなら [VOICEVOX](https://voicevox.hiroshiba.jp/) か AivisSpeech を起動しておく

### 中身
- バージョン $VERSION / ソースは同タグのコミット
- 縦書き EPUB の表示（読みやすさ優先 / EPUB のまま の2モード）
- 漫画（OMF）の綴じ方向・見開き・アスペクト比を本ごとに指定
- VOICEVOX / AivisSpeech での読み上げ、音声・動画の書き出し

notarize（Apple の公証）は付いていません。必要な方はフォークして各自の Developer ID で
署名してください。
EOF
)"

say "リリースを作成: $TAG → $PUBLIC_REPO"
if gh release view "$TAG" -R "$PUBLIC_REPO" >/dev/null 2>&1; then
    warn "$TAG は既にあります。資材を差し替えます。"
    gh release upload "$TAG" "$ZIP" -R "$PUBLIC_REPO" --clobber
else
    gh release create "$TAG" "$ZIP" -R "$PUBLIC_REPO" \
        --title "$APP_NAME $VERSION" --notes "$NOTES"
fi
ok "公開: https://github.com/$PUBLIC_REPO/releases/tag/$TAG"
