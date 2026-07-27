// foliate-js を WKWebView に載せるためのブリッジ。
// Swift → JS: window.__reader.* を evaluateJavaScript で呼ぶ（結果は JSON 文字列で返す）。
// JS → Swift: window.webkit.messageHandlers.foliate.postMessage({type, ...}) で通知。
import './foliate-js/view.js'
import { Overlayer } from './foliate-js/overlayer.js'

const BOOK_URL = 'foliate:///book/current.epub'

function toSwift(msg) {
  try { window.webkit?.messageHandlers?.foliate?.postMessage(msg) } catch (e) { /* noop */ }
  if (!window.webkit?.messageHandlers?.foliate) console.log('[bridge]', JSON.stringify(msg))
}

function flatLang(x) {
  if (!x) return ''
  if (typeof x === 'string') return x
  const k = Object.keys(x)
  return k.length ? x[k[0]] : ''
}
function flatContributor(c) {
  if (!c) return ''
  if (Array.isArray(c)) return c.map(flatContributor).filter(Boolean).join('、')
  if (typeof c === 'string') return c
  return flatLang(c.name)
}
// 作者の読み（EPUB opf の file-as）。foliate の metadata は contributor.sortAs を持つ。
function contributorSortAs(c) {
  if (!c) return ''
  if (Array.isArray(c)) return contributorSortAs(c[0])
  if (typeof c === 'string') return ''
  return (typeof c.sortAs === 'string' ? c.sortAs : flatLang(c.sortAs)) || ''
}

// テーマCSS（renderer.setStyles で本文 iframe に注入。foliate が全 section に適用し続ける）。
function themeCSS(theme, fontScale, lineHeight) {
  const palettes = {
    light: { bg: '#ffffff', fg: '#1a1a1a', link: '#2563eb' },
    sepia: { bg: '#f4ecd8', fg: '#5b4636', link: '#8a5a2b' },
    dark:  { bg: '#1c1c1e', fg: '#e6e6e6', link: '#7fb2ff' },
  }
  // 'auto' はシステムのライト/ダークに追従（sepia/light/dark はそのまま）。
  let resolved = theme
  if (theme === 'auto') {
    const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
    resolved = dark ? 'dark' : 'light'
  }
  const p = palettes[resolved] || palettes.light
  const pct = Math.round((fontScale || 1) * 100)
  // 行間は指定があるときだけ本文へ適用（0/未指定なら本のスタイルを尊重）。
  const lh = (typeof lineHeight === 'number' && lineHeight > 0)
    ? `body, p, li, div { line-height: ${lineHeight} !important; }` : ''
  return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html { color-scheme: ${resolved === 'dark' ? 'dark' : 'light'}; background: ${p.bg}; color: ${p.fg}; font-size: ${pct}%; }
    body { background: ${p.bg}; color: ${p.fg}; }
    ${lh}
    a:link, a:visited { color: ${p.link}; }
    aside[epub|type~="footnote"], aside[epub|type~="endnote"] { display: none; }
    /* 挿絵・画像はビューポートに収める（アスペクト維持）。foliate は自前制約を持たないため。 */
    /* svg も対象に含める（calibre 等が表紙を <svg><image> でラップするため）。
       ただし SVG の比率を決めるのは object-fit ではなく preserveAspectRatio 属性なので、
       歪みの是正は normalizeSVGImages() の DOM パッチ側で行う。ここは寸法制約だけ。 */
    ${isFriendly() ? 'img, picture, svg { max-width: 100% !important; max-height: 95vh !important; object-fit: contain; }' : ''}
  `
}

// 表示モード。
// 'friendly': 読みやすさを優先した表示。画像を面いっぱいに出し、画像だけのページは自前で描き、
//             続く画像は見開きに組む。EPUB 側の指定の粗さは吸収する（このアプリの既定）。
// 'raw':      EPUB の指定どおりにエンジンが描いたまま。歪んだ表紙や効いていない指定が
//             そのまま見えるので、EPUB の粗を洗うのに使う。
let renderMode = 'friendly'
const isFriendly = () => renderMode === 'friendly'

const State = {
  view: null,
  index: -1,                // 表示中の章（見開きの組を決めるのに使う）
  imagePage: null,          // 画像面を直接描いているとき {index, partner}
  style: { theme: 'light', fontScale: 1.0, lineHeight: 0 },
  userCSS: '',
  // 書字方向 'auto'（本の指定に従う）/ 'vertical'（強制縦書き）/ 'horizontal'（強制横書き）。
  writingMode: 'auto',
  // OPF の primary-writing-mode（auto のときの保険。下の opfWritingHint を参照）。
  bookWritingHint: null,
  // 本全体としての読み進む向き（進捗スライダーの鏡像・左右タップの向きに使う）。
  // noteSectionDirection を参照。
  bookDir: 'ltr',
  // bookDir を本文の実測で確定できたか。false のうちは OPF 由来の暫定値。
  bookDirConfirmed: false,
  // 綴じ方向の強制 'auto' | 'rtl' | 'ltr'。auto 以外は実測にも OPF にも必ず勝つ。
  // 漫画・写真集は本文が画像だけで向きを測りようがないので、読み手の指定が最後の拠り所になる。
  forcedBinding: 'auto',
  // 見開きの強制 'auto' | 'always' | 'never'。画像ページと本文で別々に持つ
  //（漫画は見開き・小説は単ページ、のような使い分けをそのまま設定にしたいため）。
  imageSpread: 'auto',
  textSpread: 'auto',
  // 画像を当てはめる縦横比 {w, h}（null = 強制しない）。収めるのではなく引き伸ばす。
  forcedAspect: null,
  // この本から拾えた縦横比（OPF の viewport / 先頭画像の実寸）。UI の既定値に使う。
  detectedAspect: null,
  // TTS
  ttsBlocks: null,          // 現在ブロックの文リスト [{mark, text}]
  ttsHighlightCFI: null,    // 現在ハイライト中の annotation value(CFI)
  searchAbort: null,
}

// OPF の <meta name="primary-writing-mode"> を読む。
// 日本語の縦書き本を calibre で変換すると CSS の writing-mode が落ち、縦書きの意思が
// このメタにしか残らないことがある（EPUB としては非標準だが実在の本で多い）。
// foliate 本体は body の computed writing-mode しか見ないので、ここで拾って補う。
function opfWritingHint(book) {
  try {
    const opf = book?.resources?.opf
    if (!opf) return null
    for (const m of opf.querySelectorAll('meta')) {
      if (m.getAttribute('name') !== 'primary-writing-mode') continue
      const v = (m.getAttribute('content') || '').trim().toLowerCase()
      if (v.startsWith('vertical')) return 'vertical'
      if (v.startsWith('horizontal')) return 'horizontal'
    }
  } catch (e) { /* メタが無いのは普通のこと */ }
  return null
}

// OPF の <spine page-progression-direction>。本全体のページ送りの向きの暫定値に使う。
//
// 本文の実測（pageDirection）より弱い扱いにしているのは、横組みへ変換された本でも
// rtl が残っていることがあるため。それでも読むのは、primary-writing-mode を持たない本が
// 多数派だから——手元の書棚 37 冊で ppd は 37 冊全部が rtl を持つのに対し、
// primary-writing-mode は 14 冊しか持っていない。ppd を捨てると、残りの本は
// 「本文を一度描くまで縦書きだと分からない」状態になる（下の noteSectionDirection 参照）。
function opfPageDirection(book) {
  try {
    const spine = book?.resources?.opf?.querySelector('spine')
    const v = (spine?.getAttribute('page-progression-direction') || '').trim().toLowerCase()
    return (v === 'rtl' || v === 'ltr') ? v : null
  } catch (e) { /* 無いのは普通のこと */ }
  return null
}

// 表示の強制（綴じ方向・見開き・アスペクト比）を opts から読む。
// 本を開くときと、あとから設定を変えたときの両方から通る。知らないキーは触らない
//（Swift 側が一部だけ送ってくることがあるため）。
function readDisplayOverrides(opts = {}) {
  if (['auto', 'rtl', 'ltr'].includes(opts.binding)) State.forcedBinding = opts.binding
  if (['auto', 'always', 'never'].includes(opts.imageSpread)) State.imageSpread = opts.imageSpread
  if (['auto', 'always', 'never'].includes(opts.textSpread)) State.textSpread = opts.textSpread
  if ('aspect' in opts) State.forcedAspect = normalizeAspect(opts.aspect)
}

// {w, h} 形式の縦横比に整える。読めない値は null（＝強制しない）。
function normalizeAspect(a) {
  if (!a) return null
  const w = Number(a.w ?? a.width), h = Number(a.h ?? a.height)
  return (w > 0 && h > 0) ? { w, h } : null
}

// この本のページの縦横比を拾う。強制アスペクト比の既定値としてUIに出すためのもので、
// 拾えなくても表示には影響しない。
//
// 見るのは OPF の viewport 系メタ。漫画の EPUB は判型をここに書く慣習があり、
// OMF（日本の漫画配信で使われる形式）は omf:viewport、EPUB 3 の固定レイアウトは
// rendition:viewport に "width=844, height=1200" の形で入る。
// 無い本は先頭の画像の実寸から拾う（imageRatioOf 側で後追いする）。
function detectBookAspect(book) {
  try {
    const opf = book?.resources?.opf
    if (!opf) return null
    for (const m of opf.querySelectorAll('meta')) {
      const prop = (m.getAttribute('property') || m.getAttribute('name') || '').toLowerCase()
      if (!prop.endsWith('viewport')) continue
      const text = (m.getAttribute('content') || m.textContent || '')
      const w = /width\s*=\s*(\d+(?:\.\d+)?)/i.exec(text)
      const h = /height\s*=\s*(\d+(?:\.\d+)?)/i.exec(text)
      if (w && h) return normalizeAspect({ w: parseFloat(w[1]), h: parseFloat(h[1]) })
    }
  } catch (e) { /* メタが無いのは普通のこと */ }
  return null
}

// OPF に判型が書いていない本のために、最初のほうの画像面の実寸から縦横比を拾う。
// 強制アスペクト比の入力欄に出す既定値を作るだけなので、拾えなくても表示は変わらない。
async function fillAspectFromFirstImage() {
  try {
    const n = State.view?.book?.sections?.length ?? 0
    for (let i = 0; i < Math.min(n, 8); i++) {
      if (!(await isImageSection(i))) continue
      const src = await sectionImageSrc(i)
      if (!src) continue
      const size = await new Promise(resolve => {
        const img = new Image()
        img.onload = () => resolve({ w: img.naturalWidth, h: img.naturalHeight })
        img.onerror = () => resolve(null)
        img.src = src
      })
      if (size && size.w > 0 && size.h > 0) { State.detectedAspect = size; return }
    }
  } catch (e) { /* 既定値を出せないだけ */ }
}

// 前付け・後付け（表紙・目次・奥付など）か。本文ではないので、本全体の向きの判断材料にしない。
//
// 日本語の EPUB では、これらの面だけが本文と別系統で作られていることが非常に多い。
// 青空文庫由来の本は表紙が cover.css（縦書き指定なし）だけを読み、本文は nsepub-v.css で
// 縦書きにする——という形が手元の 10 冊すべてで一致した。初期に作られた 1 冊が
// テンプレートとして複製され続けた結果と思われる。表紙を本文の代表として測ると、
// 縦書きの本を横組みと誤認する。
const MATTER_TYPES =
  /\b(cover|toc|landmarks|frontmatter|backmatter|titlepage|halftitlepage|colophon|copyright-page|imprint|dedication|acknowledgments|bibliography|index)\b/i
function isFrontOrBackMatter(doc) {
  try {
    const els = [doc.documentElement, doc.body,
      doc.body?.firstElementChild, doc.querySelector('section, div')]
    for (const el of els) {
      if (!el) continue
      // XHTML として読まれた文書では epub:type は名前空間付き属性になる。
      const v = el.getAttribute?.('epub:type')
        || el.getAttributeNS?.('http://www.idpf.org/2007/ops', 'type')
        || el.getAttribute?.('role') || ''
      if (MATTER_TYPES.test(v)) return true
    }
  } catch (e) { /* 判定できなければ本文とみなす */ }
  return false
}

// 組み方向クラス（EBPAJ の制作ガイドが定めた慣習）の既定。
// 日本の商業 EPUB は html 要素に vrtl/vltr/hltr/hrtl を付け、writing-mode 自体は本の CSS
// 側で当てる約束になっている。ところが変換を経た本ではクラスだけが残って定義が落ちている
// ことがあり（手元の書棚 26 冊のうち 5 冊。うち 3 冊は OPF の primary-writing-mode も無く、
// 縦書きの痕跡がこのクラスしか残っていない）、縦書きの本が横書きで開いてしまう。
// 定義が生きている本はそちらを優先させたいので、本の CSS より前に弱く置く。
// body でなく html にだけ当てるのも同じ理由（writing-mode は継承するので body へは届くが、
// body に直接当てると本が body に書いた指定を詳細度で踏み潰してしまう）。
const WM_CLASS_CSS = [
  ['vrtl', 'vertical-rl'], ['vltr', 'vertical-lr'],
  ['hltr', 'horizontal-tb'], ['hrtl', 'horizontal-tb'],
].map(([cls, wm]) => `html.${cls} { writing-mode: ${wm};`
  + ` -webkit-writing-mode: ${wm}; -epub-writing-mode: ${wm}; }`).join('\n')

// 上のクラスを持たない文書。OPF メタ由来の補いはここにだけ効かせる
// （縦書き本でも前付け・奥付は hltr＝横組みのことがあり、本全体を縦書きにすると壊れる）。
const WM_UNCLASSED = 'html:not(.vrtl):not(.vltr):not(.hltr):not(.hrtl)'

// 書字方向の指定。[本のCSSより前に置くもの, 後に置くもの] で返す
// （paginator.setStyles は配列を受け取ると head の先頭/末尾へ振り分ける）。
// 強制モードは本の指定に必ず勝たせたいので後段＋!important、
// auto の補い（クラスの既定・メタ由来）は「本が明示していればそちらを尊重」したいので前段。
function writingModeCSS() {
  const decl = wm =>
    `${WM_UNCLASSED}, ${WM_UNCLASSED} > body { writing-mode: ${wm};`
    + ` -webkit-writing-mode: ${wm}; -epub-writing-mode: ${wm}; }`
  const declHard = wm =>
    `html, body { writing-mode: ${wm} !important; -webkit-writing-mode: ${wm} !important;`
    + ` -epub-writing-mode: ${wm} !important; }`
  const mode = State.writingMode
  if (mode === 'vertical') return ['', declHard('vertical-rl')]
  if (mode === 'horizontal') return ['', declHard('horizontal-tb')]
  const hint = State.bookWritingHint === 'vertical' ? '\n' + decl('vertical-rl') : ''
  return [WM_CLASS_CSS + hint, '']
}

// 縦書きで見開きにするときの本文ブロックの幅。paginator の既定（--_max-block-size: 1440px）
// の2倍＝紙でいう見開き1面ぶん。画面より広ければ paginator のグリッドが頭打ちにするので、
// 狭い窓でも破綻しない。
const VERTICAL_SPREAD_BLOCK_SIZE = '2880px'

// 直近に反映した見開きの状態（'mode:vertical'）。relocate のたびに呼ばれるので、
// 変わっていないときは何もしない（render を呼び直すと組版がやり直しになる）。
let appliedTextSpread = null

// 本文の見開き。横書きと縦書きで、効かせるところがまったく違う。
//
// **横書き**は列数で決まる。paginator は既定で「横長の画面なら2列・縦長なら1列」に
// 切り替える（--_max-column-count と --_max-column-count-portrait）。auto はそれに任せ、
// always/never はどちらの向きでも固定したいので portrait 用の変数も一緒に倒す。
// shadow root が closed で外から #top に触れないため、paginator 側に
// max-column-count-portrait 属性を通す最小パッチを当ててある。
//
// **縦書き**では列数を増やしても見開きにならない。CSS の多段組は列を inline 方向へ積むので、
// 縦書き（inline＝上下）では列が上下に並び、「上段が1ページ・下段が次のページ」という
// 紙とは似ても似つかない形になる。縦書きの1ページは block 方向（右→左）の幅で決まるので、
// 本文ブロックの幅そのものを広げる。こうすると行が右上から左へ続けて流れ、
// めくる単位も2ページぶんになる——紙の見開きと同じ読み方になる。
function applyTextSpread(doc, { rerender = false } = {}) {
  const r = State.view?.renderer
  if (!r?.setAttribute) return false
  const vertical = doc?.body ? isVerticalDoc(doc) : false
  const key = State.textSpread + ':' + vertical
  if (appliedTextSpread === key) return false
  appliedTextSpread = key

  const columns = (!vertical && State.textSpread === 'always') ? '2'
    : (!vertical && State.textSpread === 'never') ? '1' : null
  for (const attr of ['max-column-count', 'max-column-count-portrait']) {
    if (columns == null) r.removeAttribute(attr)
    else r.setAttribute(attr, columns)
  }
  if (vertical && State.textSpread === 'always') {
    r.setAttribute('max-block-size', VERTICAL_SPREAD_BLOCK_SIZE)
  } else {
    // never は既定に戻すだけでよい（縦書きの既定は元々1ページぶんの幅）。
    r.removeAttribute('max-block-size')
  }
  if (rerender) r.render?.()
  return true
}

function applyStyles() {
  if (!State.view) return
  const [pre, post] = writingModeCSS()
  const css = themeCSS(State.style.theme, State.style.fontScale, State.style.lineHeight)
    + '\n' + (State.userCSS || '') + '\n' + post
  State.view.renderer?.setStyles?.([pre, css])
}

// これ以下しか文字が無い面は「絵の面」とみなす（キャプション・ノンブル程度は許す）。
const TEXTLESS_MAX_CHARS = 10

// この面は書字方向の証拠になるか。
//
// ならないのは絵だけの面である。漫画・写真集の EPUB は全ページが画像1枚で、日本の
// 配信フォーマット（OMF 等）では spine が XHTML を挟まず JPEG を直接指すことさえある。
// その場合 iframe に載るのは WebKit が画像のために作る文書なので、body は必ず
// horizontal-tb / ltr になる——本の綴じ方とは何の関係もない値である。これを本文の実測と
// して採ると、右綴じの漫画が必ず左綴じに倒れる（noteSectionDirection の確定処理を参照）。
// 絵の面には向きの手がかりが原理的に無いので、OPF の ppd を暫定値のまま残す。
function hasDirectionEvidence(doc) {
  if ((doc.contentType || '').startsWith('image/')) return false
  const text = (doc.body?.textContent || '').replace(/[\s　]/g, '')
  return text.length > TEXTLESS_MAX_CHARS
}

// ページ送りの向き。縦書きは常に右→左。横書きは本文の direction が rtl のときだけ右→左。
// spine の page-progression-direction は見ない: 日本語の変換本は横組みになっていても
// rtl のまま残っていることが多く、それを信じるとページ送り・スライダー・矢印キーだけが
// 逆を向いて本文とちぐはぐになる。
function pageDirection(doc) {
  if (!doc?.body) return 'ltr'
  if (isVerticalDoc(doc)) return 'rtl'
  const dir = doc.defaultView.getComputedStyle(doc.body).direction
  return (dir === 'rtl' || doc.body.dir === 'rtl' || doc.documentElement.dir === 'rtl')
    ? 'rtl' : 'ltr'
}

// 表示中セクションの向きを Swift へ渡す形にまとめ、ついでに本全体の向きを更新する。
//
// 向きは本ではなく章ごとの性質である（foliate の paginator も getDirection を章ごとに
// 呼んで #vertical/#rtl を決め直す）。縦書きの本でも表紙・前付け・目次・奥付は横組みなので、
// 開いた瞬間の1回だけ測って本全体の値として固定すると、着地した章によって当たり外れが出る。
// dir/vertical（返り値）は「いま画面に組まれているもの」なので、朗読動画の縦横のように
// 描画そのものを合わせたいところだけがこれを使う。
//
// 一方、進捗スライダーの鏡像と左右タップの向きは本単位でなければならない。章ごとの値だと、
// 摘みが章をまたぐたび左右へ飛び、同じ左タップの意味が進む⇄戻るへ反転する。そこで bookDir は
// 縦書き／RTL の章を一度でも見たら rtl に倒し、以後戻さない（横書きの本が縦書きの章を
// 持つことはないので、これで誤って鏡像化はしない）。
//
// 問題は「本文を一度も描いていない間」——つまり表紙を開いた直後である。ここで bookDir を
// 取り違えると、左右タップだけが逆を向く。実際、青空文庫由来の本は表紙が横組みで
// primary-writing-mode も持たないため、表紙にいる間は横組みの本と見分けがつかず、
// 左タップ（縦書きなら「進む」）が「戻る」になって無反応だった（手元の 10 冊すべてで発生）。
// そこで開くときに OPF の ppd を暫定値として入れておき（opfPageDirection 参照）、
// 本文——前付け・後付けでない章——を実測するまでは下ろさない。実測で横組みだと分かれば
// そこで ltr に確定するので、ppd が残骸だった本も取りこぼさない。
function noteSectionDirection(doc) {
  if (!doc?.body) return { vertical: false, dir: State.bookDir }
  const vertical = isVerticalDoc(doc)
  // 読み手が綴じ方向を決めているなら、本の申告も実測も見ない。
  // 章ごとの dir も強制値で返す（左右タップと画面の見え方を食い違わせないため）。
  if (State.forcedBinding !== 'auto') {
    State.bookDir = State.forcedBinding
    State.bookDirConfirmed = true
    return { vertical, dir: State.forcedBinding }
  }
  const dir = pageDirection(doc)
  if (dir === 'rtl') {
    State.bookDir = 'rtl'
    State.bookDirConfirmed = true
  } else if (!State.bookDirConfirmed && !isFrontOrBackMatter(doc) && hasDirectionEvidence(doc)) {
    // 本文が横組み＝OPF の ppd は変換で残った残骸だった。暫定値を下ろして確定する。
    // 絵だけの面は根拠にしない（hasDirectionEvidence を参照）。
    State.bookDir = 'ltr'
    State.bookDirConfirmed = true
  }
  return { vertical, dir }
}

// ---- SVG ラップ画像のアスペクト比を是正 ----
// calibre 変換 EPUB の表紙は <svg width="100%" height="100%" preserveAspectRatio="none">
// <image .../></svg> という形が定番で、"none" は「比率を無視してボックスいっぱいに伸ばせ」の意。
// エンジンは指示どおりに描くので表紙が縦に潰れる。CSS では直せない
// （preserveAspectRatio は CSS プロパティではなく、object-fit は SVG 要素に効かない）ため、
// 属性そのものを既定値 xMidYMid meet に書き換える。
function normalizeSVGImages(doc) {
  try {
    for (const el of doc.querySelectorAll('svg[preserveAspectRatio], image[preserveAspectRatio]')) {
      const v = (el.getAttribute('preserveAspectRatio') || '').trim()
      // "none" 単独、および "none slice" のような meetOrSlice 付きも対象。
      if (!/^none\b/i.test(v)) continue
      el.__bridgeOrigPAR = v          // raw モードでは元に戻して、歪みをそのまま見せる
      el.setAttribute('preserveAspectRatio', 'xMidYMid meet')
    }
  } catch (e) { /* 壊れた文書でも読書は続行 */ }
}

// ---- 縦書き前提の「ぶら下げインデント」を、実際の書字方向に合わせて置き直す ----
// 日本語の本は章見出しなどを text-indent:-5.2em と padding-top:5.2em の対で組むことが多い。
// 縦書きでは padding-top が行の先頭側なので負のインデントをちょうど打ち消すが、横書きで
// 描くと text-indent は左へ効くのに padding は上のままなので、打ち消しが外れて見出しが
// 枠の外＝ページの余白側へ飛び出す（実本の章扉で 79px はみ出すのを実測）。
// 打ち消すべきなのは常に「行の先頭側」＝padding-inline-start なので、対になっている物理
// padding と同じ量をそちらへ入れ直す。逆向き（横書き前提の本を縦書きで読む）にも効く。
// 対の padding を持たない負インデントは本来のぶら下げ組みなので触らない。
function fixHangingIndent(doc) {
  try {
    if (!doc?.body || doc.__hangIndentFixed) return
    const win = doc.defaultView
    if (!win) return
    doc.__hangIndentFixed = true
    const vertical = isVerticalDoc(doc)
    for (const el of doc.body.querySelectorAll('*')) {
      const cs = win.getComputedStyle(el)
      const indent = parseFloat(cs.textIndent) || 0
      if (!(indent < -4)) continue
      const need = -indent
      const pad = side => parseFloat(cs['padding' + side]) || 0
      const start = vertical ? 'Top' : (cs.direction === 'rtl' ? 'Right' : 'Left')
      if (Math.abs(pad(start) - need) <= 2) continue   // すでに先頭側にある＝そのままで正しい
      const donor = ['Top', 'Left', 'Right', 'Bottom']
        .find(s => s !== start && Math.abs(pad(s) - need) <= 2)
      if (!donor) continue
      el.style.setProperty('padding-' + start.toLowerCase(), need + 'px', 'important')
    }
  } catch (e) { /* 補正は保険なので、失敗しても読書は続ける */ }
}

// 比率の是正を取り消して、EPUB の指定どおりの描画に戻す。
function restoreSVGImages(doc) {
  try {
    for (const el of doc.querySelectorAll('svg, image')) {
      if (!el.__bridgeOrigPAR) continue
      el.setAttribute('preserveAspectRatio', el.__bridgeOrigPAR)
      el.__bridgeOrigPAR = null
    }
  } catch (e) { /* noop */ }
}

// こちらが画像に付けた寸法を剥がす（raw へ切り替えるとき）。
// paginator 自身の max-* は次の render で入れ直されるので、まとめて消してよい。
function clearImageTweaks(doc) {
  try {
    for (const el of doc.body.querySelectorAll('img, svg')) {
      if (el.__bridgeFitH == null) continue
      el.__bridgeFitH = null
      el.__bridgeFitForced = null
      for (const prop of ['height', 'max-height', 'width', 'max-width', 'object-fit'])
        el.style.removeProperty(prop)
    }
  } catch (e) { /* noop */ }
}

// ---- 目次のリンク切れを拾う ----
// 変換を経た本では、spine から外れたファイルを目次が指したまま残ることがある
// （calibre が表紙を差し替えると、目次の「表紙」だけ古い c0.xhtml を指し続ける等）。
// そのままだとその項目だけ黙って反応しない。friendly ではファイル名や目次の並びから
// 行き先を推し量って飛ばす。raw では EPUB の不備をそのまま見せる。
async function guessSectionFor(href) {
  const book = State.view?.book
  if (!book?.sections?.length) return null
  const name = String(href).split('#')[0].split('/').pop()
  const byName = book.sections.findIndex(s => String(s.id || '').split('/').pop() === name)
  if (byName >= 0) return byName
  const toc = book.toc || []
  const pos = toc.findIndex(t => t.href === href)
  if (pos < 0) return null
  if (pos === 0) return 0        // 目次の先頭項目（たいてい表紙）は spine の先頭
  for (let i = pos - 1; i >= 0; i--) {   // 直前に飛べる項目の次の章まで送る
    try {
      const r = book.resolveHref(toc[i].href)
      if (r && r.index >= 0) return Math.min(r.index + 1, book.sections.length - 1)
    } catch (e) { /* この項目も壊れている。さらに前を見る */ }
  }
  return 0
}

async function goToTarget(target) {
  const view = State.view
  if (!view) return
  try {
    const r = await view.goTo(target)
    if (!r || r.index >= 0) return r    // 解決できた（CFI 等は index を返さないこともある）
  } catch (e) { /* 解決に失敗。下で拾い直す */ }
  if (!isFriendly()) return
  const idx = await guessSectionFor(target)
  slog('goTo fallback', String(target).slice(-16), '->', idx)
  if (idx != null) return State.view?.renderer?.goTo?.({ index: idx, anchor: 0 })
}

// ---- 画像だけのページは EPUB エンジンに載せず、こちらで直接描く ----
// 列レイアウトに載せると、本の CSS が付けたラッパ・SVG 包みの癖・縦組み判定に振り回されて
// 拡大も見開きも安定しない。位置の管理（進捗・しおり・CFI）は foliate に任せたまま、
// 描画だけ引き取る。こうすると画面いっぱいの表示も見開きも素直に決まる。
let imageLayer = null

function ensureImageLayer() {
  if (imageLayer) return imageLayer
  const el = document.createElement('div')
  el.id = 'image-page-layer'
  Object.assign(el.style, {
    position: 'fixed', inset: '0', display: 'none',
    alignItems: 'center', justifyContent: 'center', gap: '0',
    zIndex: '3', pointerEvents: 'none', overflow: 'hidden',
  })
  document.body.append(el)
  imageLayer = el
  return el
}

function hideImageLayer() {
  if (imageLayer) {
    imageLayer.style.display = 'none'
    imageLayer.replaceChildren()
  }
  if (State.view) State.view.style.visibility = ''
  State.imagePage = null
}

// これ未満の画像は本文中の記号・ロゴ・飾りとみなして拡大しない（巨大化を防ぐ）。
// 挿絵は普通 600px 以上あるので、この値で取りこぼしはしない。
const FIT_MIN_NATURAL = 200

// 拡大してよい画像か。行の中に文字と並んでいるものと、ロゴ・飾り程度の小さな画像は外し、
// 単独のブロックとして置かれている図版（表紙・口絵・挿絵）だけを拾う。
function isFigureImage(el) {
  const doc = el.ownerDocument
  const win = doc.defaultView
  if (el.tagName === 'IMG') {
    // naturalWidth は読み込み後にしか入らない。呼び出し側で complete を確かめてから来る。
    const w = el.naturalWidth || 0, h = el.naturalHeight || 0
    if (!w || !h) return false
    if (Math.min(w, h) < FIT_MIN_NATURAL) return false
  } else {
    // svg には固有サイズが無いので、いま描かれている大きさで判断する。
    const r = el.getBoundingClientRect()
    if (Math.min(r.width, r.height) < FIT_MIN_NATURAL) return false
  }
  // 同じ行に文字と並んでいる画像（本文中の記号など）は拡大しない。
  // 見るのは「同じ親の中で自分と行を共有しうるもの」＝テキストノードとインライン要素だけ。
  // 別の段落など兄弟のブロック要素は、行を共有しないので数えない。
  const parent = el.parentElement
  if (!parent) return false
  let inlineText = ''
  for (const node of parent.childNodes) {
    if (node === el) continue
    if (node.nodeType === 3) inlineText += node.textContent
    else if (node.nodeType === 1 && win.getComputedStyle(node).display.startsWith('inline'))
      inlineText += node.textContent
  }
  return inlineText.replace(/[\s　]/g, '').length === 0
}

// ページの向き。foliate 自身と同じく body の writing-mode で見る
// （縦書き本でも documentElement は horizontal-tb のままのことが多い）。
function isVerticalDoc(doc) {
  const wm = doc.defaultView.getComputedStyle(doc.body).writingMode || ''
  return wm === 'vertical-rl' || wm === 'vertical-lr'
}

// 1ページぶんの内寸。columnize は列の inline サイズを column-width に、
// ブロック方向のサイズを documentElement の width/height に入れる。
// iframe 自体は expand で全ページ分に引き伸ばされるので innerHeight/Width は使えない。
function pageBox(doc) {
  const de = doc.documentElement
  const cs = doc.defaultView.getComputedStyle(de)
  const colSize = parseFloat(cs.columnWidth) || 0
  const padY = (parseFloat(cs.paddingTop) || 0) + (parseFloat(cs.paddingBottom) || 0)
  const padX = (parseFloat(cs.paddingLeft) || 0) + (parseFloat(cs.paddingRight) || 0)
  return isVerticalDoc(doc)
    ? { h: colSize, w: Math.max(0, de.clientWidth - padX) }
    : { h: Math.max(0, de.clientHeight - padY), w: colSize }
}

// 画像の縦横比（幅÷高さ）。img は実寸から、svg は viewBox から取る。
function naturalRatio(el) {
  if (el.naturalWidth > 0 && el.naturalHeight > 0) return el.naturalWidth / el.naturalHeight
  const vb = el.getAttribute?.('viewBox')
  if (vb) {
    const p = vb.trim().split(/[\s,]+/).map(Number)
    if (p.length === 4 && p[2] > 0 && p[3] > 0) return p[2] / p[3]
  }
  return 0
}

// ホスト側の表示枠の高さ。計算値が壊れたときに画像が無限に伸びるのを防ぐ上限として使う。
function hostViewportHeight(doc) {
  try {
    const frame = doc.defaultView.frameElement
    const container = frame?.parentElement?.parentElement   // #element → #container
    return container?.getBoundingClientRect?.().height || 0
  } catch (e) { return 0 }
}

// paginator の setImageSize は render のたびに max-* を !important で入れ直すため、
// こちらも !important で、かつ render の後（relocate）に上書きする。
function fitImages(doc) {
  try {
    if (!doc?.body) return
    const box = pageBox(doc)
    let h = Math.round(box.h)
    const cap = Math.round(hostViewportHeight(doc))
    if (cap > 0) h = Math.min(h, cap)
    if (!(h > 0)) return
    const pageW = Math.round(box.w)
    for (const el of doc.body.querySelectorAll('img, svg')) {
      // 実寸が分かる前に判定すると、ロゴのような小さな画像まで拡大してしまう。
      if (el.tagName === 'IMG' && !el.complete) {
        if (!el.__bridgeFitWaiting) {
          el.__bridgeFitWaiting = true
          el.addEventListener('load', () => fitImages(doc), { once: true })
        }
        continue
      }
      if (!isFigureImage(el)) continue
      // 横長の画像は幅からはみ出さない高さに抑える（ボックスと絵柄をぴったり一致させる）。
      // 比率を強制しているときは、絵の実比率ではなく指定の比率で枠を決める。
      const forced = State.forcedAspect
      const ratio = forced ? forced.w / forced.h : naturalRatio(el)
      let target = h
      if (ratio > 0 && pageW > 0) target = Math.min(h, Math.round(pageW / ratio))
      if (el.__bridgeFitH === target && el.__bridgeFitForced === !!forced) continue
      el.__bridgeFitH = target
      el.__bridgeFitForced = !!forced
      el.style.setProperty('height', `${target}px`, 'important')
      el.style.setProperty('max-height', `${target}px`, 'important')
      if (forced) {
        // 指定の比率へ引き伸ばす。幅も決め打ちしないと絵の実比率のままになる。
        el.style.setProperty('width', `${Math.round(target * ratio)}px`, 'important')
        el.style.setProperty('max-width', '100%', 'important')
        el.style.setProperty('object-fit', 'fill', 'important')
        continue
      }
      // 比率が分かるなら幅は成り行きでよい（img は実寸、svg は viewBox から決まる）。
      // viewBox の無い svg だけは固有サイズを持たず width:auto で潰れるので枠いっぱいにする。
      el.style.setProperty('width', ratio > 0 ? 'auto' : '100%', 'important')
      el.style.setProperty('max-width', '100%', 'important')
      el.style.setProperty('object-fit', 'contain', 'important')
    }
  } catch (e) { /* 画像が無くても読書は続行 */ }
}

// ---- 画像ページの見開き（Kindle と同じ考え方） ----
// 固定レイアウトでなくても、Kindle は画像だけのページが続くと2枚ずつ組にして見せる。
// ここでも同じにする: 表紙は単独、そこから2枚ずつ。右綴じなら先のページが右。
// 実際の本は透明ページの入れ忘れ等で組がずれるので、丸ごと1ページずらせるようにしてある
// （`toggleSpread`。ネイティブの「見開きをずらす」ボタンから呼ぶ）。
const sectionKind = new Map()    // index -> 'image' | 'text'（章の中身を読んだ結果のキャッシュ）
let spreadOffset = 0             // 0 or 1。組全体を1ページずらす
let spreadRedirecting = false    // 組の2枚目へ来たときの跳ね返し中
const spreadLog = []             // 挙動追跡用（spreadState で読める）
function slog(...a) {
  spreadLog.push(a.join(' '))
  if (spreadLog.length > 40) spreadLog.shift()
}

// 章の XHTML を読む（foliate が resource を blob URL に置換済みなので、そのまま表示に使える）。
async function sectionDoc(index) {
  const s = State.view?.book?.sections?.[index]
  if (!s) return null
  const url = await s.load()
  const html = await (await fetch(url)).text()
  return new DOMParser().parseFromString(html, 'application/xhtml+xml')
}

// spine のこの項目が指すファイルの media-type。
//
// EPUB の spine は本来 XHTML を指すものだが、日本の漫画・写真集の配信形式（OMF）は
// **XHTML を挟まず JPEG を直接 spine に並べる**。その章を XHTML としてパースしても
// 当然失敗するので、パースの前にここで見分ける。見分けないと画像章がすべて
// 「テキストの章」に落ち、見開きも画像レイヤーも一切効かなくなる。
function sectionMediaType(index) {
  const href = State.view?.book?.sections?.[index]?.id
  if (!href) return ''
  const item = State.view?.book?.resources?.manifest?.find(i => i.href === href)
  return (item?.mediaType || '').toLowerCase()
}
const isImageSpineItem = index => sectionMediaType(index).startsWith('image/')

function imageSrcOf(doc) {
  const el = doc?.body?.querySelector('img, image')
  if (!el) return ''
  return el.getAttribute('src')
    || el.getAttributeNS('http://www.w3.org/1999/xlink', 'href')
    || el.getAttribute('xlink:href') || ''
}

// この章の絵の URL。spine が画像を直接指しているなら、その章のロード結果が絵そのもの。
async function sectionImageSrc(index) {
  const s = State.view?.book?.sections?.[index]
  if (!s) return ''
  if (isImageSpineItem(index)) {
    try { return await s.load() } catch (e) { return '' }
  }
  return imageSrcOf(await sectionDoc(index))
}

async function isImageSection(index) {
  if (index < 0) return false
  if (sectionKind.has(index)) return sectionKind.get(index) === 'image'
  let kind = 'text'
  if (isImageSpineItem(index)) kind = 'image'
  else try {
    const doc = await sectionDoc(index)
    if (doc && detectImagePage(doc)) kind = 'image'
  } catch (e) { /* 読めない章はテキスト扱いにして先へ進む */ }
  sectionKind.set(index, kind)
  return kind === 'image'
}

// 本が申告しているこの面の左右（spine itemref の page-spread-left/right）。
// 漫画の EPUB はこれを全面に持っていることが多く、持っているなら組の正解はこれで決まる
//（透明ページの入れ忘れを疑って数え直す必要がない）。
function declaredSide(index) {
  const s = State.view?.book?.sections?.[index]?.pageSpread
  return (s === 'left' || s === 'right') ? s : null
}
// 見開きの組で先に来る側。右綴じは右ページが先。
const leadSide = () => State.bookDir === 'rtl' ? 'right' : 'left'
const trailSide = () => State.bookDir === 'rtl' ? 'left' : 'right'

// 画像ページが続く区間で、組が始まる index。spine 先頭から続く区間は表紙を単独にする。
async function spreadBase(index) {
  let start = index
  while (start > 0 && await isImageSection(start - 1)) start--
  return (start === 0 ? 1 : start) + (spreadOffset ? 1 : 0)
}

// 章の画像の縦横比（幅÷高さ）。読み込んで実寸を測るので結果はキャッシュする。
const sectionRatio = new Map()
async function imageRatioOf(index) {
  if (sectionRatio.has(index)) return sectionRatio.get(index)
  let ratio = 0
  try {
    if (!isImageSpineItem(index)) {
      const doc = await sectionDoc(index)
      const svg = doc?.body?.querySelector('svg[viewBox]')
      if (svg) ratio = naturalRatio(svg)
    }
    if (!ratio) {
      const src = await sectionImageSrc(index)
      if (src) ratio = await new Promise(resolve => {
        const img = new Image()
        img.onload = () => resolve(img.naturalHeight > 0 ? img.naturalWidth / img.naturalHeight : 0)
        img.onerror = () => resolve(0)
        img.src = src
      })
    }
  } catch (e) { /* 測れなければ縦長扱い（=組める）にしておく */ }
  sectionRatio.set(index, ratio)
  return ratio
}

// 横長の画像は、それ自体がもう見開き1枚として描かれている。2枚並べても意味が無いので
// 単独で1見開きを占める（Kindle も幅に2枚入らないものは並べない）。
async function isWideImage(index) {
  return (await imageRatioOf(index)) > 1
}

// 区間の先頭から順に組を積み上げて、この章が属する組を返す。
// 横長が挟まると1面で1見開きを使うので、そこから先の組は1つずれる。
// 返り値 { first, partner }。partner が null なら単独ページ。
async function spreadGroupOf(index) {
  const single = { first: index, partner: null }
  if (State.imageSpread === 'never') return single
  if (index < 0 || !(await isImageSection(index))) return single

  // 本が page-spread-left/right を申告しているなら、それが組の正解。数え直すより確実で、
  // 透明ページの入れ忘れでずれた本も本の申告どおりに組める（declaredSide のコメント参照）。
  const side = declaredSide(index)
  if (side && State.imageSpread !== 'always') {
    if (side === leadSide() && declaredSide(index + 1) === trailSide()
        && await isImageSection(index + 1)) return { first: index, partner: index + 1 }
    if (side === trailSide() && declaredSide(index - 1) === leadSide()
        && await isImageSection(index - 1)) return { first: index - 1, partner: index }
    return single      // 相方のいない面（見開きの片割れが無い＝単独で置かれている）
  }

  const base = await spreadBase(index)
  if (index < base) return single       // 表紙、およびずらしで押し出された面
  // 強制見開きでは横長かどうかを見ない（本の作りが粗くて自動で組まれない本の救済なので、
  // 読み手が「常に見開き」と言った以上は機械的に2枚ずつ並べる）。
  const forced = State.imageSpread === 'always'
  let i = base
  for (let guard = 0; guard < 1000 && i <= index; guard++) {
    let partner = null
    if ((forced || !(await isWideImage(i)))
        && await isImageSection(i + 1)
        && (forced || !(await isWideImage(i + 1)))) partner = i + 1
    const span = partner == null ? 1 : 2
    if (index < i + span) return { first: i, partner }
    i += span
  }
  return single
}

// この章が組の1枚目なら相方の index。単独ページ・組の2枚目なら null。
async function spreadPartnerOf(index) {
  const g = await spreadGroupOf(index)
  return g.first === index ? g.partner : null
}

function imageReady(img) {
  return new Promise(resolve => {
    if (img.complete) return resolve()
    img.addEventListener('load', resolve, { once: true })
    img.addEventListener('error', resolve, { once: true })
  })
}

// 画像ページを直接描く。単独なら1枚、組なら2枚を左右に並べる（右綴じは先のページが右）。
async function showImagePage(index) {
  const first = await sectionImageSrc(index)
  slog('show', 'idx=' + index, 'src=' + (first ? 'ok' : 'none'))
  if (!first) { hideImageLayer(); return }
  const partner = await spreadPartnerOf(index)
  const srcs = [first]
  if (partner != null) {
    const second = await sectionImageSrc(partner)
    if (second) srcs.push(second)
  }
  slog('show', 'idx=' + index, 'partner=' + partner, 'n=' + srcs.length)

  const layer = ensureImageLayer()
  // 並べる向きは本の綴じ方向（State.bookDir）で決める。book.dir は OPF の
  // page-progression-direction そのままなので、読み手の強制指定が効かない。
  layer.style.flexDirection = State.bookDir === 'rtl' ? 'row-reverse' : 'row'
  layer.style.background = pageBackground()
  const imgs = srcs.map(src => {
    const img = document.createElement('img')
    img.src = src
    Object.assign(img.style, {
      display: 'block', blockSize: 'auto', inlineSize: 'auto',
      height: '100%', width: 'auto',
      maxHeight: '100%', maxWidth: `${Math.floor(100 / srcs.length)}%`,
      objectFit: 'contain',
    })
    return img
  })
  layer.replaceChildren(...imgs)
  layer.style.display = 'flex'
  if (State.view) State.view.style.visibility = 'hidden'
  State.imagePage = { index, partner }
  layoutImageLayer()
  await Promise.all(imgs.map(imageReady))
}

// 強制アスペクト比のとき、画像を指定比率へ引き伸ばして置き直す。
//
// 比率を CSS の aspect-ratio だけで当てると、幅の上限に当たったときに高さが追従せず
// 比率が崩れる（置換要素の width/height は auto と固定値が混ざると解決順が変わる）。
// 枠を実測して px で入れるほうが確実なので、そうしている。窓の大きさが変われば入れ直す。
function layoutImageLayer() {
  if (!imageLayer || !State.imagePage) return
  const imgs = [...imageLayer.querySelectorAll('img')]
  if (!imgs.length) return
  const ar = State.forcedAspect
  if (!ar) {
    // 強制なし＝元の比率のまま収める（showImagePage が入れた指定に戻す）。
    for (const img of imgs) Object.assign(img.style, {
      width: 'auto', height: '100%',
      maxWidth: `${Math.floor(100 / imgs.length)}%`, maxHeight: '100%',
      objectFit: 'contain',
    })
    return
  }
  const boxW = imageLayer.clientWidth / imgs.length
  const boxH = imageLayer.clientHeight
  if (!(boxW > 0 && boxH > 0)) return
  const ratio = ar.w / ar.h
  let w = boxH * ratio, h = boxH
  if (w > boxW) { w = boxW; h = boxW / ratio }
  for (const img of imgs) Object.assign(img.style, {
    width: `${Math.floor(w)}px`, height: `${Math.floor(h)}px`,
    maxWidth: 'none', maxHeight: 'none',
    objectFit: 'fill',      // 収めるのではなく引き伸ばす（この機能の目的そのもの）
  })
}

window.addEventListener('resize', () => layoutImageLayer())

// 画像面の地色。本文と同じ配色にして、切り替わりで白が差し込まないようにする。
function pageBackground() {
  const palettes = { light: '#ffffff', sepia: '#f4ecd8', dark: '#1c1c1e' }
  let t = State.style.theme
  if (t === 'auto') t = (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light'
  return palettes[t] || palettes.light
}

// 見開きの「2枚目」か（＝単独では出さず、1枚目とセットで出す面か）。
async function isSpreadSecondPage(index) {
  if (index <= 0 || !(await isImageSection(index))) return false
  const g = await spreadGroupOf(index)
  return g.first !== index
}

// 組の2枚目へ直接来たら1枚目へ跳ね返す（しおり・検索で飛んでも見開きで出る）。
// foliate はページ送りの最中 goTo を黙って捨てる（#locked）ので、着くまで少し粘る。
async function redirectIfSecondPage(index) {
  if (spreadRedirecting || index <= 0) return false
  if (!(await isSpreadSecondPage(index))) return false
  slog('-> redirect to', index - 1)
  spreadRedirecting = true
  try {
    for (let i = 0; i < 12; i++) {
      try { await State.view?.renderer?.goTo?.({ index: index - 1, anchor: 0 }) } catch (e) { /* 移動中 */ }
      if (State.index === index - 1) return true
      await new Promise(r => setTimeout(r, 60))
    }
    slog('redirect gave up at', index)
  } finally { spreadRedirecting = false }
  return true
}

// 画像面を組み直す。表示が落ち着いてから呼ぶこと——章の読み込み中に跳ね返し
// （renderer.goTo）を投げても、foliate が移動中なので黙って捨てられる。
async function applySpread(doc, index) {
  if (State.imagePage && State.imagePage.index === index) return   // 既に描いてある
  if (await redirectIfSecondPage(index)) return
  await showImagePage(index)
}

// 次のページへ。見開き中は、左ページとして出ている章を飛ばす。
function goNext() {
  if (!isFriendly()) return State.view?.next?.()
  const shown = State.imagePage?.partner
  slog('next', 'shown=' + shown)
  if (shown != null) return State.view?.renderer?.goTo?.({ index: shown + 1, anchor: 0 })
  return State.view?.next?.()
}
// 戻る。組の2枚目に着地したら、もう1つ戻って見開きの先頭に合わせる。
// （跳ね返しを goTo でやるとページ送りのロックに食われるので、prev をもう一度使う）
async function goPrev() {
  if (!isFriendly()) return State.view?.prev?.()
  slog('prev from', State.index)
  await State.view?.prev?.()
  if (await isSpreadSecondPage(State.index)) {
    slog('prev: landed on 2nd page ->', State.index - 1)
    await State.view?.prev?.()
  }
}

// ---- ページ内入力（ホイール・矢印キー・ダブルクリック）を iframe doc に配線 ----
let wheelLock = false
function wireDoc(doc) {
  if (!doc || doc.__bridgeWired) return
  doc.__bridgeWired = true
  if (isFriendly()) normalizeSVGImages(doc)
  // ホイール1ノッチ = 1ページ（連続発火はロックで抑制）。
  doc.addEventListener('wheel', e => {
    e.preventDefault()
    if (wheelLock) return
    const primary = Math.abs(e.deltaY) >= Math.abs(e.deltaX) ? e.deltaY : e.deltaX
    if (Math.abs(primary) < 4) return
    wheelLock = true
    setTimeout(() => { wheelLock = false }, 250)
    if (primary > 0) goNext(); else goPrev()
  }, { passive: false })
  // 矢印キー: 左右は書字方向対応(goLeft/goRight)、上下は進む/戻る。
  doc.addEventListener('keydown', e => {
    switch (e.key) {
      case 'ArrowLeft': State.view?.goLeft?.(); break
      case 'ArrowRight': State.view?.goRight?.(); break
      case 'ArrowDown': goNext(); break
      case 'ArrowUp': goPrev(); break
      // 読み上げの操作。開始・停止の判断は Swift 側が持っているので通知だけする。
      case ' ': case 'Spacebar': toSwift({ type: 'shortcut', action: 'playPause' }); break
      case 'Enter': case 'Escape': toSwift({ type: 'shortcut', action: 'stop' }); break
      default: return
    }
    e.preventDefault()
  })
  // ダブルクリック → その位置から読み上げ（Swift に通知。開始は Swift 主導）。
  doc.addEventListener('dblclick', () => {
    toSwift({ type: 'dblclick' })
  })
  // 選択状態を Swift へ通知（右クリックメニューの出し分け・辞書登録用）。
  // selectionchange はドラッグ中に連続発火するのでデバウンスする。
  let selTimer = null
  doc.addEventListener('selectionchange', () => {
    clearTimeout(selTimer)
    selTimer = setTimeout(() => {
      const sel = doc.getSelection?.()
      toSwift({ type: 'selection', text: sel ? String(sel).trim() : '' })
    }, 100)
  })
  // セクション切替直後は前ページの選択が残らないよう空でリセット。
  toSwift({ type: 'selection', text: '' })
}

// 現在表示中セクションの iframe contents（{doc, index, overlayer}）。
function currentContents() {
  return State.view?.renderer?.getContents?.()?.[0] ?? null
}

// 画像のみページか（列フィットなどの適用除外判定用）。
function detectImagePage(doc) {
  try {
    if (!doc?.body) return false
    const hasImage = !!doc.body.querySelector('img, svg, image')
    if (!hasImage) return false
    const text = (doc.body.textContent || '').replace(/[\s　]/g, '')
    return text.length <= TEXTLESS_MAX_CHARS
  } catch (e) { return false }
}

async function openBook(opts = {}) {
  try {
    // 書字方向は最初の組版より前に決まっている必要がある（applyStyles の呼び先を参照）。
    if (opts.writingMode === 'auto' || opts.writingMode === 'vertical' || opts.writingMode === 'horizontal')
      State.writingMode = opts.writingMode
    // 表示モードも最初の組版より前に決めておく（画像の寸法制約 CSS の有無が変わる）。
    if (opts.renderMode === 'raw' || opts.renderMode === 'friendly') renderMode = opts.renderMode
    // 表示の強制（綴じ方向・見開き・アスペクト比）も組版より前に。綴じ方向は最初の
    // relocate で左右タップの向きに使われるので、遅れると1ページぶん逆を向く。
    readDisplayOverrides(opts)
    const res = await fetch(BOOK_URL)
    if (!res.ok) throw new Error('book fetch failed: ' + res.status)
    const blob = await res.blob()
    const file = new File([blob], 'current.epub', { type: 'application/epub+zip' })

    // 書字方向を切り替えたときは同じ本を開き直す（下の reopen を参照）ので、
    // 前の view が残っていたら先に畳む。放置すると iframe が二重に生き続ける。
    if (State.view) {
      try { State.view.close?.() } catch (_) { /* 後始末の失敗は remove() で足りる */ }
      State.view.remove()
      State.view = null
    }
    const view = document.createElement('foliate-view')
    document.body.append(view)
    State.view = view
    hideImageLayer()
    sectionKind.clear()
    sectionRatio.clear()
    await view.open(file)

    view.addEventListener('relocate', e => {
      const d = e.detail || {}
      const doc = currentContents()?.doc
      // 見せ方の補正は friendly のときだけ。raw では EPUB の指定どおりに描かせる。
      if (isFriendly()) {
        fitImages(doc)   // render 後にここへ来るので、paginator の max-* 再設定に勝てる
        // 書字方向が確定した後でないと向きを判定できないので、load ではなくここで直す。
        fixHangingIndent(doc)
        // 画像面の描画・組み直しはここで。load の時点だと移動が弾かれる。
        if (detectImagePage(doc)) setTimeout(() => applySpread(doc, State.index), 0)
        else hideImageLayer()
      }
      // 向きは章ごとに変わる。ready の1回きりでは着地した章の性質に左右されるので、
      // 表示が落ち着くたびに取り直す（noteSectionDirection のコメントを参照）。
      const orient = noteSectionDirection(doc)
      // 本文の見開きは縦書きと横書きで効かせ方が違うので、章の向きが変わったら入れ直す。
      applyTextSpread(doc, { rerender: true })
      toSwift({
        type: 'relocate',
        fraction: d.fraction ?? 0,
        cfi: d.cfi ?? '',
        isImagePage: detectImagePage(doc),
        vertical: orient.vertical,
        dir: orient.dir,
        bookDir: State.bookDir,
        // 目次サイドバーで「いま読んでいる章」を示すため。
        tocHref: d.tocItem?.href ?? '',
      })
    })
    view.addEventListener('load', e => {
      const doc = e.detail?.doc
      const index = e.detail?.index ?? -1
      State.index = index
      wireDoc(doc)
      slog('load', 'idx=' + index, 'imageOnly=' + detectImagePage(doc))
      toSwift({ type: 'load', index })
    })
    // TTS/検索ハイライトの描画スタイル。
    view.addEventListener('draw-annotation', e => {
      const { draw, annotation } = e.detail
      if (annotation.isTTS) draw(Overlayer.highlight, { color: 'rgba(255, 235, 59, 0.5)' })
      else draw(Overlayer.highlight, { color: 'rgba(66, 133, 244, 0.4)' })
    })

    const book = view.book
    view.renderer?.setAttribute?.('flow', 'paginated')
    // 最初のセクションが読まれる前に書字方向を決めておく。paginator は iframe の
    // ロード直後に computed writing-mode を見て縦横を決め打ちするので、ここで入れた
    // CSS は初回の組版から効く（後から入れても既に組まれたページには効かない）。
    State.bookWritingHint = opfWritingHint(book)
    // 本を開き直すたびに本全体の向きも引き直す（前の本の値を持ち越さない）。
    // 強制モードと primary-writing-mode は本全体の宣言なのでここで確定。
    // ppd しか無い本は暫定にとどめ、本文を実測して確定させる（noteSectionDirection 参照）。
    const forcedRTL = State.writingMode === 'vertical'
      || (State.writingMode === 'auto' && State.bookWritingHint === 'vertical')
    const forcedLTR = State.writingMode === 'horizontal'
      || (State.writingMode === 'auto' && State.bookWritingHint === 'horizontal')
    // 読み手が綴じ方向を決めていればそれが最優先（noteSectionDirection も同じ扱いをする）。
    State.bookDirConfirmed = State.forcedBinding !== 'auto' || forcedRTL || forcedLTR
    State.bookDir = State.forcedBinding !== 'auto' ? State.forcedBinding
      : forcedRTL ? 'rtl'
      : forcedLTR ? 'ltr'
      : (opfPageDirection(book) === 'rtl' ? 'rtl' : 'ltr')
    State.detectedAspect = detectBookAspect(book)
    // 本を開き直したら、前の本で入れた見開きの状態は持ち越さない。
    // 実際の反映は最初の relocate（章の向きが分かった時点）で行う。
    appliedTextSpread = null
    applyStyles()

    if (opts.cfi) {
      try { await view.goTo(opts.cfi) } catch (_) { await view.renderer?.next?.() }
    } else if (typeof opts.fraction === 'number' && opts.fraction > 0) {
      try { await view.goToFraction(opts.fraction) } catch (_) { await view.renderer?.next?.() }
    } else {
      await view.renderer?.next?.()
    }

    const readyDoc = currentContents()?.doc
    // dir/vertical は「いま組まれている章」の向き。着地した章が前付けなら横組みで正しい
    // （本全体の向きは bookDir。以後 relocate ごとに取り直す）。
    const readyOrient = readyDoc
      ? noteSectionDirection(readyDoc)
      : { vertical: false, dir: State.bookDir }
    toSwift({
      type: 'ready',
      title: flatLang(book?.metadata?.title),
      author: flatContributor(book?.metadata?.author),
      // dir は「ページ送りの向き」。spine の page-progression-direction ではなく
      // 実際に組まれた本文から決める（pageDirection のコメントを参照）。
      dir: readyOrient.dir,
      vertical: readyOrient.vertical,
      bookDir: State.bookDir,
      writingMode: State.writingMode,
      bookWritingHint: State.bookWritingHint,
      fixedLayout: (book?.rendition?.layout === 'pre-paginated'),
      // 表示の強制は displayState() をそのまま載せる。Swift 側はここを見て状態を写すので、
      // 一部だけ載せると載せ忘れた項目が「指定なし」に見えて上書きされる（実際 aspect で踏んだ）。
      ...displayState(),
    })
    // OPF に判型が無い本は画像の実寸から拾い直し、取れたら追って知らせる。
    if (!State.detectedAspect) {
      fillAspectFromFirstImage().then(() => {
        if (State.detectedAspect) toSwift({ type: 'display', ...displayState() })
      })
    }
  } catch (e) {
    toSwift({ type: 'error', message: String(e && e.message ? e.message : e) })
  }
}

// 目次を Swift へ渡せる形に畳む。id は階層位置（"0.2.1"）。href は本の中に同じものが
// 複数現れうるので識別子には使わない。
function tocToJSON(items, prefix = '') {
  if (!Array.isArray(items)) return []
  return items.map((it, i) => {
    const id = prefix ? `${prefix}.${i}` : String(i)
    const label = typeof it?.label === 'string' ? it.label : flatLang(it?.label)
    return {
      id,
      label: (label || '').trim(),
      href: it?.href || '',
      subitems: tocToJSON(it?.subitems, id),
    }
  })
}

// 表紙の指定が無い本のための、spine 先頭からの拾い直し。
//
// foliate の getCover() が見るのは ①manifest の properties="cover-image"
// ②EPUB 2 の <meta name="cover"> ③guide の reference[type=cover] の3つだが、
// 漫画・写真集（OMF）はそのどれも持たないことがある——『レディ＆オールドマン 1』は
// 実際に3つとも無く、表紙の手がかりはファイル名の "_cover" だけだった。
// ただし spine の先頭が表紙であることはほぼ確実なので、そこから絵を取る。
// ファイル名に cover が入っているかで探すより確か（別の画像に当たりようがない）。
async function coverFromFirstSection(book) {
  try {
    const s = book?.sections?.[0]
    if (!s) return null
    const url = await s.load()
    if (!url) return null
    const item = book?.resources?.manifest?.find(i => i.href === s.id)
    // spine が画像を直接指す本（OMF）は、章のロード結果が絵そのもの。
    if ((item?.mediaType || '').toLowerCase().startsWith('image/')) {
      return await (await fetch(url)).blob()
    }
    // XHTML の表紙ページなら、その中の最初の絵を拾う（resource は blob URL に置換済み）。
    const html = await (await fetch(url)).text()
    const doc = new DOMParser().parseFromString(html, 'application/xhtml+xml')
    const src = imageSrcOf(doc)
    if (!src) return null
    return await (await fetch(src)).blob()
  } catch (e) {
    return null      // 表紙が無いのは致命ではない。メタデータだけで登録する。
  }
}

// ---- 書棚登録用: メタデータ＋表紙だけ取り出す（描画しない）----
async function probeBook() {
  try {
    const res = await fetch(BOOK_URL)
    if (!res.ok) throw new Error('book fetch failed: ' + res.status)
    const blob = await res.blob()
    const file = new File([blob], 'current.epub', { type: 'application/epub+zip' })
    // makeBook 相当は view.open が内包しているので、非表示 view で開いてメタデータだけ読む。
    const view = document.createElement('foliate-view')
    view.style.cssText = 'position:absolute;visibility:hidden;width:10px;height:10px;overflow:hidden'
    document.body.append(view)
    await view.open(file)
    const book = view.book
    const md = book?.metadata || {}
    let coverB64 = null
    try {
      const cover = (await book?.getCover?.()) || (await coverFromFirstSection(book))
      if (cover) {
        coverB64 = await new Promise((resolve, reject) => {
          const fr = new FileReader()
          fr.onload = () => resolve(String(fr.result).split(',')[1] || null)
          fr.onerror = reject
          fr.readAsDataURL(cover)
        })
      }
    } catch (_) {}
    const out = {
      type: 'probe',
      title: flatLang(md.title),
      author: flatContributor(md.author),
      authorSort: contributorSortAs(md.author),
      publisher: flatContributor(md.publisher),
      cover: coverB64,
    }
    // close() は「一度も描画していない view」で必ず落ちる（paginator.destroy が
    // ページ生成時にしか作られない内部 view を触るため）。probe は描画しないので毎回踏む。
    // ここで例外を外へ出すと、取得済みのメタデータごと catch に落ちて probe が失敗扱いになる。
    try { view.close?.() } catch (_) { /* 後始末の失敗は remove() で足りる */ }
    view.remove()
    toSwift(out)
  } catch (e) {
    toSwift({ type: 'probe', error: String(e && e.message ? e.message : e) })
  }
}

// ---- TTS（VOICEVOX は Swift 側。ここは文の列挙とハイライトだけ）----
// SSML 文字列を <mark name> で区切り、文リスト [{mark, text}] へ。
function ssmlToSentences(ssml) {
  if (!ssml) return null
  const doc = new DOMParser().parseFromString(ssml, 'application/xml')
  const root = doc.documentElement
  if (!root || root.nodeName === 'parsererror') return []
  const out = []
  let current = { mark: null, text: '' }
  const walk = node => {
    for (let c = node.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 3 || c.nodeType === 4) { current.text += c.textContent; continue }
      if (c.nodeType !== 1) continue
      if (c.localName === 'mark') {
        if (current.text.trim()) out.push({ mark: current.mark, text: current.text })
        current = { mark: c.getAttribute('name'), text: '' }
      } else if (c.localName === 'break') {
        current.text += '\n'
        walk(c)
      } else {
        walk(c)
      }
    }
  }
  walk(root)
  if (current.text.trim()) out.push({ mark: current.mark, text: current.text })
  // 空白だけの文を除去し、改行や連続空白を正規化。
  return out
    .map(s => ({ mark: s.mark, text: s.text.replace(/\s+/g, ' ').trim() }))
    .filter(s => s.text.length > 0)
}

async function ttsInit() {
  const view = State.view
  if (!view) return false
  // granularity='sentence' で mark が文単位に入る。highlight は annotation + スクロール。
  await view.initTTS('sentence', range => {
    try {
      const contents = currentContents()
      if (!contents) return
      const cfi = view.getCFI(contents.index, range)
      if (State.ttsHighlightCFI) {
        try { view.deleteAnnotation({ value: State.ttsHighlightCFI }) } catch (_) {}
      }
      State.ttsHighlightCFI = cfi
      view.addAnnotation({ value: cfi, isTTS: true })
      // 読み上げ位置が画面外なら自動送り（アニメなしで確実に）。
      view.renderer.scrollToAnchor?.(range)
    } catch (e) { /* ハイライト失敗は読み上げ継続 */ }
  })
  return !!view.tts
}

function ttsClearHighlight() {
  if (State.ttsHighlightCFI && State.view) {
    try { State.view.deleteAnnotation({ value: State.ttsHighlightCFI }) } catch (_) {}
    State.ttsHighlightCFI = null
  }
}

// ---- 対訳用の本文抽出 ----
// 翻訳の単位はブロック要素にする。文で切ると代名詞・主語が消えて訳が壊れ、
// セクション丸ごとだとローカル LLM には長すぎて待ち時間が読めなくなる。
const PASSAGE_SELECTOR =
  'p, h1, h2, h3, h4, h5, h6, li, blockquote, dd, dt, figcaption, td, th, pre'
const HEADING_TAGS = new Set(['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])
// 1画面ぶんの上限。ページに収まる段落はふつう10前後なので、これに掛かるのは
// 抽出がおかしいときだけ（＝暴走して LLM に何十本も投げるのを防ぐ保険）。
const PASSAGE_MAX = 40

/// いま画面に見えている段落を [{cfi, text, heading}] で返す。
function collectVisiblePassages() {
  const contents = currentContents()
  const doc = contents?.doc
  if (!doc?.body) return { passages: [], reason: 'no-content' }
  // 画像だけのページ（表紙・口絵）は訳す本文が無い。
  if (detectImagePage(doc)) return { passages: [], reason: 'image-page' }

  // lastLocation.range = 現在ページの可視範囲（TTS の visible モードと同じ根拠）。
  const range = State.view?.lastLocation?.range ?? null
  const out = []
  const seen = new Set()
  for (const el of doc.body.querySelectorAll(PASSAGE_SELECTOR)) {
    // 入れ子（li の中の p など）は内側だけ採る。両方採ると同じ文を二度訳すことになる。
    if (el.querySelector(PASSAGE_SELECTOR)) continue
    if (range) {
      try { if (!range.intersectsNode(el)) continue } catch (_) { /* 判定不能なら採る */ }
    }
    const text = (el.textContent || '').replace(/\s+/g, ' ').trim()
    if (!text) continue

    let cfi = ''
    try {
      const r = doc.createRange()
      r.selectNodeContents(el)
      cfi = State.view?.getCFI?.(contents.index, r) ?? ''
    } catch (_) { /* CFI が取れなくても訳は出せる */ }

    const key = cfi || 'i:' + out.length + ':' + text
    if (seen.has(key)) continue
    seen.add(key)

    out.push({ cfi, text, heading: HEADING_TAGS.has(el.localName) })
    if (out.length >= PASSAGE_MAX) break
  }
  return { passages: out, index: contents.index, hadRange: !!range }
}

// 表示の強制の現在値。Swift 側のツールバー表示を実際の状態と合わせるために返す。
function displayState() {
  return {
    binding: State.forcedBinding,
    bookDir: State.bookDir,
    imageSpread: State.imageSpread,
    textSpread: State.textSpread,
    aspect: State.forcedAspect,
    detectedAspect: State.detectedAspect,
  }
}

// Swift から呼ぶ API。値は JSON 文字列で返す（evaluateJavaScript の戻り値として受ける）。
window.__reader = {
  open: (json) => { openBook(json ? JSON.parse(json) : {}) },
  probe: () => { probeBook() },

  // 表示モードの切り替え（'friendly' / 'raw'）。
  // raw は EPUB の指定どおりに描かせるモードで、EPUB の粗を見るために使う。
  setRenderMode: (mode) => {
    const next = mode === 'raw' ? 'raw' : 'friendly'
    if (next !== renderMode) {
      renderMode = next
      const doc = currentContents()?.doc
      hideImageLayer()
      if (doc) {
        clearImageTweaks(doc)
        if (isFriendly()) normalizeSVGImages(doc); else restoreSVGImages(doc)
      }
      applyStyles()                       // 画像の寸法制約 CSS を出す／引っ込める
      State.view?.renderer?.render?.()    // paginator に寸法を計算し直させる
      if (isFriendly() && doc && detectImagePage(doc))
        setTimeout(() => applySpread(doc, State.index), 0)
    }
    return JSON.stringify({ renderMode })
  },
  renderMode: () => JSON.stringify({ renderMode }),

  next: () => goNext(),
  prev: () => goPrev(),

  // 見開きの組を1ページずらす（透明ページの入れ忘れなどで組が合わない本の救済）。
  toggleSpread: () => {
    spreadOffset = spreadOffset ? 0 : 1
    State.imagePage = null      // 組み直しを強制する
    ;(async () => {
      const doc = currentContents()?.doc
      if (doc && detectImagePage(doc)) await applySpread(doc, State.index)
    })()
    return JSON.stringify({ spreadOffset })
  },
  spreadState: () => JSON.stringify({
    log: spreadLog.slice(-24),
    spreadOffset,
    imagePage: State.imagePage ?? null,
    index: State.index,
  }),

  // 表示の強制（綴じ方向・見開き・アスペクト比）をまとめて差し替える。
  // 送られてきたキーだけを変える（readDisplayOverrides 参照）ので、
  // ツールバーの1項目だけを切り替えるときも他は現状のままになる。
  setDisplay: (json) => {
    const opts = json ? JSON.parse(json) : {}
    const beforeBinding = State.forcedBinding
    const beforeText = State.textSpread
    readDisplayOverrides(opts)

    // 綴じ方向は本全体の向きへ即座に反映する。次の relocate を待つと、切り替えた直後の
    // 1回だけ左右タップが逆を向く。
    if (State.forcedBinding !== 'auto') {
      State.bookDir = State.forcedBinding
      State.bookDirConfirmed = true
    } else if (beforeBinding !== 'auto') {
      // 自動へ戻した。OPF の暫定値まで巻き戻して、いま見えている面から測り直す。
      State.bookDirConfirmed = false
      State.bookDir = opfPageDirection(State.view?.book) === 'rtl' ? 'rtl' : 'ltr'
      const doc = currentContents()?.doc
      if (doc) noteSectionDirection(doc)
    }

    const doc = currentContents()?.doc
    if (State.textSpread !== beforeText) applyTextSpread(doc, { rerender: true })

    // 画像面は組み方・並び順・比率のどれが変わっても描き直す。
    hideImageLayer()                    // State.imagePage も落ちるので組み直しになる
    if (isFriendly() && doc && detectImagePage(doc)) {
      setTimeout(() => applySpread(doc, State.index), 0)
    } else if (isFriendly()) {
      fitImages(doc)                    // 本文中の挿絵にも比率の強制が効く
    }
    return JSON.stringify(displayState())
  },
  displayState: () => JSON.stringify(displayState()),
  goLeft: () => State.view?.goLeft?.(),
  goRight: () => State.view?.goRight?.(),
  goToFraction: (f) => State.view?.goToFraction?.(f),
  goTo: (target) => goToTarget(target),

  setStyle: (json) => {
    const s = json ? JSON.parse(json) : {}
    if (s.theme) State.style.theme = s.theme
    if (typeof s.fontScale === 'number') State.style.fontScale = s.fontScale
    if (typeof s.lineHeight === 'number') State.style.lineHeight = s.lineHeight
    if (typeof s.userCSS === 'string') State.userCSS = s.userCSS
    applyStyles()
  },

  // ---- 書字方向（自動 / 強制縦書き / 強制横書き）----
  // CSS を差し替えるだけでは既に組まれたページの縦横は変わらない
  //（paginator が iframe ロード時の computed writing-mode で決め打ちするため）。
  // 現在位置を CFI で保ったまま本を開き直して組み直す。
  // cfi は Swift 側が relocate で受けている最新位置。JS の lastLocation は
  // 画像面を自前描画しているページなどで欠けることがあるので、渡された方を優先する。
  setWritingMode: async (mode, cfi) => {
    const m = (mode === 'vertical' || mode === 'horizontal') ? mode : 'auto'
    if (m === State.writingMode) return JSON.stringify({ writingMode: m, reopened: false })
    const target = cfi || State.view?.lastLocation?.cfi || ''
    State.writingMode = m
    await openBook(target ? { cfi: target, writingMode: m } : { writingMode: m })
    return JSON.stringify({ writingMode: m, reopened: true, cfi: target })
  },

  // ---- 目次 ----
  // nav.xhtml / NCX のどちらから作られた toc でも同じ形で返す。
  getTOC: () => JSON.stringify(tocToJSON(State.view?.book?.toc)),

  // 選択範囲の CFI と選択文（右クリックの「しおりを追加」用）。
  // 選択が無い／CFI を作れないときは cfi:null を返す。呼び出し側は現在位置へ退避する。
  getSelectionCFI: () => {
    const view = State.view
    const contents = currentContents()
    const sel = contents?.doc?.getSelection?.()
    if (!view || !sel || !sel.rangeCount) return JSON.stringify({ cfi: null, text: '' })
    const text = String(sel).trim()
    if (!text) return JSON.stringify({ cfi: null, text: '' })
    let cfi = null
    try {
      cfi = view.getCFI(contents.index, sel.getRangeAt(0))
    } catch (e) {
      cfi = null
    }
    return JSON.stringify({ cfi, text })
  },

  // 現在の選択テキスト（辞書登録・選択位置からの読み上げ用）。
  getSelection: () => {
    const doc = currentContents()?.doc
    const sel = doc?.getSelection?.()
    return JSON.stringify({ text: sel ? String(sel).trim() : '' })
  },

  // ---- 検索 ----
  // 逐次 {type:'searchHit', cfi, excerpt} を Swift へ送り、終了で {type:'searchDone', count}。
  runSearch: async (query) => {
    const view = State.view
    if (!view) return
    if (State.searchAbort) State.searchAbort.aborted = true
    const abort = { aborted: false }
    State.searchAbort = abort
    let count = 0
    try {
      for await (const result of view.search({ query, matchCase: false, matchDiacritics: false, matchWholeWords: false })) {
        if (abort.aborted) return
        if (result === 'done') break
        if (result.subitems) {
          for (const { cfi, excerpt } of result.subitems) {
            count++
            // excerpt は {pre, match, post}（search.js の makeExcerpt）。
            toSwift({
              type: 'searchHit', cfi,
              pre: excerpt?.pre ?? '', match: excerpt?.match ?? '', post: excerpt?.post ?? '',
            })
            if (count >= 500) break
          }
        }
        if (count >= 500) break
      }
    } catch (e) {
      toSwift({ type: 'error', message: 'search: ' + String(e?.message || e) })
    }
    toSwift({ type: 'searchDone', count })
  },
  clearSearch: () => { State.view?.clearSearch?.() },

  // ---- TTS ----
  // 開始/再開/選択位置から。戻り値: 文リスト JSON（null は終端）。
  // 呼び出し側は callAsyncJavaScript（Promise を解決する）を使うこと。
  ttsStart: async (mode) => {
    const view = State.view
    if (!view) return JSON.stringify(null)
    const ok = await ttsInit()
    if (!ok) return JSON.stringify(null)
    let ssml = null
    if (mode === 'selection') {
      const doc = currentContents()?.doc
      const sel = doc?.getSelection?.()
      if (sel && sel.rangeCount > 0 && String(sel).trim()) {
        ssml = view.tts.from(sel.getRangeAt(0))
        sel.removeAllRanges()
      } else {
        ssml = view.tts.start()
      }
    } else if (mode === 'resume') {
      ssml = view.tts.resume()
    } else if (mode === 'visible') {
      // いま表示しているページ（可視範囲の先頭）から。lastLocation.range が現在の可視範囲。
      const range = view.lastLocation?.range
      ssml = range ? view.tts.from(range) : view.tts.start()
    } else {
      ssml = view.tts.start()
    }
    State.ttsBlocks = ssmlToSentences(ssml)
    return JSON.stringify(State.ttsBlocks)
  },
  // 次のブロック（段落）へ。null で本の終わり。
  ttsNextBlock: async () => {
    const view = State.view
    if (!view?.tts) return JSON.stringify(null)
    let ssml = view.tts.next()
    if (!ssml) {
      // 現セクションのブロックが尽きた → 次セクションへ進み TTS を初期化し直す。
      const moved = await view.next()
      // next() は表示更新後に resolve する（load イベントで doc 差し替え済み）。
      await ttsInit()
      ssml = view.tts?.start?.()
      if (!ssml) return JSON.stringify(null)
    }
    State.ttsBlocks = ssmlToSentences(ssml)
    return JSON.stringify(State.ttsBlocks)
  },
  // 文単位ハイライト（mark 名）。視覚フィードバック＋ページ自動送り。
  ttsMark: (name) => { State.view?.tts?.setMark?.(name) },
  ttsStop: () => { ttsClearHighlight() },

  // 現在のセクション（章）の全文を先頭から末尾まで文リストで収集する（音声ファイル保存用）。
  // tts.start()→tts.next() で SSML ブロックを列挙するだけ（setMark を呼ばないので
  // ハイライトも自動送りも起こさず、view.next() も呼ばないので表示ページは変わらない）。
  // 戻り値: 文テキストの配列 JSON（null は本なし/TTS初期化失敗）。
  ttsCollectSection: async () => {
    const view = State.view
    if (!view) return JSON.stringify(null)
    const ok = await ttsInit()
    if (!ok) return JSON.stringify(null)
    const out = []
    let ssml = view.tts.start()
    while (ssml) {
      const sents = ssmlToSentences(ssml)
      if (sents) for (const s of sents) out.push(s.text)
      ssml = view.tts.next()
    }
    ttsClearHighlight()
    return JSON.stringify(out)
  },

  // ---- 対訳（LM Studio 連携）----
  // いま画面に見えている範囲の本文を、翻訳に渡しやすい単位（ブロック要素）で列挙する。
  // 翻訳そのものは Swift 側でやる。WebView からローカルの LLM サーバへは CSP(connect-src)
  // でも CORS でも届かないため（VOICEVOX で実証済みの制約）。
  getVisiblePassages: () => JSON.stringify(collectVisiblePassages()),

  // ---- 測定・デバッグ ----
  // 本文 iframe の window で任意 JS を評価（測定オーバーレイ・実測用）。
  // win.eval なので `(function(){...})();` 形式の式がそのまま値を返す（旧 Readium evaluateJavaScript 互換）。
  evalInContent: (js) => {
    const contents = currentContents()
    if (!contents?.doc) return JSON.stringify('<no content>')
    try {
      const win = contents.doc.defaultView
      const out = win.eval(js)
      return JSON.stringify(out === undefined ? null : out)
    } catch (e) {
      return JSON.stringify('<error: ' + String(e?.message || e) + '>')
    }
  },
}

toSwift({ type: 'bridge-ready' })
