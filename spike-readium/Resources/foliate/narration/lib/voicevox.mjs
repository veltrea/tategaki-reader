// VOICEVOX タイムライン生成（純ロジック / 依存性注入）
//
// 設計方針:
//  - 外部依存(HTTP)はすべて引数で受け取り、node からモックでテストできるようにする。
//  - audio_query が返すモーラ(consonant_length + vowel_length)を積算し、
//    行ごとの正確な発話時間と、行内の各文字の読み上げ位置(sweep)を算出する。
//  - 原文(漢字混じり)とモーラ(カナ読み)は 1:1 対応しないため、
//    「行の総時間を可視文字数で線形に割る」sweep を基本とする。カラオケ字幕の王道。

/** テキストを行に分割。空行はポーズ(無音行)として保持する。 */
export function splitLines(text) {
  return text
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((s) => s.replace(/\s+$/g, "")); // 行末空白のみ除去。空行は残す(=ポーズ)。
}

/** 1 モーラの尺(秒)。consonant は無い場合がある。 */
function moraSeconds(m) {
  const c = typeof m.consonant_length === "number" ? m.consonant_length : 0;
  const v = typeof m.vowel_length === "number" ? m.vowel_length : 0;
  return c + v;
}

/**
 * audio_query の JSON から、その行の発話尺(秒)を算出する。
 * 実際に synthesis される WAV の長さと一致するように pre/post/pause を含める。
 */
export function computeLineDuration(query) {
  const speed = query.speedScale || 1;
  let sum = (query.prePhonemeLength || 0) + (query.postPhonemeLength || 0);
  const pauseScale = query.pauseLengthScale || 1;
  for (const ap of query.accent_phrases || []) {
    for (const m of ap.moras || []) sum += moraSeconds(m);
    if (ap.pause_mora) sum += moraSeconds(ap.pause_mora) * pauseScale;
  }
  return sum / speed;
}

/**
 * 行内の各モーラの [start,end]（行頭=0 基準・秒）を返す。
 * prePhonemeLength ぶん先頭に無音があるのでそこから積む。
 */
export function computeMoraTimings(query) {
  const speed = query.speedScale || 1;
  const pauseScale = query.pauseLengthScale || 1;
  let t = (query.prePhonemeLength || 0) / speed;
  const out = [];
  for (const ap of query.accent_phrases || []) {
    for (const m of ap.moras || []) {
      const dur = moraSeconds(m) / speed;
      out.push({ text: m.text, start: t, end: t + dur });
      t += dur;
    }
    if (ap.pause_mora) t += (moraSeconds(ap.pause_mora) * pauseScale) / speed;
  }
  return out;
}

/**
 * 行内の可視文字それぞれに読み上げ時刻 [start,end]（行頭基準・秒）を割り当てる。
 * 原文とモーラは一致しないので、モーラ全体の時間区間 [firstMoraStart, lastMoraEnd] を
 * 可視文字数で線形に分割する（カラオケ的 sweep）。
 * @param chars 可視文字の配列（レイアウト後の文字。改行等は含めない）
 */
export function assignCharTimings(chars, query) {
  const moras = computeMoraTimings(query);
  const speech0 = moras.length ? moras[0].start : (query.prePhonemeLength || 0);
  const speech1 = moras.length
    ? moras[moras.length - 1].end
    : computeLineDuration(query);
  const span = Math.max(1e-3, speech1 - speech0);
  const n = Math.max(1, chars.length);
  return chars.map((ch, i) => ({
    ch,
    start: speech0 + (span * i) / n,
    end: speech0 + (span * (i + 1)) / n,
  }));
}

/**
 * テキスト全体のタイムラインと音声を構築する。
 *
 * @param {string} text 朗読テキスト（改行で行分割）
 * @param {object} deps
 *   - queryFetch(line, speaker) => Promise<audioQueryJson>
 *   - synthFetch(query, speaker) => Promise<Uint8Array>  // WAV バイト
 *   - speaker: number
 *   - gap: number  行間に挿入する無音秒(既定 0.15)
 *   - visibleChars(line) => string[]  行から可視文字配列を得る（縦書きレイアウトと共有）
 * @returns {Promise<{lines, totalDuration, speaker}>}
 *   lines: [{ index, text, start, end, duration, chars:[{ch,start,end(絶対秒)}], wav:Uint8Array }]
 */
export async function buildTimeline(text, deps) {
  const {
    queryFetch,
    synthFetch,
    speaker,
    gap = 0.15,
    visibleChars = (line) => Array.from(line),
  } = deps;

  const rawLines = splitLines(text);
  const lines = [];
  let cursor = 0;

  for (let i = 0; i < rawLines.length; i++) {
    const line = rawLines[i];
    if (line.trim() === "") {
      // 空行 = ポーズ。音声は出さず時間だけ進める。
      const pause = 0.5;
      lines.push({
        index: i,
        text: "",
        start: cursor,
        end: cursor + pause,
        duration: pause,
        chars: [],
        wav: null,
      });
      cursor += pause;
      continue;
    }

    const query = await queryFetch(line, speaker);
    const duration = computeLineDuration(query);
    const wav = await synthFetch(query, speaker);

    const chars = visibleChars(line);
    const rel = assignCharTimings(chars, query);
    const absChars = rel.map((c) => ({
      ch: c.ch,
      start: cursor + c.start,
      end: cursor + c.end,
    }));

    lines.push({
      index: i,
      text: line,
      start: cursor,
      end: cursor + duration,
      duration,
      chars: absChars,
      wav,
    });
    cursor += duration + gap;
  }

  return { lines, totalDuration: cursor, speaker };
}
