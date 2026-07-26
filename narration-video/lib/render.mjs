// Canvas レンダラ（縦書き/横書き 両対応・発光スポットライト・スクロール）
//
// - computeLayout: タイムラインから全グリフのワールド座標を 1 度だけ算出（フレーム毎の再計算を避ける）。
// - readingHead: 時刻 t → 連続的な「読み位置」インデックス。
// - drawFrame: 読み位置を中心にスクロールし、スポットライト状に発光＋減光して描画。
//
// verticalText.mjs の分類(rotate/offset)と voicevox.mjs の char 時刻を突き合わせる。
// 両者とも visibleChars(line) 由来で順序が一致している前提。

import { wrapColumns, visibleChars } from "./verticalText.mjs";

/**
 * @param {object} timeline buildTimeline の戻り
 * @param {object} opts
 *   orientation: 'vertical' | 'horizontal'
 *   fontSize: px
 *   cellRatio: セル送り(行送り)= fontSize * cellRatio  (既定 1.5)
 *   colRatio: 列送り(縦書き)/ 行間(横書き)= fontSize * colRatio (既定 1.9)
 *   viewH / viewW: キャンバス論理サイズ
 *   marginRatio: 端マージン(fontSize 倍)
 *   lineGapCols: 行(文)間に空ける列/行の割合
 */
export function computeLayout(timeline, opts) {
  const {
    orientation = "vertical",
    fontSize = 48,
    cellRatio = 1.02,
    colRatio = 1.9,
    viewH = 1080,
    viewW = 1920,
    marginRatio = 1.2,
    lineGapCols = 0.6,
  } = opts;

  const cell = fontSize * cellRatio; // 文字送り
  const colW = fontSize * colRatio; // 列送り(縦) / 行送り(横)
  const margin = fontSize * marginRatio;
  const glyphs = [];

  if (orientation === "vertical") {
    // 縦書き: 列は右→左。文字は上→下。
    const rowsPerColumn = Math.max(1, Math.floor((viewH - 2 * margin) / cell));
    let globalCol = 0;
    for (const line of timeline.lines) {
      if (!line.chars.length) {
        globalCol += 1 + lineGapCols; // 空行 = 1 列ぶんの余白
        continue;
      }
      const cols = wrapColumns(
        line.chars.map((c) => c.ch),
        rowsPerColumn
      );
      // line.chars と columns を読み順で対応付ける
      let ci = 0;
      for (const col of cols) {
        const colX = globalCol * colW; // ワールド座標(左に進むほど大)。描画時に反転。
        for (let r = 0; r < col.length; r++) {
          const g = col[r];
          const timing = line.chars[ci] || { start: line.start, end: line.end };
          glyphs.push({
            gi: glyphs.length,
            ch: g.ch,
            rotate: g.rotate,
            offset: g.offset,
            colX, // 論理列位置(0,1,2,...)を colW 倍したもの
            rowY: margin + r * cell + cell / 2,
            start: timing.start,
            end: timing.end,
          });
          ci++;
        }
        globalCol++;
      }
      globalCol += lineGapCols;
    }
    const worldW = Math.max(colW, globalCol * colW);
    return { glyphs, orientation, cell, colW, fontSize, margin, worldW, worldH: viewH, rowsPerColumn };
  } else {
    // 横書き: 行は上→下。文字は左→右。
    const colsPerRow = Math.max(1, Math.floor((viewW - 2 * margin) / cell));
    let globalRow = 0;
    for (const line of timeline.lines) {
      if (!line.chars.length) {
        globalRow += 1 + lineGapCols;
        continue;
      }
      // 横書きは回転/約物処理不要（通常のまま）。折り返しのみ。
      const chars = line.chars.map((c) => c.ch);
      let ci = 0;
      for (let start = 0; start < chars.length; start += colsPerRow) {
        const rowChars = chars.slice(start, start + colsPerRow);
        const rowY = globalRow * colW;
        for (let k = 0; k < rowChars.length; k++) {
          const timing = line.chars[ci] || { start: line.start, end: line.end };
          glyphs.push({
            gi: glyphs.length,
            ch: rowChars[k],
            rotate: false,
            offset: { dx: 0, dy: 0 },
            colX: margin + k * cell + cell / 2, // x 実座標
            rowY, // 論理行位置 * colW
            start: timing.start,
            end: timing.end,
          });
          ci++;
        }
        globalRow++;
      }
      globalRow += lineGapCols;
    }
    const worldH = Math.max(colW, globalRow * colW);
    return { glyphs, orientation, cell, colW, fontSize, margin, worldW: viewW, worldH, colsPerRow };
  }
}

/**
 * 時刻 t → 連続的な読み位置 H（グリフ index の実数）。
 * ギャップ中はグリフ間を線形補間して滑らかに移動させる。
 * @returns {number} 0..glyphs.length-1（未開始なら -1 相当は呼び出し側で扱う）
 */
export function readingHead(glyphs, t) {
  if (!glyphs.length) return 0;
  if (t <= glyphs[0].start) return 0;
  const last = glyphs[glyphs.length - 1];
  if (t >= last.end) return glyphs.length - 1;
  for (let i = 0; i < glyphs.length; i++) {
    const g = glyphs[i];
    if (t >= g.start && t <= g.end) {
      const f = (t - g.start) / Math.max(1e-4, g.end - g.start);
      return i + f;
    }
    // ギャップ: g.end < t < next.start
    const next = glyphs[i + 1];
    if (next && t > g.end && t < next.start) {
      const f = (t - g.end) / Math.max(1e-4, next.start - g.end);
      return i + f;
    }
  }
  return glyphs.length - 1;
}

/** ワールド座標での読み位置(スクロール基準点)を返す。 */
function headWorldPos(layout, H) {
  const { glyphs, orientation, colW } = layout;
  const i = Math.max(0, Math.min(glyphs.length - 1, Math.floor(H)));
  const g = glyphs[i];
  if (orientation === "vertical") {
    return { x: g.colX + colW / 2 };
  }
  return { y: g.rowY + colW / 2 };
}

/**
 * 1 フレーム描画。
 * @param ctx CanvasRenderingContext2D
 * @param layout computeLayout の戻り
 * @param t 秒
 * @param theme { bg, fg, accent, fontFamily }
 * @param size { w, h }（キャンバス論理サイズ）
 * @param cfg { baseOpacity, sigma, maxBlur, headTargetRatio }
 */
export function drawFrame(ctx, layout, t, theme, size, cfg = {}) {
  const {
    baseOpacity = 0.26,
    sigma = 1.9,
    maxBlur = 22,
    headTargetRatio = 0.6,
  } = cfg;
  const { glyphs, orientation, fontSize, colW } = layout;

  // 背景（テーマ色）
  ctx.save();
  ctx.fillStyle = theme.bg;
  ctx.fillRect(0, 0, size.w, size.h);
  ctx.restore();

  if (!glyphs.length) return;

  const H = readingHead(glyphs, t);
  const started = t >= glyphs[0].start;

  // スクロール量: 読み位置を画面の headTargetRatio 位置へ。
  let scrollX = 0,
    scrollY = 0;
  if (orientation === "vertical") {
    const hp = headWorldPos(layout, H);
    // ワールドは「右に進むほど colX 大」。画面では右→左に流すため x を反転配置。
    // 画面 x = size.w - (colX - scroll)。head を size.w*headTargetRatio に置く。
    scrollX = hp.x - size.w * (1 - headTargetRatio);
  } else {
    const hp = headWorldPos(layout, H);
    scrollY = hp.y - size.h * headTargetRatio;
  }

  ctx.save();
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.font = `${fontSize}px ${theme.fontFamily}`;

  for (const g of glyphs) {
    // 画面座標
    let sx, sy;
    if (orientation === "vertical") {
      sx = size.w - (g.colX - scrollX);
      sy = g.rowY;
    } else {
      sx = g.colX;
      sy = g.rowY - scrollY + fontSize; // 行位置ベース
    }
    // 画面外は間引き
    if (sx < -colW || sx > size.w + colW || sy < -colW || sy > size.h + colW) continue;

    // 発光強度: 読み位置からの距離(グリフ数)でガウス減衰
    const d = g.gi - H;
    const intensity = started ? Math.exp(-(d * d) / (2 * sigma * sigma)) : 0;
    const readPast = g.gi < H ? 1 : 0; // 既読

    const opacity = baseOpacity + (1 - baseOpacity) * Math.max(intensity, readPast * 0.18);

    ctx.save();
    ctx.globalAlpha = Math.min(1, opacity);
    // 色: 発光部はアクセント、それ以外は前景色
    const lit = intensity > 0.15;
    ctx.fillStyle = lit ? theme.accent : theme.fg;
    if (intensity > 0.04) {
      ctx.shadowColor = theme.accent;
      ctx.shadowBlur = maxBlur * intensity;
    }

    ctx.translate(sx, sy);
    if (g.rotate) ctx.rotate(Math.PI / 2);
    const dx = (g.offset?.dx || 0) * fontSize;
    const dy = (g.offset?.dy || 0) * fontSize;
    ctx.fillText(g.ch, dx, dy);
    ctx.restore();
  }

  ctx.restore();
}
