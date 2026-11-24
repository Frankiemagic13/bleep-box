"""Make the PNG/ICO images for the Stream Deck plugin and the app.
Run: python3 tools/make_icons.py
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
IMGS = ROOT / "streamdeck" / "com.frankievalletech.bleepbox.sdPlugin" / "imgs"
ACCENT = (255, 138, 61, 255)
RED = (229, 72, 77, 255)
DARK = (18, 20, 24, 255)
WHITE = (255, 255, 255, 255)
WAVE = [(3, 12), (6, 12), (9, 5), (15, 19), (18, 12), (21, 12)]


def wave(draw, box, color, width):
    x0, y0, size = box
    pts = [(x0 + x / 24 * size, y0 + y / 24 * size) for x, y in WAVE]
    draw.line(pts, fill=color, width=width, joint="curve")
    r = width / 2
    for p in (pts[0], pts[-1]):
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=color)


def font(size):
    for name in ("DejaVuSans-Bold.ttf", "Arial Bold.ttf", "arialbd.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def key(size, bleeping):
    s = size * 4
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if bleeping:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.14, fill=RED)
        fg = WHITE
    else:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.14, fill=DARK)
        d.rounded_rectangle([s * 0.04, s * 0.04, s * 0.96, s * 0.96], radius=s * 0.11, outline=ACCENT, width=int(s * 0.03))
        fg = ACCENT
    wave(d, (s * 0.22, s * 0.14, s * 0.56), fg, int(s * 0.055))
    label = "BLEEPING" if bleeping else "BLEEP"
    f = font(int(s * (0.13 if bleeping else 0.15)))
    w = d.textlength(label, font=f)
    d.text(((s - w) / 2, s * 0.70), label, font=f, fill=fg)
    return im.resize((size, size), Image.LANCZOS)


def plugin_icon(size):
    s = size * 4
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=s * 0.22, fill=ACCENT)
    wave(d, (s * 0.15, s * 0.15, s * 0.7), (21, 23, 27, 255), int(s * 0.08))
    return im.resize((size, size), Image.LANCZOS)


def mono_icon(size):
    s = size * 4
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    wave(d, (0, 0, s), WHITE, int(s * 0.11))
    return im.resize((size, size), Image.LANCZOS)


def main():
    IMGS.mkdir(parents=True, exist_ok=True)
    plugin_icon(256).save(IMGS / "plugin.png")
    plugin_icon(512).save(IMGS / "plugin@2x.png")
    mono_icon(28).save(IMGS / "category.png")
    mono_icon(56).save(IMGS / "category@2x.png")
    mono_icon(20).save(IMGS / "action.png")
    mono_icon(40).save(IMGS / "action@2x.png")
    key(72, False).save(IMGS / "key-ready.png")
    key(144, False).save(IMGS / "key-ready@2x.png")
    key(72, True).save(IMGS / "key-bleeping.png")
    key(144, True).save(IMGS / "key-bleeping@2x.png")
    plugin_icon(256).save(ROOT / "app" / "app.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icons written")


if __name__ == "__main__":
    main()
