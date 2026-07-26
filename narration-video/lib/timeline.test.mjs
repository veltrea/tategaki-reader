// node --test 相当の簡易テスト。VOICEVOX 実機(50021)にも当てる。
import assert from "node:assert";
import {
  computeLineDuration,
  computeMoraTimings,
  assignCharTimings,
  buildTimeline,
  splitLines,
} from "./voicevox.mjs";
import { classifyChar, wrapColumns, visibleChars } from "./verticalText.mjs";

const BASE = "http://127.0.0.1:50021";
const SPEAKER = 2;

let pass = 0,
  fail = 0;
function t(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => {
      pass++;
      console.log("  ok  -", name);
    })
    .catch((e) => {
      fail++;
      console.log("FAIL  -", name, "\n       ", e.message);
    });
}

// ---- 縦書き分類（純ロジック） ----
await t("句読点は右上オフセット・非回転", () => {
  const c = classifyChar("、");
  assert.equal(c.kind, "punct");
  assert.equal(c.rotate, false);
  assert.ok(c.offset.dx > 0 && c.offset.dy < 0, "右上に寄る");
});
await t("長音ーは回転", () => {
  assert.equal(classifyChar("ー").rotate, true);
  assert.equal(classifyChar("（").rotate, true);
});
await t("小書き仮名は軽オフセット", () => {
  const c = classifyChar("っ");
  assert.equal(c.kind, "small");
  assert.ok(c.offset.dy < 0);
});
await t("通常文字はオフセット無し", () => {
  const c = classifyChar("星");
  assert.deepEqual(c.offset, { dx: 0, dy: 0 });
  assert.equal(c.rotate, false);
});
await t("行頭禁則: 列頭の。は前列にぶら下がる", () => {
  const cols = wrapColumns(visibleChars("あいう。えお"), 3);
  // rows=3 → ["あ","い","う"] 次列頭が "。" なので前列へ → 前列4文字
  assert.equal(cols[0].map((x) => x.ch).join(""), "あいう。");
  assert.equal(cols[1].map((x) => x.ch).join(""), "えお");
});

// ---- タイムライン数理（純ロジック・モック） ----
await t("computeLineDuration は pre/post/mora を積算", () => {
  const q = {
    speedScale: 1,
    prePhonemeLength: 0.1,
    postPhonemeLength: 0.1,
    accent_phrases: [
      { moras: [{ consonant_length: 0.05, vowel_length: 0.08 }, { vowel_length: 0.1 }], pause_mora: null },
    ],
  };
  assert.ok(Math.abs(computeLineDuration(q) - (0.1 + 0.05 + 0.08 + 0.1 + 0.1)) < 1e-9);
});
await t("assignCharTimings は文字を単調増加で割り当て", () => {
  const q = {
    speedScale: 1,
    prePhonemeLength: 0.1,
    postPhonemeLength: 0.1,
    accent_phrases: [{ moras: [{ vowel_length: 0.3 }, { vowel_length: 0.3 }], pause_mora: null }],
  };
  const ct = assignCharTimings(["あ", "い", "う"], q);
  assert.equal(ct.length, 3);
  assert.ok(ct[0].start < ct[1].start && ct[1].start < ct[2].start);
  assert.ok(ct[0].start >= 0.099); // prePhoneme 後から
});
await t("splitLines は空行を保持", () => {
  assert.deepEqual(splitLines("a\n\nb"), ["a", "", "b"]);
});

// ---- VOICEVOX 実機結合 ----
async function reachable() {
  try {
    const r = await fetch(`${BASE}/version`, { signal: AbortSignal.timeout(2000) });
    return r.ok;
  } catch {
    return false;
  }
}

if (await reachable()) {
  const queryFetch = async (line, speaker) => {
    const r = await fetch(
      `${BASE}/audio_query?text=${encodeURIComponent(line)}&speaker=${speaker}`,
      { method: "POST" }
    );
    if (!r.ok) throw new Error("audio_query " + r.status);
    return r.json();
  };
  const synthFetch = async (query, speaker) => {
    const r = await fetch(`${BASE}/synthesis?speaker=${speaker}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(query),
    });
    if (!r.ok) throw new Error("synthesis " + r.status);
    return new Uint8Array(await r.arrayBuffer());
  };

  await t("実機: buildTimeline が行時刻とWAVを返す", async () => {
    const tl = await buildTimeline("これは見本の一行目です。\n二行目はここから始まります。", {
      queryFetch,
      synthFetch,
      speaker: SPEAKER,
      visibleChars,
    });
    assert.equal(tl.lines.length, 2);
    assert.ok(tl.lines[0].duration > 0.3, "1行目に尺がある");
    assert.ok(tl.lines[1].start >= tl.lines[0].end, "行が時系列で並ぶ");
    assert.ok(tl.lines[0].wav && tl.lines[0].wav.length > 44, "WAVヘッダ以上のバイト");
    // WAV マジック "RIFF"
    const w = tl.lines[0].wav;
    assert.equal(String.fromCharCode(w[0], w[1], w[2], w[3]), "RIFF");
    assert.ok(tl.totalDuration > tl.lines[1].end - 0.001);
    console.log(
      `        line0 dur=${tl.lines[0].duration.toFixed(2)}s chars=${tl.lines[0].chars.length} total=${tl.totalDuration.toFixed(2)}s`
    );
  });
} else {
  console.log("  skip- VOICEVOX 未到達のため実機結合テストをスキップ");
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
