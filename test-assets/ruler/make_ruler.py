#!/usr/bin/env python3
"""測定用「メジャー画像」を生成する。

画像の四辺に 0-100% の目盛りを焼き込み、中央に十字とサイズ表記を入れる。
リーダーで表示したスクショから、画像の実バウンディングボックスと目盛りを
突き合わせれば「上下左右がどれだけずれ/欠けているか」をピクセル単位で測れる。
"""
import sys
from PIL import Image, ImageDraw, ImageFont

def load_font(size):
    for path in [
        "/System/Library/Fonts/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()

def draw_ruler(W, H, out, label):
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)

    # 薄い 10% グリッド
    for i in range(1, 10):
        x = round(W * i / 10)
        y = round(H * i / 10)
        d.line([(x, 0), (x, H)], fill=(220, 220, 220), width=1)
        d.line([(0, y), (W, y)], fill=(220, 220, 220), width=1)

    # 対角線（中心割り出し用）
    d.line([(0, 0), (W - 1, H - 1)], fill=(230, 200, 200), width=1)
    d.line([(W - 1, 0), (0, H - 1)], fill=(230, 200, 200), width=1)

    fnt = load_font(max(14, W // 45))
    small = load_font(max(11, W // 60))

    tick_len = max(12, W // 40)
    # 四辺の目盛り（0-100%）
    for i in range(0, 101, 10):
        x = round((W - 1) * i / 100)
        y = round((H - 1) * i / 100)
        # 上辺・下辺（横方向 = 幅%）
        d.line([(x, 0), (x, tick_len)], fill="black", width=2)
        d.line([(x, H - 1), (x, H - 1 - tick_len)], fill="black", width=2)
        # 左辺・右辺（縦方向 = 高さ%）
        d.line([(0, y), (tick_len, y)], fill="black", width=2)
        d.line([(W - 1, y), (W - 1 - tick_len, y)], fill="black", width=2)
        # ラベル（上辺と左辺のみ）
        d.text((x + 3, tick_len + 2), f"{i}", font=small, fill=(0, 0, 180))
        d.text((tick_len + 3, y + 2), f"{i}", font=small, fill=(180, 0, 0))

    # 外枠（画像の物理的な端を示す赤い2px枠）
    d.rectangle([0, 0, W - 1, H - 1], outline=(220, 0, 0), width=2)

    # 中央十字
    cx, cy = W // 2, H // 2
    d.line([(cx, cy - 30), (cx, cy + 30)], fill=(0, 150, 0), width=2)
    d.line([(cx - 30, cy), (cx + 30, cy)], fill=(0, 150, 0), width=2)
    d.text((cx + 6, cy + 6), "CENTER", font=small, fill=(0, 130, 0))

    # 角ラベル
    off = tick_len + 4
    d.text((off, off), "TL", font=fnt, fill="black")
    d.text((W - off - 40, off), "TR", font=fnt, fill="black")
    d.text((off, H - off - 24), "BL", font=fnt, fill="black")
    d.text((W - off - 40, H - off - 24), "BR", font=fnt, fill="black")

    # 中央のサイズ表記
    title = f"{label}\n{W}x{H}px  ratio {W}:{H}"
    d.multiline_text((cx, cy - 90), title, font=fnt, fill="black",
                     anchor="ma", align="center", spacing=6)

    img.save(out)
    print(f"wrote {out} ({W}x{H})")

if __name__ == "__main__":
    outdir = sys.argv[1]
    draw_ruler(1200, 1600, f"{outdir}/ruler-portrait.png", "PORTRAIT 3:4")
    draw_ruler(1600, 1200, f"{outdir}/ruler-landscape.png", "LANDSCAPE 4:3")
    draw_ruler(1400, 1400, f"{outdir}/ruler-square.png", "SQUARE 1:1")
