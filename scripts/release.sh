#!/usr/bin/env bash
# release.sh — 配布用の .app を作り、DMG にして GitHub Releases へ上げる。
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
#   bash scripts/release.sh                # ビルド → 署名 → DMG（dist/ に置くだけ）
#   UPLOAD=1 bash scripts/release.sh       # 上に加えて GitHub Releases を作成
#   TAG=v0.2.0 UPLOAD=1 bash scripts/release.sh
#   REF=c432494 bash scripts/release.sh    # 過去のコミットから作り直す（配布物の復元）
#
# REF は「どのコミットから配布物を作るか」。既定は HEAD。公開済みバージョンの資材を
# 作り直すときに使う（公開済みの版に、後から中身の違う .app を上書きしないため）。
# バージョンは REF のツリーの project.yml から読む＝作業ツリーの版に引きずられない。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLIC_REPO="veltrea/tategaki-reader"
APP_NAME="EpubReaderSpike"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; }

REF="${REF:-HEAD}"

# ビルド木はリポジトリと同じボリュームに置く。$TMPDIR は起動ディスクにあり、
# Xcode のビルド（数 GB）が入らずに ENOSPC で落ちることがある（実際に落ちた）。
DIST="$REPO/dist"
mkdir -p "$DIST"
EXPORT="$(mktemp -d "$DIST/build.XXXXXX")"
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
say "書き出し: $(git -C "$REPO" log -1 --format='%h %s' "$REF")"
dirty="$(git -C "$REPO" status --porcelain --untracked-files=all | wc -l | tr -d ' ')"
[ "$dirty" != "0" ] && warn "未コミットの変更が $dirty 件あります。配布物には入りません。"
git -C "$REPO" archive --format=tar "$REF" | tar -x -C "$EXPORT"

# バージョンは書き出したツリーから読む（REF を指定したときに作業ツリーの版が混ざらない）。
VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' "$EXPORT/spike-readium/project.yml")"
[ -n "$VERSION" ] || { err "MARKETING_VERSION を project.yml から読めません"; exit 1; }
TAG="${TAG:-v$VERSION}"

# --- 2. Release 構成でビルド ----------------------------------------------
# Debug ではなく Release。コマンドバスは配布物にも載るが、受け付けるのは読み辞書まわりだけ
#（TestBus.releaseCommands）。その絞り込みが実物に入っていることは下で確かめる。
say "ビルド（Release / Mac Catalyst）"
cd "$EXPORT/spike-readium"
xcodegen generate >/dev/null
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath ./DerivedData build 2>&1 | tail -3

APP="$EXPORT/spike-readium/DerivedData/Build/Products/Release-maccatalyst/$APP_NAME.app"
[ -d "$APP" ] || { err "ビルド成果物が見つかりません: $APP"; KEEP_TMP=1; exit 1; }

# コマンドバスの絞り込みを実物で確かめる。
#
# 読み辞書の編集・検算（dictAdd / applyRules 等）は配布版でも開けてある。手で熟語を数十件
# 入れるのは割に合わず、AI に任せられることに意味があるため。ただし蔵書の一覧・パス、
# 書棚の切り替え、本文への eval、電源操作まで開くと書棚を分ける設計が無意味になるので、
# リリースでは TestBus.releaseCommands 以外を突き返す。その分岐（#if !DEBUG）が
# 実物に入っているかを、拒否メッセージの文字列で確認する。
BIN="$APP/Contents/MacOS/$APP_NAME"
# 文字列は一度変数へ受け、判定はパイプを使わない `case` で行う。
# `… | grep -q` だと、grep が最初の一致で抜けた拍子に上流が SIGPIPE で死に、
# pipefail がその終了コードを拾って「一致したのに失敗」になる（実際に踏んだ）。
SYMS="$(strings "$BIN" 2>/dev/null || true)"
case "$SYMS" in
    *"command not available in this build"*) ;;
    *)  err "配布ビルドにコマンドの絞り込みが入っていません（TestBus の #if !DEBUG を確認）"
        KEEP_TMP=1; exit 1 ;;
esac
# 開発ビルド限定の逃げ道（電源操作を記録だけにするフラグ）が混ざっていないこと。
case "$SYMS" in
    *"sleepTimer.debug.realPower"*)
        err "配布ビルドに DEBUG 限定のコードが混ざっています"
        KEEP_TMP=1; exit 1 ;;
esac
ok "コマンドバスは読み辞書まわりのみ（絞り込みを確認）"

# --- 3. ad-hoc で deep sign -----------------------------------------------
# 同梱物を全部配置し終えたあとに署名する。順番を逆にすると署名シールが壊れる。
say "ad-hoc 署名"
codesign --sign - --deep --force --timestamp=none "$APP"
# 検証は浅い verify で判断する（--deep --strict は framework の symlink で警告が出るが、
# TCC が見るのは主実行ファイルの署名）。
codesign --verify "$APP" && ok "署名の検証を通過"

# --- 4. DMG ---------------------------------------------------------------
# zip ではなく dmg にする。
#
# zip は macOS の拡張属性を AppleDouble（`Contents/._Info.plist` 等）として抱き込み、
# 受け取った人が `unzip` で展開するとそれが実体ファイルになって**署名シールを壊す**。
# しかも Finder のダブルクリック展開では壊れないので、作った本人は気付けない
#（`--norsrc --noextattr` や `--sequesterRsrc` で回避はできるが、フラグを一つ間違えると
#  静かに壊れる類の話になる）。
# dmg はファイルシステムごと運ぶのでこの問題が原理的に起きない。中身は署名済みの .app が
# そのまま入るだけで、外側を zip で包む必要も無い（UDZO で圧縮済み）。
DMG="$DIST/$APP_NAME-$VERSION-maccatalyst.dmg"
STAGE="$EXPORT/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
say "DMG を作成"
# ditto でコピー（cp -R は拡張属性やシンボリックリンクの扱いが甘い）。
ditto "$APP" "$STAGE/$APP_NAME.app"
# ドラッグ＆ドロップで入れられるよう /Applications への近道を置く。
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov -quiet "$DMG"

# 配る前に、**マウントした実物**で署名を確かめる（作業ツリーの .app ではなく、
# 受け取った人が触るのと同じ経路で見る）。
say "DMG を検証"
# マウント先は hdiutil に決めさせる（-mountpoint で任意のディレクトリを指定すると
# EACCES で attach failed になる環境がある。実際にこのリポジトリのある外付けで踏んだ）。
MNT="$(hdiutil attach "$DMG" -nobrowse -readonly -plist \
        | /usr/bin/python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print([e["mount-point"] for e in d["system-entities"] if e.get("mount-point")][0])')"
[ -n "$MNT" ] || { err "DMG をマウントできません"; KEEP_TMP=1; exit 1; }
fail=""
stray="$(find "$MNT" -name '._*' | wc -l | tr -d ' ')"
[ "$stray" != "0" ] && fail="AppleDouble が $stray 件混ざっています"
codesign --verify "$MNT/$APP_NAME.app" || fail="マウントした .app の署名検証に失敗しました"
codesign -dv "$MNT/$APP_NAME.app" 2>&1 | grep -E 'Identifier|Sealed' | sed 's/^/      /' >&2 || true
hdiutil detach "$MNT" -quiet || true
if [ -n "$fail" ]; then err "$fail"; KEEP_TMP=1; exit 1; fi
ok "署名の検証を通過（マウントした実物）"
ok "$(basename "$DMG") — $(du -h "$DMG" | awk '{print $1}') / sha256 $(shasum -a 256 "$DMG" | cut -c1-16)…"

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
1. DMG を開いて \`$APP_NAME.app\` を \`Applications\` へドラッグする
2. **右クリック →「開く」**（ダブルクリックでは開けません）→ もう一度「開く」
   - または システム設定 → プライバシーとセキュリティ →「このまま開く」
   - コマンドでよければ: \`xattr -dr com.apple.quarantine /Applications/$APP_NAME.app\`
3. 読み上げを使うなら [VOICEVOX](https://voicevox.hiroshiba.jp/) か AivisSpeech を起動しておく

### このバージョンで増えたもの
- **自動ページ送り** — 10〜90 秒か任意の間隔。読み上げ中は送らず、本の終わりで止まる
- **スリープタイマー** — 15〜120 分。満了時に読み上げ停止／Mac をスリープ／シャットダウン
  （シャットダウンは 30 秒の猶予つきで取り消せる）
- **分類**（入れ子可）・お気に入り・作者別の五十音表示
- **書棚の切り替え** — 蔵書の一覧・分類・読書位置・しおり・読み辞書ごと入れ替わる。
  見せたくない本を「隠す」のではなく、読む先を変える作り
- **フォルダから一括登録**（⇧⌘O、サブフォルダも探す）
- 読み上げ辞書を外部から編集・検算できるように（AI に任せる用。詳しくはマニュアル八章）
- 配布形式を ZIP から **DMG** へ

### 中身
- バージョン $VERSION / ソースは同タグのコミット
- 縦書き EPUB の表示（読みやすさ優先 / EPUB のまま の2モード）
- 漫画（OMF）の綴じ方向・見開き・アスペクト比を本ごとに指定
- VOICEVOX / AivisSpeech での読み上げ、音声・動画の書き出し

### 使い方の説明
https://veltrea.github.io/tategaki-reader/

notarize（Apple の公証）は付いていません。必要な方はフォークして各自の Developer ID で
署名してください。
EOF
)"

say "リリースを作成: $TAG → $PUBLIC_REPO"
if gh release view "$TAG" -R "$PUBLIC_REPO" >/dev/null 2>&1; then
    warn "$TAG は既にあります。資材を差し替えます。"
    gh release upload "$TAG" "$DMG" -R "$PUBLIC_REPO" --clobber
else
    gh release create "$TAG" "$DMG" -R "$PUBLIC_REPO" \
        --title "$APP_NAME $VERSION" --notes "$NOTES"
fi
ok "公開: https://github.com/$PUBLIC_REPO/releases/tag/$TAG"
