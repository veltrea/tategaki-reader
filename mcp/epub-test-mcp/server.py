#!/usr/bin/env python3
"""EpubReaderSpike テスト用の最小 MCP サーバー（stdio / JSONL）。

アプリを前面化せずにウィンドウを撮る `screenshot` ツールを提供する。
screencapture -l <windowID> はウィンドウサーバーから直接撮るので、
非アクティブ・他ウィンドウに隠れていても撮れる（ユーザーの操作を邪魔しない）。

依存: /usr/bin/python3（pyobjc/Quartz 同梱）。外部パッケージ不要。
注意: MCP stdio transport は JSONL（1行1 JSON、\n 区切り）。Content-Length ヘッダーは付けない。
"""
import sys
import json
import base64
import subprocess
import tempfile
import os

try:
    import Quartz
except Exception:  # pragma: no cover
    Quartz = None

try:
    import axdriver  # AX 駆動（同ディレクトリ）
except Exception:  # pragma: no cover
    axdriver = None

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "epub-test-mcp", "version": "0.1.0"}

TOOLS = [
    {
        "name": "screenshot",
        "description": (
            "EpubReaderSpike（または指定アプリ）のウィンドウを、前面化せずにキャプチャして "
            "PNG 画像を返す。非アクティブ・他ウィンドウに隠れていても撮れる。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "app": {
                    "type": "string",
                    "description": "対象アプリ名（既定 EpubReaderSpike）",
                }
            },
        },
    },
    {
        "name": "list_windows",
        "description": "現在オンスクリーンのウィンドウ（オーナーアプリ名・サイズ・window id）を列挙する。",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "ui_tree",
        "description": (
            "アプリの Accessibility 要素ツリーを構造化テキストで返す（role/title/desc/value/actions）。"
            "スクショの代わりに UI 状態を確認する。座標も frontmost も不要。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "app": {"type": "string", "description": "対象アプリ名（既定 EpubReaderSpike）"},
                "max_depth": {"type": "integer", "description": "走査の深さ（既定 14）"},
                "grep": {"type": "string", "description": "この文字列を含む行だけ返す（任意）"},
            },
        },
    },
    {
        "name": "ui_find",
        "description": "セレクタに一致する要素を列挙する（role/title/desc/value 等）。操作前の確認に使う。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string"},
                "title": {"type": "string"},
                "title_contains": {"type": "string"},
                "desc": {"type": "string"},
                "desc_contains": {"type": "string"},
                "value": {"type": "string"},
                "app": {"type": "string"},
            },
        },
    },
    {
        "name": "ui_action",
        "description": (
            "セレクタに一致する要素へ AX アクションを実行（AXPress/AXConfirm/AXCancel/AXScrollToVisible 等）。"
            "ボタン押下・グリッド/インデックス切替(AXRadioButton)などに使う。"
            "注意: SwiftUI の .contextMenu(右クリックメニュー)は AXShowMenu では開けない。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string"},
                "title": {"type": "string"},
                "title_contains": {"type": "string"},
                "desc": {"type": "string"},
                "desc_contains": {"type": "string"},
                "value": {"type": "string"},
                "nth": {"type": "integer"},
                "focused": {"type": "boolean"},
                "action": {"type": "string", "description": "実行する AX アクション名（例 AXPress）"},
                "app": {"type": "string"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "ui_set_value",
        "description": "セレクタに一致する要素(テキスト欄など)へ値を設定する。TextField への入力に使う。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string"},
                "title": {"type": "string"},
                "desc": {"type": "string"},
                "desc_contains": {"type": "string"},
                "value": {"type": "string", "description": "現在値での絞り込み（例 空文字）"},
                "nth": {"type": "integer"},
                "focused": {"type": "boolean"},
                "text": {"type": "string", "description": "設定する文字列"},
                "app": {"type": "string"},
            },
            "required": ["text"],
        },
    },
    {
        "name": "ui_menu",
        "description": "メニューバー項目を辿って実行する。path 例 'ファイル>開く'。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "'>' 区切りのメニュー経路"},
                "app": {"type": "string"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "ui_overflow",
        "description": (
            "要素(inner)が枠(outer, 既定はウィンドウ)から各辺で何ポイントはみ出しているか数値で返す。"
            "正=はみ出し / 負=内側の余白。inside=true なら はみ出しなし。"
            "ボタンが枠外・テキスト見切れ・画像が余白超過 等のレイアウト事故検出に使う。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {"type": "string", "description": "inner のセレクタ"},
                "title": {"type": "string"},
                "title_contains": {"type": "string"},
                "desc": {"type": "string"},
                "desc_contains": {"type": "string"},
                "value": {"type": "string"},
                "nth": {"type": "integer"},
                "outer_role": {"type": "string", "description": "枠のセレクタ（省略時 AXWindow）"},
                "outer_desc": {"type": "string"},
                "outer_desc_contains": {"type": "string"},
                "tol": {"type": "number", "description": "許容差pt（既定0）"},
                "app": {"type": "string"},
            },
        },
    },
    {
        "name": "measure_overlay",
        "description": (
            "リーダーの WebView 本文に『計りレイヤー』（ルーラー + 16色2レーンの絶対座標リボン）を "
            "重ねる/外す/測る。ネイティブ測定グリッドと同一の配色・符号化（cell=10px, "
            "下位色=palette[cell%16] / 上位色=palette[(cell/16)%16]）。DEBUG ビルド・本を開いた状態で動作。\n"
            "  mode=on   : 計りレイヤーを注入（この後 screenshot で色帯を読む）\n"
            "  mode=off  : 計りレイヤーを除去\n"
            "  mode=measure : 現在ページの img/svg と body の getBoundingClientRect を JSON で返す "
            "（各辺の viewport への隙間 gapLeft/Right/Top/Bottom、中央 centerX/Y、端の色帯 leftBand/rightBand 付き）。\n"
            "使い方: on→screenshot（AIが色帯で絶対座標を読む）→measure（数値で裏取り）→修正→再測定。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "enum": ["on", "off", "measure"],
                    "description": "on=注入 / off=除去 / measure=bbox測定",
                }
            },
            "required": ["mode"],
        },
    },
    {
        "name": "app_cmd",
        "description": (
            "アプリ内コマンドバス(127.0.0.1:47831)へコマンドを送る。AX では駆動できない "
            ".contextMenu 限定操作や、モデルの真の状態取得に使う。\n"
            "読み辞書まわり（ping / dictList / dictAdd / dictUpdate / dictDelete / setRules / "
            "applyRules）は配布版でも通る。それ以外は DEBUG ビルドでのみ動作。\n"
            "cmd 一覧: ping / state / setYomi(title_contains,yomi) / clearYomi(title_contains) / "
            "remove(title_contains) / open(title_contains) / openYomiEditor(title_contains) / "
            "overlayOn / overlayOff / measureImage（計りレイヤーは measure_overlay ツールが便利）/ "
            "dictList / dictAdd(surface,reading,layer) / dictDelete(id) / "
            "applyRules(text) …読み辞書の一括投入と検算。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string", "description": "コマンド名（例 state, setYomi, dictAdd）"},
                "title_contains": {"type": "string", "description": "対象書籍をタイトル部分一致で指定"},
                "title": {"type": "string"},
                "id": {"type": "string", "description": "対象の id（dictUpdate / dictDelete の語 id など）"},
                "yomi": {"type": "string", "description": "setYomi 用の読み（かな）"},
                # 読み辞書の編集・検算。手で数十件入れるのは割に合わないので、
                # エージェントが dictAdd → applyRules の往復で自分の登録結果を検算できるようにする。
                "surface": {"type": "string", "description": "dictAdd/dictUpdate: 本文中の表記（例 明暗）"},
                "reading": {"type": "string", "description": "dictAdd/dictUpdate: 読み（カタカナ）"},
                "layer": {
                    "type": "integer",
                    "description": "dictAdd/dictUpdate: 適用レイヤー 1..10（大きいほど先に置換）。既定 5",
                },
                "text": {"type": "string", "description": "applyRules: 辞書を適用して読み上げに渡る文字列を得る文"},
            },
            "required": ["cmd"],
        },
    },
]


def _selector(args):
    sel = {}
    for k in ("role", "title", "title_contains", "desc", "desc_contains", "value", "nth", "focused"):
        if args.get(k) is not None:
            sel[k] = args[k]
    return sel


def find_window_id(app):
    if Quartz is None:
        return None
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID
    )
    best = None
    for w in wins:
        if w.get("kCGWindowOwnerName") != app:
            continue
        if w.get("kCGWindowLayer", 0) != 0:
            continue
        b = w.get("kCGWindowBounds", {})
        area = b.get("Width", 0) * b.get("Height", 0)
        if best is None or area > best[1]:
            best = (int(w["kCGWindowNumber"]), area)
    return best[0] if best else None


def list_windows():
    if Quartz is None:
        return []
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID
    )
    out = []
    for w in wins:
        if w.get("kCGWindowLayer", 0) != 0:
            continue
        b = w.get("kCGWindowBounds", {})
        out.append(
            {
                "app": w.get("kCGWindowOwnerName", ""),
                "id": int(w.get("kCGWindowNumber", 0)),
                "w": int(b.get("Width", 0)),
                "h": int(b.get("Height", 0)),
            }
        )
    return out


def capture(app):
    wid = find_window_id(app)
    if wid is None:
        raise RuntimeError(f"window not found for app: {app}")
    fd, path = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        subprocess.run(
            ["screencapture", "-o", "-x", "-l", str(wid), path], check=True
        )
        with open(path, "rb") as f:
            data = f.read()
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    return base64.b64encode(data).decode("ascii")


def handle(method, params):
    if method == "initialize":
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": SERVER_INFO,
        }
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "screenshot":
            app = args.get("app") or "EpubReaderSpike"
            b64 = capture(app)
            return {
                "content": [
                    {"type": "image", "data": b64, "mimeType": "image/png"}
                ]
            }
        if name == "list_windows":
            wins = list_windows()
            return {
                "content": [
                    {"type": "text", "text": json.dumps(wins, ensure_ascii=False)}
                ]
            }
        # ---- AX 駆動ツール ----
        if name in ("ui_tree", "ui_find", "ui_action", "ui_set_value", "ui_menu", "ui_overflow"):
            if axdriver is None:
                raise RuntimeError("axdriver 未ロード（pyobjc/AX 権限を確認）")
            app = args.get("app") or "EpubReaderSpike"
            if name == "ui_tree":
                nodes = axdriver.tree(app, int(args.get("max_depth", 14)))
                lines = []
                for n in nodes:
                    ind = "  " * n["depth"]
                    bits = [n["role"] or "?"]
                    for k in ("title", "desc", "value"):
                        if n.get(k):
                            bits.append(f"{k}={n[k]!r}")
                    if n["actions"]:
                        bits.append(f"act={n['actions']}")
                    lines.append(ind + " ".join(bits))
                grep = args.get("grep")
                if grep:
                    lines = [ln for ln in lines if grep in ln]
                return {"content": [{"type": "text", "text": "\n".join(lines)}]}
            if name == "ui_find":
                res = [axdriver._node_info(e) for e in axdriver.find_all(_selector(args), app)]
                return {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=2)}]}
            if name == "ui_action":
                r = axdriver.do_action(_selector(args), args["action"], app)
                return {"content": [{"type": "text", "text": json.dumps(r, ensure_ascii=False)}]}
            if name == "ui_set_value":
                r = axdriver.set_value(_selector(args), args["text"], app)
                return {"content": [{"type": "text", "text": json.dumps(r, ensure_ascii=False)}]}
            if name == "ui_menu":
                r = axdriver.menu(args["path"], app)
                return {"content": [{"type": "text", "text": json.dumps(r, ensure_ascii=False)}]}
            if name == "ui_overflow":
                outer = {}
                if args.get("outer_role"): outer["role"] = args["outer_role"]
                if args.get("outer_desc"): outer["desc"] = args["outer_desc"]
                if args.get("outer_desc_contains"): outer["desc_contains"] = args["outer_desc_contains"]
                r = axdriver.overflow(_selector(args), outer or None, float(args.get("tol", 0.0)), app)
                return {"content": [{"type": "text", "text": json.dumps(r, ensure_ascii=False)}]}
        if name == "measure_overlay":
            if axdriver is None:
                raise RuntimeError("axdriver 未ロード")
            mode = args.get("mode")
            cmd = {"on": "overlayOn", "off": "overlayOff", "measure": "measureImage"}.get(mode)
            if cmd is None:
                raise RuntimeError(f"invalid mode: {mode}（on/off/measure）")
            r = axdriver.app_cmd({"cmd": cmd})
            return {"content": [{"type": "text", "text": json.dumps(r, ensure_ascii=False)}]}
        if name == "app_cmd":
            if axdriver is None:
                raise RuntimeError("axdriver 未ロード")
            payload = {k: v for k, v in args.items() if k != "app"}
            r = axdriver.app_cmd(payload)
            return {"content": [{"type": "text", "text": json.dumps(r, ensure_ascii=False)}]}
        raise RuntimeError(f"unknown tool: {name}")
    raise RuntimeError(f"unknown method: {method}")


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        mid = msg.get("id")
        method = msg.get("method")
        params = msg.get("params") or {}
        # 通知（id 無し）は応答しない。
        if mid is None:
            continue
        try:
            result = handle(method, params)
            send({"jsonrpc": "2.0", "id": mid, "result": result})
        except Exception as e:  # pragma: no cover
            send(
                {
                    "jsonrpc": "2.0",
                    "id": mid,
                    "error": {"code": -32000, "message": str(e)},
                }
            )


if __name__ == "__main__":
    main()
