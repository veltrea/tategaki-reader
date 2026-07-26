#!/usr/bin/env python3
"""アプリ内 DEBUG テストバス(127.0.0.1:47831)へ任意 JSON を投げる。"""
import json, socket, sys

def send(payload, timeout=20.0):
    s = socket.create_connection(("127.0.0.1", 47831), timeout=timeout)
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
