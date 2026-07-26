#!/usr/bin/env python3
"""書棚の各 EPUB が『縦書きの意思』をどこに書いているかを横断調査する。

このマシンのアプリ設定から自分の書棚を読む、手元専用の診断ツール。
"""
import json, os, plistlib, re, zipfile

p = os.path.expanduser("~/Library/Preferences/com.veltrea.EpubReaderSpike.plist")
books = json.loads(plistlib.load(open(p, 'rb'))["library.books.v1"])

WM = re.compile(r'([^{}]*)\{([^{}]*?(?:-epub-|-webkit-)?writing-mode\s*:\s*([a-z-]+)[^{}]*)\}', re.I)

def analyze(path):
    out = {"opfMeta": None, "ppd": None, "htmlClass": set(), "htmlAttrs": set(),
           "wmRules": [], "css": [], "err": None}
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        opf = next((n for n in names if n.endswith('.opf')), None)
        if opf:
            t = z.read(opf).decode('utf-8', 'replace')
            m = re.search(r'<meta[^>]*name=["\']primary-writing-mode["\'][^>]*content=["\']([^"\']+)', t) \
                or re.search(r'<meta[^>]*content=["\']([^"\']+)["\'][^>]*name=["\']primary-writing-mode["\']', t)
            out["opfMeta"] = m.group(1) if m else None
            m = re.search(r'page-progression-direction=["\']([^"\']+)', t)
            out["ppd"] = m.group(1) if m else None
        xhtml = [n for n in names if re.search(r'\.(x?html)$', n, re.I)][:400]
        for n in xhtml[:80]:
            t = z.read(n).decode('utf-8', 'replace')[:2000]
            m = re.search(r'<html\b([^>]*)>', t, re.I)
            if not m: continue
            attrs = m.group(1)
            c = re.search(r'class=["\']([^"\']*)', attrs)
            if c: out["htmlClass"].add(c.group(1).strip())
            for a in re.findall(r'\b(epub:type|xml:lang|dir|style)=', attrs):
                out["htmlAttrs"].add(a)
        for n in [x for x in names if x.lower().endswith('.css')]:
            css = z.read(n).decode('utf-8', 'replace')
            out["css"].append(os.path.basename(n))
            for sel, decl, val in WM.findall(css):
                out["wmRules"].append((os.path.basename(n), ' '.join(sel.split())[:60], val))
    out["htmlClass"] = sorted(out["htmlClass"])
    out["htmlAttrs"] = sorted(out["htmlAttrs"])
    return out

for b in books:
    path = b.get("path")
    title = b.get("title", "?")[:34]
    if not path or not os.path.exists(path):
        print(f"--- {title}\n    (ファイル無し)"); continue
    try:
        r = analyze(path)
    except Exception as e:
        print(f"--- {title}\n    ERROR {e}"); continue
    # html/body に効く縦書きルールがあるか
    effective = [x for x in r["wmRules"]
                 if re.search(r'(^|[\s,])(html|body|:root)\b|\.vrtl|\.hltr', x[1], re.I)
                 and x[2].startswith('vertical')]
    print(f"--- {title}")
    print(f"    OPF meta={r['opfMeta']}  ppd={r['ppd']}  html.class={r['htmlClass']}  bookWM={b.get('writingMode')}")
    print(f"    CSS内 writing-mode 宣言 {len(r['wmRules'])}件 / うち html|body|.vrtl に効くもの {len(effective)}件")
    for f, sel, val in r["wmRules"][:6]:
        mark = "***" if (f, sel, val) in effective else "   "
        print(f"      {mark} [{f}] {sel} -> {val}")
