// 音声: 行ごとの WAV を 1 本の AudioBuffer に結合し、再生/録画へ供給する。
// ブラウザ専用（AudioContext を使う）。

/**
 * 行ごとの WAV(Uint8Array) を、タイムラインの line.start 位置に配置した
 * 単一 AudioBuffer に結合する。
 * @param {AudioContext} ac
 * @param {object} timeline buildTimeline の戻り（lines[].start, lines[].wav）
 * @returns {Promise<AudioBuffer>}
 */
export async function buildCombinedBuffer(ac, timeline) {
  const decoded = [];
  for (const line of timeline.lines) {
    if (!line.wav) {
      decoded.push(null);
      continue;
    }
    // decodeAudioData は ArrayBuffer を消費するのでコピーを渡す
    const buf = line.wav.buffer.slice(
      line.wav.byteOffset,
      line.wav.byteOffset + line.wav.byteLength
    );
    // eslint-disable-next-line no-await-in-loop
    const ab = await ac.decodeAudioData(buf);
    decoded.push(ab);
  }

  const sr = ac.sampleRate;
  const totalLen = Math.ceil((timeline.totalDuration + 0.4) * sr);
  const out = ac.createBuffer(1, totalLen, sr);
  const outData = out.getChannelData(0);

  timeline.lines.forEach((line, i) => {
    const ab = decoded[i];
    if (!ab) return;
    const offset = Math.floor(line.start * sr);
    // 元がステレオでもモノにまとめる
    const ch0 = ab.getChannelData(0);
    for (let s = 0; s < ch0.length && offset + s < totalLen; s++) {
      outData[offset + s] += ch0[s];
    }
  });

  return out;
}

/**
 * 再生セッションを作る。プレビュー(スピーカー出力)と録画(MediaStream)を両立。
 * @returns {{ start, stop, currentTime, streamDest }}
 */
export function createPlayer(ac, audioBuffer) {
  const streamDest = ac.createMediaStreamDestination();
  let src = null;
  let startAt = 0;

  return {
    streamDest,
    /** monitor=true でスピーカーにも出す */
    start(monitor = true, offset = 0) {
      src = ac.createBufferSource();
      src.buffer = audioBuffer;
      src.connect(streamDest);
      if (monitor) src.connect(ac.destination);
      startAt = ac.currentTime - offset;
      src.start(0, offset);
      return src;
    },
    stop() {
      if (src) {
        try {
          src.stop();
        } catch {}
        src.disconnect();
        src = null;
      }
    },
    /** 再生位置(秒) */
    currentTime() {
      return ac.currentTime - startAt;
    },
  };
}
