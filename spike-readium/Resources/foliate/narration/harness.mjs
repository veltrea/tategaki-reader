// セクション動画レンダラのヘッドレス描画エンジン（Swift の VideoNarrationRenderer から駆動）。
//
// 役割分担（重要）:
//   - VOICEVOX 通信は Swift(URLSession) が担当（foliate:// origin はブラウザ fetch だと CORS/ATS で弾かれる）。
//   - 音声(WAV)は Swift が持ち、各行を lineStarts に配置して結合する（webview へ音声を往復させない）。
//   - 動画エンコードは Swift(AVAssetWriter) が担当（素の WKWebView は MediaRecorder / canvas.captureStream を持たない）。
//   - この harness は「Canvas 2D 描画」だけを担当する。Swift がフレーム時刻 t を指定して 1 枚ずつ絵を取り出す。
//
// narration-video の純ロジック(lib/*.mjs)を再利用して、縦書きグロー（カラオケ字幕風）を描く。
//
// API（Swift は callAsyncJavaScript で呼ぶ）:
//   window.__narr.prepare(payload) -> Promise<JSON文字列>
//       payload = { lines:[{text, query}], orientation, fontSize, width, height, bg, fg, accent, fontFamily }
//       戻り = { ok, totalDuration, lineStarts:[秒...] }  // 各行の開始秒。Swift はこの位置に音声を置いて mux
//   window.__narr.frame(t) -> string   // 時刻 t(秒) の 1 フレームを JPEG data URL で返す
//   window.__narr.abort()              // 破棄
//
// メッセージ（webkit.messageHandlers.narration）は準備完了通知にのみ使う:
//   { type: "narr-ready" }  ロード完了。Swift は prepare を呼ぶ

import { computeLineDuration, assignCharTimings } from "./lib/voicevox.mjs";
import { visibleChars } from "./lib/verticalText.mjs";
import { computeLayout, drawFrame } from "./lib/render.mjs";

const canvas = document.getElementById("stage");
const ctx = canvas.getContext("2d");

function post(msg) {
  try {
    window.webkit.messageHandlers.narration.postMessage(msg);
  } catch (e) {
    console.log("[narration]", JSON.stringify(msg).slice(0, 200));
  }
}

const state = {
  layout: null,
  theme: null,
  size: null,
  aborted: false,
};

/// 行間無音（gap）。Swift の音声配置と一致させる必要があるので定数で共有する。
const GAP = 0.15;

// Swift 提供の [{text, query}] から buildTimeline 相当のタイムラインを組む（fetch も音声も持たない）。
// 各行の開始・尺・文字掃引だけを算出する。開始秒(cursor)は Swift の音声配置と一致させる。
function buildTimelineFromData(lines, gap) {
  let cursor = 0;
  const out = [];
  for (const L of lines) {
    const query = typeof L.query === "string" ? JSON.parse(L.query) : L.query;
    const duration = computeLineDuration(query);
    const chars = visibleChars(L.text || "");
    const rel = assignCharTimings(chars, query);
    const absChars = rel.map((c) => ({
      ch: c.ch,
      start: cursor + c.start,
      end: cursor + c.end,
    }));
    out.push({
      index: out.length,
      text: L.text || "",
      start: cursor,
      end: cursor + duration,
      duration,
      chars: absChars,
    });
    cursor += duration + gap;
  }
  return { lines: out, totalDuration: cursor };
}

// タイムライン + レイアウトを構築し、各行の開始秒と総尺を Swift に返す（音声は Swift 側で配置）。
function prepare(payload) {
  try {
    state.aborted = false;
    const p = typeof payload === "string" ? JSON.parse(payload) : payload;
    canvas.width = p.width || 720;
    canvas.height = p.height || 1280;
    state.size = { w: canvas.width, h: canvas.height };
    state.theme = {
      bg: p.bg || "#0a0a0f",
      fg: p.fg || "#f5f5f5",
      accent: p.accent || "#00d0ff",
      fontFamily: p.fontFamily || "serif",
    };

    const srcLines = Array.isArray(p.lines) ? p.lines : [];
    if (!srcLines.length) return JSON.stringify({ ok: false, error: "合成データがありません" });

    const timeline = buildTimelineFromData(srcLines, GAP);
    if (!timeline.lines.length) {
      return JSON.stringify({ ok: false, error: "合成結果が空です" });
    }

    // レイアウト（列組み・グリフ配置）。以降 frame(t) で使い回す。
    state.layout = computeLayout(timeline, {
      orientation: p.orientation || "vertical",
      fontSize: p.fontSize || 48,
      viewW: canvas.width,
      viewH: canvas.height,
    });

    // 先頭フレームを一度描いておく（フォント確定・初期化）。
    drawFrame(ctx, state.layout, 0, state.theme, state.size);

    return JSON.stringify({
      ok: true,
      totalDuration: timeline.totalDuration,
      lineStarts: timeline.lines.map((l) => l.start),
    });
  } catch (e) {
    return JSON.stringify({ ok: false, error: (e && e.message) || String(e) });
  }
}

// 時刻 t(秒) のフレームを描いて JPEG data URL で返す。Swift が fps ぶん繰り返し呼ぶ。
function frame(t) {
  if (!state.layout) return "";
  drawFrame(ctx, state.layout, t, state.theme, state.size);
  return canvas.toDataURL("image/jpeg", 0.92);
}

function abort() {
  state.aborted = true;
  state.layout = null;
}

window.__narr = { prepare, frame, abort };
post({ type: "narr-ready" });
