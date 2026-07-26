// UI 統合: テキスト → VOICEVOX → タイムライン → プレビュー → MP4 保存。
import { buildTimeline } from "./lib/voicevox.mjs";
import { visibleChars } from "./lib/verticalText.mjs";
import { computeLayout, drawFrame } from "./lib/render.mjs";
import { buildCombinedBuffer, createPlayer } from "./lib/audio.mjs";
import { makeVVClient, pickRecorderMime } from "./lib/vvClient.mjs";

const $ = (id) => document.getElementById(id);
const canvas = $("stage");
const ctx = canvas.getContext("2d");

const state = {
  vv: makeVVClient(),
  ac: null,
  timeline: null,
  buffer: null,
  layout: null,
  raf: null,
  player: null,
  recording: false,
};

function theme() {
  return {
    bg: $("bg").value,
    fg: $("fg").value,
    accent: $("accent").value,
    fontFamily: $("font").value,
  };
}
function size() {
  return { w: canvas.width, h: canvas.height };
}
function log(msg) {
  $("status").textContent = msg;
}

// --- 話者一覧 ---
async function loadSpeakers() {
  try {
    const v = await state.vv.version();
    if (!v) {
      log("VOICEVOX に接続できません（起動＆:50021 を確認）");
      return;
    }
    const speakers = await state.vv.listSpeakers();
    const sel = $("speaker");
    sel.innerHTML = "";
    for (const sp of speakers) {
      for (const st of sp.styles) {
        const opt = document.createElement("option");
        opt.value = st.id;
        opt.textContent = `${sp.name} / ${st.name} (${st.id})`;
        sel.appendChild(opt);
      }
    }
    // 既定: 四国めたん ノーマル(2) があれば選ぶ
    if ([...sel.options].some((o) => o.value === "2")) sel.value = "2";
    log(`VOICEVOX ${v} 接続OK・話者 ${sel.options.length} スタイル`);
  } catch (e) {
    log("話者取得失敗: " + e.message);
  }
}

function buildLayout() {
  const orientation = $("orientation").value;
  const fontSize = parseInt($("fontSize").value, 10);
  state.layout = computeLayout(state.timeline, {
    orientation,
    fontSize,
    viewW: canvas.width,
    viewH: canvas.height,
  });
}

// --- 生成 ---
async function generate() {
  const text = $("text").value.trim();
  if (!text) return log("テキストを入力してください");
  const speaker = parseInt($("speaker").value, 10);
  log("VOICEVOX で合成中…");
  $("generate").disabled = true;
  try {
    if (!state.ac) state.ac = new AudioContext();
    if (state.ac.state === "suspended") await state.ac.resume();

    state.timeline = await buildTimeline(text, {
      queryFetch: state.vv.queryFetch.bind(state.vv),
      synthFetch: state.vv.synthFetch.bind(state.vv),
      speaker,
      visibleChars,
      gap: parseFloat($("gap").value),
    });
    log("音声を結合中…");
    state.buffer = await buildCombinedBuffer(state.ac, state.timeline);
    buildLayout();

    // 静止プレビュー(先頭フレーム)
    drawFrame(ctx, state.layout, 0, theme(), size());
    $("preview").disabled = false;
    $("record").disabled = false;
    log(
      `準備OK: ${state.timeline.lines.length}行 / ${state.timeline.totalDuration.toFixed(1)}秒 / ${state.layout.glyphs.length}文字`
    );
  } catch (e) {
    log("生成失敗: " + e.message);
    console.error(e);
  } finally {
    $("generate").disabled = false;
  }
}

// --- プレビュー再生 ---
function stopLoop() {
  if (state.raf) cancelAnimationFrame(state.raf);
  state.raf = null;
  if (state.player) state.player.stop();
}

async function preview() {
  if (!state.buffer) return;
  stopLoop();
  if (state.ac.state === "suspended") await state.ac.resume();
  state.player = createPlayer(state.ac, state.buffer);
  state.player.start(true, 0);
  const end = state.timeline.totalDuration + 0.3;
  const loop = () => {
    const t = state.player.currentTime();
    drawFrame(ctx, state.layout, t, theme(), size());
    if (t >= end) {
      stopLoop();
      log("プレビュー終了");
      return;
    }
    state.raf = requestAnimationFrame(loop);
  };
  loop();
  log("プレビュー再生中…");
}

// --- 録画・保存 ---
async function record() {
  if (!state.buffer || state.recording) return;
  const mime = pickRecorderMime();
  if (!mime) return log("この環境は MediaRecorder 非対応です");
  stopLoop();
  if (state.ac.state === "suspended") await state.ac.resume();

  const fps = parseInt($("fps").value, 10);
  const videoStream = canvas.captureStream(fps);
  state.player = createPlayer(state.ac, state.buffer);
  const audioStream = state.player.streamDest.stream;
  const mixed = new MediaStream([
    ...videoStream.getVideoTracks(),
    ...audioStream.getAudioTracks(),
  ]);

  const chunks = [];
  const rec = new MediaRecorder(mixed, {
    mimeType: mime,
    videoBitsPerSecond: parseInt($("bitrate").value, 10) * 1_000_000,
  });
  rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  rec.onstop = () => {
    const blob = new Blob(chunks, { type: mime.split(";")[0] });
    const ext = mime.startsWith("video/mp4") ? "mp4" : "webm";
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `narration_${Date.now()}.${ext}`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    state.recording = false;
    $("record").disabled = false;
    $("generate").disabled = false;
    log(`保存しました（${(blob.size / 1e6).toFixed(1)}MB / ${ext.toUpperCase()}）`);
  };

  state.recording = true;
  $("record").disabled = true;
  $("generate").disabled = true;
  log(`録画中… (${mime.split(";")[0]})`);

  rec.start(100);
  state.player.start(false, 0); // 録画中はスピーカーに出さない（ハウリング防止）
  const end = state.timeline.totalDuration + 0.3;
  const loop = () => {
    const t = state.player.currentTime();
    drawFrame(ctx, state.layout, t, theme(), size());
    if (t >= end) {
      state.player.stop();
      if (state.raf) cancelAnimationFrame(state.raf);
      state.raf = null;
      rec.stop();
      return;
    }
    state.raf = requestAnimationFrame(loop);
  };
  loop();
}

// リアルタイムでテーマ/向き/サイズ変更を静止プレビューへ反映
function refreshStatic() {
  if (!state.timeline) return;
  buildLayout();
  drawFrame(ctx, state.layout, 0, theme(), size());
}

// --- 配線 ---
$("generate").addEventListener("click", generate);
$("preview").addEventListener("click", preview);
$("record").addEventListener("click", record);
$("stop").addEventListener("click", () => {
  stopLoop();
  log("停止");
});
["bg", "fg", "accent", "font", "orientation", "fontSize"].forEach((id) =>
  $(id).addEventListener("change", refreshStatic)
);

loadSpeakers();
