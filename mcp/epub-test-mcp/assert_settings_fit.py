#!/usr/bin/env python3
"""設定シートのレイアウト回帰アサート（数値検証）。

目的:
  設定シート(AXSheet)の中の操作系コントロールが、シート枠から
  1つでも「はみ出し(こぼれ)」ていないことを、既知の枠寸法に対して
  プログラムで数値アサートする。目視スクショに頼らない
  (layout-qa-fixture-rule: 既知寸法の基準フィクスチャ + MCP測定で数値アサート)。

背景:
  本アプリは Mac Catalyst。SwiftUI .sheet は UIKit フォームシートとして
  提示され、システム既定サイズに丸められることがある。content の
  .frame(minHeight:) が honored されないと、シート下端で最終行
  (「言語 / Auto」など)が切れる。この回帰を検出するのが本アサート。

やること:
  1. DEBUG テストバス(127.0.0.1:47831)経由で本を開き → 設定シートを開く
  2. Accessibility ツリーから設定シート枠(AXSheet)を特定
  3. シート内の全操作系コントロール(Button/Slider/PopUp/TextField/CheckBox)を収集
  4. 各コントロールが枠から各辺で何pt はみ出しているかを測る
     (正=はみ出し / 負=内側の余白)。worst>tol なら FAIL。

使い方:
  python3 assert_settings_fit.py            # 既定: 見本 を開いて検証
  python3 assert_settings_fit.py --book 見本 --tol 1.0
  終了コード: 0=PASS / 1=FAIL / 2=セットアップ失敗

注意: DEBUG ビルドのアプリが起動している必要がある。
"""
import argparse
import json
import os
import socket
import sys
import time

import axdriver as ax
from ApplicationServices import AXUIElementPerformAction, kAXChildrenAttribute

APP = "EpubReaderSpike"
BUS_HOST = "127.0.0.1"
# ポートは axdriver と同じく EPUB_TEST_BUS_PORT で振り分けられる（並行作業での混線防止）。
BUS_PORT = ax.TESTBUS_PORT
INTERACTIVE = {"AXButton", "AXSlider", "AXPopUpButton", "AXTextField", "AXCheckBox"}


def bus(cmd: dict) -> dict:
    """DEBUG テストバスへ 1 行 JSON を送って 1 行 JSON を受け取る。"""
    s = socket.create_connection((BUS_HOST, BUS_PORT), timeout=5)
    try:
        s.sendall((json.dumps(cmd) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        return json.loads(buf.split(b"\n")[0])
    finally:
        s.close()


def find_sheet():
    """設定見出し(AXHeading '設定')を含む AXSheet 枠を返す。無ければ None。"""
    sheets = ax.find_all({"role": "AXSheet"}, APP)
    for sh in sheets:
        if _contains(sh, "設定"):
            info = ax._node_info(sh)
            if info["pos"] and info["size"]:
                return sh, info
    return None, None


def _contains(el, needle, depth=0):
    info = ax._node_info(el)
    if needle in (info.get("desc") or "") or needle in (info.get("title") or ""):
        return True
    if depth < 22:
        for k in (ax._attr(el, kAXChildrenAttribute) or []):
            if _contains(k, needle, depth + 1):
                return True
    return False


def _collect(el, out, depth=0):
    info = ax._node_info(el)
    if info["role"] in INTERACTIVE and info["pos"] and info["size"]:
        out.append(info)
    if depth < 25:
        for k in (ax._attr(el, kAXChildrenAttribute) or []):
            _collect(k, out, depth + 1)
    return out


def find_tabs(sheet):
    """設定シートのタブ(AXTabGroup 配下の AXRadioButton)を [(ラベル, 要素)] で返す。

    設定は「読み上げ / 表示」のタブに分かれており、選ばれていないタブの中身は
    そもそも描かれない。全タブを順に選んで測らないと、切れているタブを見逃す。
    """
    out = []

    def walk(el, depth=0):
        info = ax._node_info(el)
        if info["role"] == "AXRadioButton":
            label = info.get("desc") or info.get("title") or "?"
            out.append((label, el))
        if depth < 22:
            for k in (ax._attr(el, kAXChildrenAttribute) or []):
                walk(k, depth + 1)

    walk(sheet)
    return out


def measure(sheet_info, controls):
    sx, sy = sheet_info["pos"]
    sw, sh = sheet_info["size"]
    rows = []
    worst = -1e9
    for c in controls:
        x, y = c["pos"]
        w, h = c["size"]
        edges = {
            "left": sx - x,
            "top": sy - y,
            "right": (x + w) - (sx + sw),
            "bottom": (y + h) - (sy + sh),
        }
        over = max(edges.values())
        label = (c["desc"] or c["title"] or c["value"] or "?")[:36]
        rows.append((c["role"], over, edges, label))
        worst = max(worst, over)
    return worst, rows, (sx, sy, sw, sh)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--book", default="見本", help="開く本のタイトル部分一致")
    ap.add_argument("--tol", type=float, default=1.0, help="許容はみ出しpt(既定1.0)")
    ap.add_argument("--no-open", action="store_true", help="本/設定を開かず現状のまま測る")
    a = ap.parse_args()

    if not a.no_open:
        try:
            r = bus({"cmd": "open", "title_contains": a.book})
            if not r.get("ok"):
                print(f"[setup] 本を開けない: {r}", file=sys.stderr)
                return 2
            time.sleep(1.0)
            r = bus({"cmd": "openSettings"})
            if not r.get("ok"):
                print(f"[setup] 設定を開けない: {r}", file=sys.stderr)
                return 2
            time.sleep(0.8)
        except OSError as e:
            print(f"[setup] テストバス接続失敗(アプリ未起動?): {e}", file=sys.stderr)
            return 2

    sheet, info = find_sheet()
    if sheet is None:
        print("[fail] 設定シート(AXSheet)が見つからない。DEBUGビルドで設定が開いているか確認。",
              file=sys.stderr)
        return 2

    tabs = find_tabs(sheet)
    # タブが無い版でも動くよう、見つからなければ現在の内容だけ測る。
    targets = tabs or [(None, None)]
    overall = -1e9

    for tab_label, tab_el in targets:
        if tab_el is not None:
            AXUIElementPerformAction(tab_el, "AXPress")
            time.sleep(0.8)
            sheet, info = find_sheet()
            if sheet is None:
                print(f"[fail] タブ「{tab_label}」を選んだあとシートを見失った", file=sys.stderr)
                return 2

        controls = _collect(sheet, [])
        worst, rows, (sx, sy, sw, sh) = measure(info, controls)
        overall = max(overall, worst)

        head = f"タブ「{tab_label}」 " if tab_label else ""
        print(f"{head}AXSheet 枠: x={sx:.0f} y={sy:.0f} w={sw:.0f} h={sh:.0f} "
              f"(下端={sy+sh:.0f})  コントロール数={len(rows)}")
        print(f"{'role':14} {'over(pt)':>9}  {'bottom':>7}  label")
        for role, over, edges, label in sorted(rows, key=lambda r: -r[1]):
            mark = "  <== はみ出し" if over > a.tol else ""
            print(f"{role:14} {over:9.1f}  {edges['bottom']:7.1f}  {label}{mark}")
        print()

    ok = overall <= a.tol
    print(f"worst はみ出し = {overall:.1f}pt / 許容 {a.tol:.1f}pt -> "
          f"{'PASS ✅' if ok else 'FAIL ❌'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
