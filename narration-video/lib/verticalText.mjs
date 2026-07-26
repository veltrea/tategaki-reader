// 縦書きレイアウト＋句読点処理（純ロジック / canvas 非依存）
//
// canvas には縦書き組版機能が無いため、1 文字ずつ「セル(em 正方形)」に配置する。
// 句読点・長音・括弧・小書き仮名は縦書きで見た目が崩れるので、
// 文字種を分類して「回転」「セル内オフセット」フラグを返す。canvas 側はそれを適用するだけ。
//
// オフセットは em(=fontSize) を 1.0 とした相対値。セル中心を原点(0,0)とし、
// x+ は右、y+ は下。

// 縦書きで右上に寄せる約物（句読点・読点）。全角/半角の両方を含める。
const TOP_RIGHT = new Set(["、", "。", "，", "．", "､", "｡", ",", "."]);

// 縦書きで 90°回転させる文字（長音・ダッシュ・波・各種括弧）。
const ROTATE = new Set([
  "ー", "―", "‐", "‑", "‒", "–", "—", "―", "ｰ", "-", "−",
  "～", "〜", "~",
  "（", "）", "(", ")",
  "「", "」", "『", "』",
  "【", "】", "〔", "〕", "［", "］", "｛", "｝", "〈", "〉", "《", "》",
  "…", "‥", // 三点リーダは縦中央に置いて回転
  "＝", "=",
]);

// 縦書きで右上に少しずらす小書き仮名・促音。
const SMALL_KANA = new Set([
  "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ",
  "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ",
]);

// 行頭(縦書きでは各列の先頭)に置いてはいけない約物（禁則: 行頭禁則）。
const NO_LINE_START = new Set([
  "、", "。", "，", "．", "、", "」", "』", "）", ")", "】", "〕", "］", "｝",
  "〉", "》", "！", "？", "!", "?", "ー", "…", "‥", "・", "ゝ", "ゞ",
  "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "っ", "ゃ", "ゅ", "ょ",
  "ァ", "ィ", "ゥ", "ェ", "ォ", "ッ", "ャ", "ュ", "ョ",
]);

/**
 * 1 文字を分類し、縦書き描画用の情報を返す。
 * @returns {{ ch, rotate:boolean, offset:{dx,dy}, kind:string }}
 */
export function classifyChar(ch) {
  if (TOP_RIGHT.has(ch)) {
    // 句読点: セル右上へ寄せる。回転はしない（正立のまま）。
    return { ch, rotate: false, offset: { dx: 0.28, dy: -0.34 }, kind: "punct" };
  }
  if (SMALL_KANA.has(ch)) {
    return { ch, rotate: false, offset: { dx: 0.12, dy: -0.12 }, kind: "small" };
  }
  if (ROTATE.has(ch)) {
    return { ch, rotate: true, offset: { dx: 0, dy: 0 }, kind: "rotate" };
  }
  return { ch, rotate: false, offset: { dx: 0, dy: 0 }, kind: "normal" };
}

/**
 * 可視文字列を返す（縦書きで 1 セルを占める単位）。
 * サロゲートペア(絵文字等)を 1 文字として扱う。
 */
export function visibleChars(line) {
  return Array.from(line);
}

/**
 * 文字配列を縦書きの「列(column)」に折り返す。
 *  - 1 列に rowsPerColumn 文字まで。
 *  - 行頭禁則: 列の先頭に約物が来る場合、前列末尾へぶら下げる（1 文字だけ簡易対応）。
 *
 * @param {string[]} chars
 * @param {number} rowsPerColumn
 * @returns {Array<Array<{ch,rotate,offset,kind}>>}  列の配列。各列は分類済み文字の配列。
 */
export function wrapColumns(chars, rowsPerColumn) {
  const cls = chars.map(classifyChar);
  const columns = [];
  let col = [];
  for (let i = 0; i < cls.length; i++) {
    if (col.length >= rowsPerColumn) {
      // 次の文字が行頭禁則なら現在列に 1 文字だけ余分に許容してぶら下げる。
      columns.push(col);
      col = [];
    }
    if (col.length === 0 && columns.length > 0 && NO_LINE_START.has(cls[i].ch)) {
      // 列頭に禁則約物 → 直前列の末尾へ付ける。
      columns[columns.length - 1].push(cls[i]);
      continue;
    }
    col.push(cls[i]);
  }
  if (col.length) columns.push(col);
  return columns;
}
