// ブラウザ用 VOICEVOX クライアント（fetch 実体）。
// buildTimeline に queryFetch / synthFetch として注入する。

export function makeVVClient(baseURL = "http://127.0.0.1:50021") {
  return {
    async listSpeakers() {
      const r = await fetch(`${baseURL}/speakers`);
      if (!r.ok) throw new Error("speakers " + r.status);
      return r.json();
    },
    async version() {
      const r = await fetch(`${baseURL}/version`, { signal: AbortSignal.timeout(2500) });
      return r.ok ? r.text() : null;
    },
    async queryFetch(line, speaker) {
      const r = await fetch(
        `${baseURL}/audio_query?text=${encodeURIComponent(line)}&speaker=${speaker}`,
        { method: "POST" }
      );
      if (!r.ok) throw new Error("audio_query " + r.status);
      return r.json();
    },
    async synthFetch(query, speaker) {
      const r = await fetch(`${baseURL}/synthesis?speaker=${speaker}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(query),
      });
      if (!r.ok) throw new Error("synthesis " + r.status);
      return new Uint8Array(await r.arrayBuffer());
    },
  };
}

/** 録画に使える最適な mimeType を選ぶ（MP4 優先、無ければ WebM）。 */
export function pickRecorderMime() {
  const candidates = [
    "video/mp4;codecs=avc1.42E01E,mp4a.40.2",
    "video/mp4;codecs=avc1,mp4a.40.2",
    "video/mp4",
    "video/webm;codecs=vp9,opus",
    "video/webm;codecs=vp8,opus",
    "video/webm",
  ];
  for (const m of candidates) {
    if (window.MediaRecorder && MediaRecorder.isTypeSupported(m)) return m;
  }
  return "";
}
