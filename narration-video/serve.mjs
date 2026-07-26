// 依存なしの静的配信サーバ。VOICEVOX の CORS(localhost 許可)とESモジュール読込のため
// file:// ではなく http://localhost:PORT で開く必要がある。
import http from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const ROOT = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.PORT || 8123;
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
};

const server = http.createServer(async (req, res) => {
  try {
    let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (p === "/") p = "/index.html";
    const full = normalize(join(ROOT, p));
    // 区切りまで見て判定する。startsWith(ROOT) だけだと ROOT と先頭が一致する
    // 兄弟ディレクトリ（…/narration-videoX）を通してしまう。
    if (full !== ROOT && !full.startsWith(ROOT + sep)) {
      res.writeHead(403).end("forbidden");
      return;
    }
    const body = await readFile(full);
    res.writeHead(200, { "Content-Type": TYPES[extname(full)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found");
  }
});

// 開発用なのでループバックだけに出す（既定の 0.0.0.0 は同一 LAN から読める）。
server.listen(PORT, "127.0.0.1", () => {
  console.log(`朗読動画メーカー: http://localhost:${PORT}/`);
});
