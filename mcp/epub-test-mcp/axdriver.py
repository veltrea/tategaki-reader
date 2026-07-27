#!/usr/bin/env python3
"""EpubReaderSpike を Accessibility(AX) API で駆動するドライバ。

computer-use の代替。座標クリック・frontmost 検査・通知センターの被りに一切依存せず、
AXUIElement で「要素ツリー読み取り / ボタン押下 / テキスト設定 / メニュー実行」を行う。

- MCP サーバー(server.py)から import してツール化する。
- 同時に CLI としても動く（即席テスト用）:
    python3 axdriver.py tree
    python3 axdriver.py find --role AXRadioButton --desc-contains リスト
    python3 axdriver.py act  --desc-contains 箇条書き --action AXPress
    python3 axdriver.py set  --role AXTextField --focused --value-str "やまだ たろう"
    python3 axdriver.py menu --path "ファイル>開く"

依存: /usr/bin/python3（pyobjc 同梱）。外部パッケージ不要。
注意: AX 呼び出しには Accessibility 権限が要る（この Python は許可済みを確認済み）。
"""
import os
import sys
import json
import socket

from ApplicationServices import (
    AXIsProcessTrusted,
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    AXUIElementSetAttributeValue,
    AXUIElementCopyActionNames,
    AXUIElementPerformAction,
    kAXWindowsAttribute,
    kAXChildrenAttribute,
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXTitleAttribute,
    kAXValueAttribute,
    kAXDescriptionAttribute,
    kAXMenuBarAttribute,
    kAXFocusedUIElementAttribute,
    kAXPositionAttribute,
    kAXSizeAttribute,
    AXValueGetValue,
)
from AppKit import NSWorkspace
from Quartz import CGPoint, CGSize

# AXValue の型定数（pyobjc バージョン差を吸収）。
try:
    from ApplicationServices import kAXValueCGPointType as _AXV_CGPOINT
    from ApplicationServices import kAXValueCGSizeType as _AXV_CGSIZE
except Exception:  # 新しめの命名
    from ApplicationServices import kAXValueTypeCGPoint as _AXV_CGPOINT
    from ApplicationServices import kAXValueTypeCGSize as _AXV_CGSIZE

DEFAULT_APP = "EpubReaderSpike"
# アプリ内 DEBUG テストバス（TestBus.swift と一致）。ワークツリーを分けて並行作業すると
# 両方のビルドが同じポートを取り合い、テストが別のアプリに当たってしまうので、
# 環境変数 EPUB_TEST_BUS_PORT で振り分けられるようにしてある（アプリ側も同じ変数を見る）。
def _testbus_port() -> int:
    raw = (os.environ.get("EPUB_TEST_BUS_PORT") or "").strip()
    if not raw:
        # scripts/run.sh がこのワークツリー用に決めた値（無ければ既定へ落ちる）。
        here = os.path.dirname(os.path.abspath(__file__))
        try:
            with open(os.path.join(here, os.pardir, os.pardir, ".testbus-port")) as f:
                raw = f.read().strip()
        except OSError:
            raw = ""
    return int(raw) if raw.isdigit() and int(raw) >= 1024 else 47831


TESTBUS_PORT = _testbus_port()


class AXError(RuntimeError):
    pass


# ---- アプリ内 DEBUG テストバス（AX で届かない操作用）-------------------------

def app_cmd(obj, port=TESTBUS_PORT, timeout=3.0):
    """127.0.0.1:port の TestBus へ JSONL コマンドを1つ送り、応答 JSON を返す。

    AX では駆動できない .contextMenu 限定アクション（作者の読み設定/削除等）や、
    モデルの真の状態取得(state)に使う。DEBUG ビルドでのみ待ち受けている。
    """
    if isinstance(obj, str):
        obj = {"cmd": obj}
    data = (json.dumps(obj, ensure_ascii=False) + "\n").encode("utf-8")
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
        s.sendall(data)
        s.settimeout(timeout)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    line = buf.split(b"\n", 1)[0]
    return json.loads(line.decode("utf-8"))


# ---- 低レベルヘルパ ---------------------------------------------------------

def _attr(el, name):
    err, v = AXUIElementCopyAttributeValue(el, name, None)
    return v if err == 0 else None


def _actions(el):
    err, a = AXUIElementCopyActionNames(el, None)
    return list(a) if err == 0 and a else []


def app_pid(app_name):
    for a in NSWorkspace.sharedWorkspace().runningApplications():
        if a.localizedName() == app_name:
            return a.processIdentifier()
    return None


def app_element(app_name=DEFAULT_APP):
    pid = app_pid(app_name)
    if pid is None:
        raise AXError(f"app not running: {app_name}")
    return AXUIElementCreateApplication(pid)


def _roots(app):
    """探索の起点（開いているウィンドウ群 + メニューバー）。

    コンテキストメニュー/アラートは別ウィンドウとして AXWindows に出るため、
    毎回 fresh に取り直せば古い参照を掴まない。
    """
    roots = []
    wins = _attr(app, kAXWindowsAttribute) or []
    roots.extend(list(wins))
    mb = _attr(app, kAXMenuBarAttribute)
    if mb is not None:
        roots.append(mb)
    return roots


# ---- ツリー走査 -------------------------------------------------------------

def _cgpoint(axvalue):
    """AXValue(CGPoint) → (x, y)。AX の位置は AXValueRef ラップなので AXValueGetValue で取り出す。"""
    if axvalue is None:
        return None
    ok, pt = AXValueGetValue(axvalue, _AXV_CGPOINT, None)
    return (float(pt.x), float(pt.y)) if ok else None


def _cgsize(axvalue):
    if axvalue is None:
        return None
    ok, sz = AXValueGetValue(axvalue, _AXV_CGSIZE, None)
    return (float(sz.width), float(sz.height)) if ok else None


def _node_info(el):
    pt = _cgpoint(_attr(el, kAXPositionAttribute))
    sz = _cgsize(_attr(el, kAXSizeAttribute))
    px, py = (pt if pt else (None, None))
    w, h = (sz if sz else (None, None))
    val = _attr(el, kAXValueAttribute)
    return {
        "role": _attr(el, kAXRoleAttribute),
        "subrole": _attr(el, kAXSubroleAttribute),
        "title": _attr(el, kAXTitleAttribute),
        "desc": _attr(el, kAXDescriptionAttribute),
        "value": None if val is None else str(val),
        "actions": _actions(el),
        "pos": None if px is None else [px, py],
        "size": None if w is None else [w, h],
    }


def walk(el, depth=0, max_depth=14, out=None):
    if out is None:
        out = []
    info = _node_info(el)
    info["depth"] = depth
    out.append(info)
    if depth < max_depth:
        for k in (_attr(el, kAXChildrenAttribute) or []):
            walk(k, depth + 1, max_depth, out)
    return out


def tree(app_name=DEFAULT_APP, max_depth=14):
    app = app_element(app_name)
    out = []
    for r in _roots(app):
        walk(r, 0, max_depth, out)
    return out


# ---- セレクタ照合 -----------------------------------------------------------

def _matches(el, sel):
    role = sel.get("role")
    if role and _attr(el, kAXRoleAttribute) != role:
        return False
    title = sel.get("title")
    if title is not None and _attr(el, kAXTitleAttribute) != title:
        return False
    tc = sel.get("title_contains")
    if tc:
        t = _attr(el, kAXTitleAttribute) or ""
        if tc not in t:
            return False
    desc = sel.get("desc")
    if desc is not None and _attr(el, kAXDescriptionAttribute) != desc:
        return False
    dc = sel.get("desc_contains")
    if dc:
        d = _attr(el, kAXDescriptionAttribute) or ""
        if dc not in d:
            return False
    val = sel.get("value")
    if val is not None and str(_attr(el, kAXValueAttribute)) != str(val):
        return False
    return True


def _collect(el, sel, acc, depth=0, max_depth=18):
    if _matches(el, sel):
        acc.append(el)
    if depth < max_depth:
        for k in (_attr(el, kAXChildrenAttribute) or []):
            _collect(k, sel, acc, depth + 1, max_depth)
    return acc


def find_all(sel, app_name=DEFAULT_APP):
    app = app_element(app_name)
    if sel.get("focused"):
        f = _attr(app, kAXFocusedUIElementAttribute)
        return [f] if (f is not None and _matches(f, sel)) else []
    acc = []
    for r in _roots(app):
        _collect(r, sel, acc)
    return acc


def find_one(sel, app_name=DEFAULT_APP):
    matches = find_all(sel, app_name)
    nth = int(sel.get("nth", 0))
    if not matches:
        raise AXError(f"no element matches selector: {sel}")
    if nth >= len(matches):
        raise AXError(f"nth={nth} out of range (found {len(matches)}) for {sel}")
    return matches[nth]


# ---- 操作 -------------------------------------------------------------------

def do_action(sel, action, app_name=DEFAULT_APP):
    el = find_one(sel, app_name)
    avail = _actions(el)
    if action not in avail:
        raise AXError(f"action {action} not available; has {avail}")
    err = AXUIElementPerformAction(el, action)
    if err != 0:
        raise AXError(f"AXUIElementPerformAction({action}) failed err={err}")
    return {"ok": True, "action": action, "on": _node_info(el)}


def set_value(sel, value, app_name=DEFAULT_APP):
    el = find_one(sel, app_name)
    err = AXUIElementSetAttributeValue(el, kAXValueAttribute, value)
    if err != 0:
        raise AXError(f"AXUIElementSetAttributeValue failed err={err}")
    return {"ok": True, "value": value, "on": _node_info(el)}


def get_value(sel, app_name=DEFAULT_APP):
    el = find_one(sel, app_name)
    return _node_info(el)


# ---- レイアウト測定：はみ出し判定 -------------------------------------------

def _rect(sel, app_name):
    """セレクタ一致要素の矩形 (x, y, w, h)。座標が取れなければ AXError。"""
    info = _node_info(find_one(sel, app_name))
    if not info["pos"] or not info["size"]:
        raise AXError(f"要素の座標が取れない（pos/size=None）: {sel}")
    x, y = info["pos"]
    w, h = info["size"]
    return x, y, w, h, info


def overflow(inner_sel, outer_sel=None, tol=0.0, app_name=DEFAULT_APP):
    """inner が outer の枠から各辺で何ポイントはみ出しているかを返す。

    正の値 = その辺から外へはみ出している / 負の値 = 内側の余白。
    outer_sel 省略時はウィンドウ(AXWindow)を枠とみなす。
    inside = すべての辺で tol 以内に収まっているか（True なら はみ出しなし）。
    """
    if outer_sel is None:
        outer_sel = {"role": "AXWindow"}
    ix, iy, iw, ih, ii = _rect(inner_sel, app_name)
    ox, oy, ow, oh, oi = _rect(outer_sel, app_name)
    left = ox - ix                      # >0: 左枠より外へ
    top = oy - iy                       # >0: 上枠より外へ
    right = (ix + iw) - (ox + ow)       # >0: 右枠より外へ
    bottom = (iy + ih) - (oy + oh)      # >0: 下枠より外へ
    worst = max(left, top, right, bottom)
    return {
        "inside": worst <= tol,
        "worst_overflow": round(worst, 2),
        "edges": {
            "left": round(left, 2), "top": round(top, 2),
            "right": round(right, 2), "bottom": round(bottom, 2),
        },
        "inner": {"role": ii["role"], "desc": ii["desc"], "rect": [round(ix, 2), round(iy, 2), round(iw, 2), round(ih, 2)]},
        "outer": {"role": oi["role"], "desc": oi["desc"], "rect": [round(ox, 2), round(oy, 2), round(ow, 2), round(oh, 2)]},
        "tol": tol,
    }


def menu(path, app_name=DEFAULT_APP):
    """メニューバー項目を辿って AXPress する。path 例: ['ファイル','開く'] または 'ファイル>開く'。"""
    if isinstance(path, str):
        path = [p.strip() for p in path.split(">") if p.strip()]
    app = app_element(app_name)
    mb = _attr(app, kAXMenuBarAttribute)
    if mb is None:
        raise AXError("no menu bar")
    cur = mb
    for i, name in enumerate(path):
        kids = _attr(cur, kAXChildrenAttribute) or []
        found = None
        for k in kids:
            if _attr(k, kAXTitleAttribute) == name:
                found = k
                break
        if found is None:
            raise AXError(f"menu item not found: {name} (level {i})")
        # メニュー項目はサブメニュー(AXMenu)を子に持つので降りる
        if i < len(path) - 1:
            sub = _attr(found, kAXChildrenAttribute) or []
            cur = sub[0] if sub else found
        else:
            AXUIElementPerformAction(found, "AXPress")
    return {"ok": True, "path": path}


# ---- CLI --------------------------------------------------------------------

def _sel_from_args(a):
    sel = {}
    for key, dst in [
        ("role", "role"), ("title", "title"), ("title_contains", "title_contains"),
        ("desc", "desc"), ("desc_contains", "desc_contains"), ("value", "value"),
        ("nth", "nth"),
    ]:
        v = getattr(a, key, None)
        if v is not None:
            sel[dst] = v
    if getattr(a, "focused", False):
        sel["focused"] = True
    return sel


def _main(argv):
    import argparse
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_sel(sp):
        sp.add_argument("--role")
        sp.add_argument("--title")
        sp.add_argument("--title-contains", dest="title_contains")
        sp.add_argument("--desc")
        sp.add_argument("--desc-contains", dest="desc_contains")
        sp.add_argument("--value")
        sp.add_argument("--nth", type=int)
        sp.add_argument("--focused", action="store_true")
        sp.add_argument("--app", default=DEFAULT_APP)

    t = sub.add_parser("tree"); t.add_argument("--app", default=DEFAULT_APP); t.add_argument("--max-depth", type=int, default=14)
    f = sub.add_parser("find"); add_sel(f)
    ac = sub.add_parser("act"); add_sel(ac); ac.add_argument("--action", required=True)
    st = sub.add_parser("set"); add_sel(st); st.add_argument("--value-str", dest="value_str", required=True)
    gt = sub.add_parser("get"); add_sel(gt)
    ov = sub.add_parser("overflow"); add_sel(ov)
    ov.add_argument("--outer-role", dest="outer_role")
    ov.add_argument("--outer-desc", dest="outer_desc")
    ov.add_argument("--outer-desc-contains", dest="outer_desc_contains")
    ov.add_argument("--tol", type=float, default=0.0)
    mn = sub.add_parser("menu"); mn.add_argument("--path", required=True); mn.add_argument("--app", default=DEFAULT_APP)
    cm = sub.add_parser("cmd"); cm.add_argument("--json", required=True, help="TestBus へ送る JSON 文字列")
    ol = sub.add_parser("overlay", help="計りレイヤー(ルーラー+16色帯)をWebView本文にON/OFF")
    ol.add_argument("--off", action="store_true", help="除去（既定はON）")
    sub.add_parser("measure", help="現在ページの画像/本文 bbox を測って返す")
    sub.add_parser("trusted")

    a = p.parse_args(argv)

    if a.cmd == "trusted":
        print(json.dumps({"trusted": bool(AXIsProcessTrusted())})); return
    if a.cmd == "tree":
        nodes = tree(a.app, a.max_depth)
        for n in nodes:
            ind = "  " * n["depth"]
            bits = [n["role"] or "?"]
            for k in ("title", "desc", "value"):
                if n.get(k):
                    bits.append(f"{k}={n[k]!r}")
            if n["actions"]:
                bits.append(f"act={n['actions']}")
            print(ind + " ".join(bits))
        return
    if a.cmd == "menu":
        print(json.dumps(menu(a.path, a.app), ensure_ascii=False)); return
    if a.cmd == "cmd":
        print(json.dumps(app_cmd(json.loads(a.json)), ensure_ascii=False)); return
    if a.cmd == "overlay":
        cmd = "overlayOff" if a.off else "overlayOn"
        print(json.dumps(app_cmd({"cmd": cmd}), ensure_ascii=False)); return
    if a.cmd == "measure":
        print(json.dumps(app_cmd({"cmd": "measureImage"}), ensure_ascii=False)); return

    sel = _sel_from_args(a)
    app_name = getattr(a, "app", DEFAULT_APP)
    if a.cmd == "find":
        res = [_node_info(e) for e in find_all(sel, app_name)]
        print(json.dumps(res, ensure_ascii=False, indent=2))
    elif a.cmd == "act":
        print(json.dumps(do_action(sel, a.action, app_name), ensure_ascii=False))
    elif a.cmd == "set":
        print(json.dumps(set_value(sel, a.value_str, app_name), ensure_ascii=False))
    elif a.cmd == "get":
        print(json.dumps(get_value(sel, app_name), ensure_ascii=False))
    elif a.cmd == "overflow":
        outer = {}
        if a.outer_role: outer["role"] = a.outer_role
        if a.outer_desc: outer["desc"] = a.outer_desc
        if a.outer_desc_contains: outer["desc_contains"] = a.outer_desc_contains
        print(json.dumps(overflow(sel, outer or None, a.tol, app_name), ensure_ascii=False))


if __name__ == "__main__":
    try:
        _main(sys.argv[1:])
    except AXError as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False)); sys.exit(1)
