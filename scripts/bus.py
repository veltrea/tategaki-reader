#!/usr/bin/env python3
"""アプリ内 DEBUG テストバス(127.0.0.1:47831)へ任意 JSON を投げる。

ポートは環境変数 EPUB_TEST_BUS_PORT で変えられる（TestBus.swift と同じ変数）。
ワークツリーを分けて並行に作業するときは、両方のアプリが同じポートを取り合って
テストが別のアプリに当たるので、ワークツリーごとに違う値を決めておく。
"""
import json, os, socket, sys

def _port():
    raw = (os.environ.get("EPUB_TEST_BUS_PORT") or "").strip()
    if not raw:
        # scripts/run.sh がこのワークツリー用に決めた値。
        try:
            here = os.path.dirname(os.path.abspath(__file__))
            with open(os.path.join(here, os.pardir, ".testbus-port")) as f:
                raw = f.read().strip()
        except OSError:
            raw = ""
    return int(raw) if raw.isdigit() and int(raw) >= 1024 else 47831

def send(payload, timeout=20.0):
    s = socket.create_connection(("127.0.0.1", _port()), timeout=timeout)
    s.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return buf.decode(errors="replace").strip()

if __name__ == "__main__":
    print(send(json.loads(sys.argv[1])))
