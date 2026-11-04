#!/usr/bin/env python3
"""Renders every SlopDrop icon from geometry in this file.

    python3 Assets/Source/icons.py        (needs Pillow and rsvg-convert)

Writes:
    Assets/Source/*.svg                          vector masters
    Assets/AppIcon.iconset/                      every size iconutil expects
    Assets/AppIcon.icns                          what build-app.sh ships
    Assets/AppIcon.png                           1024px, for docs and the web
    Assets/preview.png                           the whole set on one sheet
    Sources/SlopDrop/Resources/MenuBar*.png      template images, 1x and 2x

The mark: the AI sparkle with its lower half under a frosted glass card, the
way SlopDrop's Frost style treats a message. The menu bar reduces it to a
template glyph with three states: muting (sparkle sunk into the glass),
paused (sparkle in front of the glass) and disconnected (hollow sparkle).
"""
import io
import os
import struct
import subprocess
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SOURCE = os.path.join(ROOT, "Assets", "Source")
ICONSET = os.path.join(ROOT, "Assets", "AppIcon.iconset")
RESOURCES = os.path.join(ROOT, "Sources", "SlopDrop", "Resources")


# ------------------------------------------------------------------ geometry

# Apple's continuous-corner rounded rect, per corner, as (u, v) in units of
# the radius: u back along the incoming edge, v along the outgoing edge.
_CORNER = [
    ("C", (1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600)),
    ("L", (0.63149399, 0.07491100)),
    ("C", (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491100, 0.63149399)),
    ("L", (0.06549600, 0.66993427)),
    ("C", (0, 0.86840689), (0, 1.08849323), (0, 1.52866471)),
]
_START = (1.52866471, 0)


def squircle(x, y, w, h, r):
    corners = [
        ((x + w, y), (1, 0), (0, 1)),
        ((x + w, y + h), (0, 1), (-1, 0)),
        ((x, y + h), (-1, 0), (0, -1)),
        ((x, y), (0, -1), (1, 0)),
    ]

    def pt(corner, din, dout, uv):
        u, v = uv
        return (corner[0] - u * r * din[0] + v * r * dout[0],
                corner[1] - u * r * din[1] + v * r * dout[1])

    def f(p):
        return f"{p[0]:.3f},{p[1]:.3f}"

    c0, din0, dout0 = corners[0]
    d = [f"M{f(pt(c0, din0, dout0, _START))}"]
    for corner, din, dout in corners:
        d.append(f"L{f(pt(corner, din, dout, _START))}")
        for seg in _CORNER:
            if seg[0] == "C":
                d.append("C" + " ".join(f(pt(corner, din, dout, s)) for s in seg[1:]))
            else:
                d.append("L" + f(pt(corner, din, dout, seg[1])))
    d.append("Z")
    return " ".join(d)


def sparkle(cx, cy, rx, ry, waist, k1):
    """Four-point sparkle with concave sides. `waist` places each side's
    control points along the tip axes (smaller = thinner star); `k1` nudges
    them off the axis."""
    tips = [(0, -1), (1, 0), (0, 1), (-1, 0)]

    def P(x, y):
        return f"{cx + x:.3f},{cy + y:.3f}"

    d = []
    for i in range(4):
        a, b = tips[i], tips[(i + 1) % 4]
        A = (a[0] * rx, a[1] * ry)
        B = (b[0] * rx, b[1] * ry)
        c1 = (A[0] * waist + b[0] * k1 * rx, A[1] * waist + b[1] * k1 * ry)
        c2 = (B[0] * waist + a[0] * k1 * rx, B[1] * waist + a[1] * k1 * ry)
        if i == 0:
            d.append(f"M{P(*A)}")
        d.append(f"C{P(*c1)} {P(*c2)} {P(*B)}")
    d.append("Z")
    return " ".join(d)


# ------------------------------------------------------------------ app icon

def app_icon(detail="full"):
    """detail: "full" (128pt and up), "small" (32pt: no message line),
    "tiny" (16pt: sparkle and glass only)."""
    body = squircle(100, 100, 824, 824, 185.4)  # macOS grid: 824 body, 100 margin
    big = sparkle(512, 470, 290, 312, waist=0.28, k1=0.05)
    small = sparkle(754, 258, 64, 69, waist=0.28, k1=0.05)
    card = squircle(164, 566, 696, 276, 84)

    scene = f"""<rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#bloom)"/>
  <path d="{big}" fill="url(#spark)"/>"""
    if detail != "tiny":
        scene += f'\n  <path d="{small}" fill="url(#spark)"/>'

    sender = ""
    if detail == "full":
        avatar = squircle(206, 606, 60, 60, 16)
        sender = f"""
  <path d="{avatar}" fill="#FFFFFF" fill-opacity="0.94"/>
  <rect x="288" y="616" width="124" height="18" rx="9" fill="#FFFFFF" fill-opacity="0.94"/>
  <rect x="288" y="645" width="64" height="12" rx="6" fill="#FFFFFF" fill-opacity="0.55"/>"""

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <clipPath id="body"><path d="{body}"/></clipPath>
  <clipPath id="card"><path d="{card}"/></clipPath>
  <linearGradient id="bg" x1="0.3" y1="0" x2="0.7" y2="1">
    <stop offset="0" stop-color="#A274FF"/>
    <stop offset="0.55" stop-color="#7240E6"/>
    <stop offset="1" stop-color="#4519AE"/>
  </linearGradient>
  <radialGradient id="bloom" cx="512" cy="440" r="380" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#F4E8FF" stop-opacity="0.55"/>
    <stop offset="0.45" stop-color="#E7D3FF" stop-opacity="0.16"/>
    <stop offset="1" stop-color="#E7D3FF" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="spark" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF"/>
    <stop offset="1" stop-color="#F1E6FF"/>
  </linearGradient>
  <linearGradient id="tint" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.28"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.10"/>
  </linearGradient>
  <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.95"/>
    <stop offset="0.3" stop-color="#FFFFFF" stop-opacity="0.30"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.55"/>
  </linearGradient>
  <filter id="frost" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="20"/>
    <feColorMatrix type="saturate" values="0.6"/>
  </filter>
  <filter id="shadow" x="-30%" y="-40%" width="160%" height="200%">
    <feGaussianBlur stdDeviation="26"/>
  </filter>
</defs>
<g clip-path="url(#body)">
  {scene}
  <path d="{card}" fill="#1B0950" fill-opacity="0.30" filter="url(#shadow)" transform="translate(0,24)"/>
  <g clip-path="url(#card)">
    <g filter="url(#frost)">{scene}</g>
    <rect width="1024" height="1024" fill="url(#tint)"/>
  </g>
  <path d="{card}" fill="none" stroke="url(#rim)" stroke-width="4"/>{sender}
</g>
</svg>
"""


# ------------------------------------------------------------------ menu bar
# 36-unit canvas = an 18pt status item image at 2x. Template images: black
# and alpha only; AppKit tints them for light, dark and highlighted bars.

MB = dict(cx=18, cy=16.2, rx=13.8, ry=14.0, waist=0.40, k1=0.07)
MB_CARD = (3.0, 18.4, 30.0, 15.4, 5.2)
ROUND_TIPS = 'stroke="#000" stroke-width="0.8" stroke-linejoin="round"'


def _mb(content):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36">
{content}
</svg>
"""


def _mb_parts():
    s = sparkle(MB["cx"], MB["cy"], MB["rx"], MB["ry"], waist=MB["waist"], k1=MB["k1"])
    return s, squircle(*MB_CARD)


def menubar_muting():
    """Sparkle sunk into the glass: crisp above, frosted inside."""
    s, card = _mb_parts()
    x, y, w, h, r = MB_CARD
    gap = 1.2
    clearance = squircle(x - gap, y - gap, w + 2 * gap, h + 2 * gap, r + gap)
    return _mb(f"""<defs>
  <clipPath id="in"><path d="{card}"/></clipPath>
  <mask id="out" maskUnits="userSpaceOnUse" x="0" y="0" width="36" height="36">
    <rect width="36" height="36" fill="#fff"/><path d="{clearance}" fill="#000"/>
  </mask>
</defs>
<path d="{s}" fill="#000" {ROUND_TIPS} mask="url(#out)"/>
<path d="{card}" fill="#000" fill-opacity="0.34"/>
<path d="{s}" fill="#000" fill-opacity="0.55" clip-path="url(#in)"/>""")


def menubar_paused():
    """Muting off: the sparkle stands in front of the glass."""
    s, card = _mb_parts()
    return _mb(f"""<defs>
  <mask id="halo" maskUnits="userSpaceOnUse" x="0" y="0" width="36" height="36">
    <rect width="36" height="36" fill="#fff"/>
    <path d="{s}" fill="#000" stroke="#000" stroke-width="3.6" stroke-linejoin="round"/>
  </mask>
</defs>
<path d="{s}" fill="#000" {ROUND_TIPS}/>
<path d="{card}" fill="#000" fill-opacity="0.4" mask="url(#halo)"/>""")


def menubar_disconnected():
    """Not attached to Slack: a hollow sparkle over faint glass."""
    s, card = _mb_parts()
    return _mb(f"""<defs>
  <mask id="halo" maskUnits="userSpaceOnUse" x="0" y="0" width="36" height="36">
    <rect width="36" height="36" fill="#fff"/>
    <path d="{s}" fill="#000" stroke="#000" stroke-width="3.6" stroke-linejoin="round"/>
  </mask>
</defs>
<path d="{s}" fill="none" stroke="#000" stroke-width="2.1" stroke-linejoin="round"/>
<path d="{card}" fill="#000" fill-opacity="0.22" mask="url(#halo)"/>""")


# ------------------------------------------------------------------ output

def rasterize(svg_text, size):
    out = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), "-f", "png"],
        input=svg_text.encode(), capture_output=True, check=True,
    ).stdout
    return Image.open(io.BytesIO(out)).convert("RGBA")


def png_bytes(image):
    buf = io.BytesIO()
    image.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def write_icns(path, entries):
    """entries: [(4-char type, png bytes)]"""
    chunks = b"".join(t.encode() + struct.pack(">I", 8 + len(d)) + d for t, d in entries)
    toc = b"TOC " + struct.pack(">I", 8 + 8 * len(entries)) + b"".join(
        t.encode() + struct.pack(">I", 8 + len(d)) for t, d in entries)
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(toc) + len(chunks)) + toc + chunks)


def main():
    os.makedirs(SOURCE, exist_ok=True)
    os.makedirs(ICONSET, exist_ok=True)
    os.makedirs(RESOURCES, exist_ok=True)

    masters = {
        "AppIcon.svg": app_icon("full"),
        "AppIcon-32pt.svg": app_icon("small"),
        "AppIcon-16pt.svg": app_icon("tiny"),
        "MenuBarMuting.svg": menubar_muting(),
        "MenuBarPaused.svg": menubar_paused(),
        "MenuBarDisconnected.svg": menubar_disconnected(),
    }
    for name, text in masters.items():
        with open(os.path.join(SOURCE, name), "w") as f:
            f.write(text)

    def art(points):
        return masters["AppIcon-16pt.svg"] if points <= 16 else (
            masters["AppIcon-32pt.svg"] if points <= 32 else masters["AppIcon.svg"])

    # iconset: (points, scale)
    rendered = {}
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            image = rasterize(art(points), px)
            rendered[(points, scale)] = png_bytes(image)
            suffix = "" if scale == 1 else "@2x"
            image.save(os.path.join(ICONSET, f"icon_{points}x{points}{suffix}.png"), optimize=True)

    write_icns(os.path.join(ROOT, "Assets", "AppIcon.icns"), [
        ("icp4", rendered[(16, 1)]),
        ("ic11", rendered[(16, 2)]),
        ("icp5", rendered[(32, 1)]),
        ("ic12", rendered[(32, 2)]),
        ("ic07", rendered[(128, 1)]),
        ("ic13", rendered[(128, 2)]),
        ("ic08", rendered[(256, 1)]),
        ("ic14", rendered[(256, 2)]),
        ("ic09", rendered[(512, 1)]),
        ("ic10", rendered[(512, 2)]),
    ])
    rasterize(masters["AppIcon.svg"], 1024).save(os.path.join(ROOT, "Assets", "AppIcon.png"), optimize=True)

    for name in ("MenuBarMuting", "MenuBarPaused", "MenuBarDisconnected"):
        svg = masters[f"{name}.svg"]
        rasterize(svg, 18).save(os.path.join(RESOURCES, f"{name}.png"), optimize=True)
        rasterize(svg, 36).save(os.path.join(RESOURCES, f"{name}@2x.png"), optimize=True)

    preview(os.path.join(ROOT, "Assets", "preview.png"))
    print("rendered icons into", ROOT)


def _font(weight, size):
    from PIL import ImageFont
    for path in (f"/usr/share/fonts/opentype/inter/Inter-{weight}.otf",
                 "/System/Library/Fonts/SFNS.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size=size)


def preview(path):
    """One sheet: the icon, its small sizes on light and dark, and the
    menu bar states at 2x zoom and at actual Retina size."""
    from PIL import ImageDraw, ImageFilter
    W, H = 1600, 1150
    sheet = Image.new("RGB", (W, H), "#F4EEF0")
    d = ImageDraw.Draw(sheet)

    icon = Image.open(os.path.join(ROOT, "Assets", "AppIcon.png")).convert("RGBA")
    hero = icon.resize((520, 520), Image.LANCZOS)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow = Image.new("RGBA", hero.size, (60, 20, 90, 255))
    shadow.putalpha(hero.split()[3].point(lambda v: int(v * 0.35)))
    glow.paste(shadow, (60, 70), shadow)
    glow = glow.filter(ImageFilter.GaussianBlur(18))
    sheet.paste(glow, (0, 0), glow)
    sheet.paste(hero, (60, 50), hero)
    d.text((640, 120), "SlopDrop", font=_font("SemiBold", 64), fill="#2E1E2A")
    d.text((642, 205), "The AI sparkle, half under frosted glass.", font=_font("Regular", 26), fill="#7A6571")

    sizes = [(64, "icon_128x128.png"), (32, "icon_32x32@2x.png"), (16, "icon_16x16@2x.png")]
    for i, (bg, ink) in enumerate((("#ECE7EA", "#6B5A64"), ("#1F1B1E", "#A99BA3"))):
        x0, y0 = 640 + i * 470, 330
        d.rounded_rectangle([x0, y0, x0 + 440, y0 + 230], radius=22, fill=bg)
        x = x0 + 24
        for points, name in sizes:
            im = Image.open(os.path.join(ICONSET, name)).convert("RGBA")
            px = points * 2
            sheet.paste(im, (x, y0 + 30 + (128 - px) // 2), im)
            d.text((x + px // 2, y0 + 190), f"{points}pt", font=_font("Medium", 18), fill=ink, anchor="mm")
            x += px + 50

    d.text((60, 640), "Menu bar", font=_font("SemiBold", 30), fill="#2E1E2A")
    states = [("MenuBarMuting", "Muting"), ("MenuBarPaused", "Paused"), ("MenuBarDisconnected", "Not connected")]
    y = 700
    for bar, ink, sub in (("#EAE6EB", (20, 20, 20), "#6B5A64"), ("#2A2629", (245, 245, 245), "#A99BA3")):
        d.rounded_rectangle([60, y, W - 60, y + 190], radius=22, fill=bar)
        x = 110
        for name, label in states:
            alpha = Image.open(os.path.join(RESOURCES, f"{name}@2x.png")).split()[3]
            for zoom, px, (tx, ty) in ((True, 72, (x, y + 28)), (False, 36, (900 + states.index((name, label)) * 70, y + 46))):
                a = alpha.resize((px, px), Image.NEAREST) if zoom else alpha
                tile = Image.new("RGBA", a.size, ink + (255,))
                tile.putalpha(a)
                sheet.paste(tile, (tx, ty), tile)
            d.text((x + 36, y + 128), label, font=_font("Medium", 18), fill=sub, anchor="mm")
            x += 260
        d.text((1130, y + 64), "Wed Nov 4  3:42 PM", font=_font("Medium", 26), fill=ink, anchor="lm")
        d.text((900, y + 128), "actual size, Retina", font=_font("Regular", 16), fill=sub)
        y += 220
    sheet.save(path, optimize=True)


if __name__ == "__main__":
    sys.exit(main())
