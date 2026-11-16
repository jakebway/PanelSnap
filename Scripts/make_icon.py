#!/usr/bin/env python3
"""Regenerates the PanelSnap app icon: red manga speed lines, tilted comic panels, yellow snap brackets.
Needs Pillow: pip install pillow"""
from PIL import Image, ImageDraw, ImageFont
import math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "PanelSnap", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
S = 2048
INK = (14, 10, 16)
RED = (226, 28, 36)
DARK_RED = (150, 12, 24)
YELLOW = (255, 208, 20)
CREAM = (255, 246, 226)

img = Image.new("RGB", (S, S), RED)
d = ImageDraw.Draw(img)
cx, cy = S // 2, S // 2

# manga speed lines radiating from the middle
n = 72
for i in range(n):
    a0 = 2 * math.pi * i / n
    a1 = a0 + 2 * math.pi / n * (0.35 + 0.35 * ((i * 7) % 5) / 4)
    R = S * 1.2
    d.polygon([(cx, cy), (cx + R * math.cos(a0), cy + R * math.sin(a0)), (cx + R * math.cos(a1), cy + R * math.sin(a1))], fill=DARK_RED)

# halftone dots fading in from the corners
step = 58
for gy in range(-1, S // step + 2):
    for gx in range(-1, S // step + 2):
        px = gx * step + (step // 2 if gy % 2 else 0)
        py = gy * step
        dist = math.hypot(px - cx, py - cy) / (S * 0.72)
        r = max(0, (dist - 0.62)) * 70
        if r > 1:
            d.ellipse((px - r, py - r, px + r, py + r), fill=INK)

# tilted comic page with three panels
page = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pd = ImageDraw.Draw(page)
PW, PH = 1060, 1260
x0, y0 = cx - PW // 2, cy - PH // 2
def card(box, fill, w=26, off=30):
    a, b, c, e = box
    pd.rectangle((a + off, b + off, c + off, e + off), fill=INK)
    pd.rectangle(box, fill=fill, outline=INK, width=w)
card((x0, y0, x0 + PW, y0 + PH), CREAM, w=34, off=44)
g = 34  # gutter
inner = (x0 + 52, y0 + 52, x0 + PW - 52, y0 + PH - 52)
ix0, iy0, ix1, iy1 = inner
split_y = iy0 + int((iy1 - iy0) * 0.46)
split_x = ix0 + int((ix1 - ix0) * 0.5)

# top wide panel: yellow with sunburst
top = (ix0, iy0, ix1, split_y - g // 2)
pd.rectangle(top, fill=YELLOW, outline=INK, width=22)
tcx, tcy = (top[0] + top[2]) // 2, (top[1] + top[3]) // 2
rays = Image.new("RGBA", (S, S), (0, 0, 0, 0))
rd = ImageDraw.Draw(rays)
for i in range(28):
    a0 = 2 * math.pi * i / 28
    a1 = a0 + math.pi / 28
    rd.polygon([(tcx, tcy), (tcx + 900 * math.cos(a0), tcy + 900 * math.sin(a0)), (tcx + 900 * math.cos(a1), tcy + 900 * math.sin(a1))], fill=(255, 150, 20, 255))
clip = Image.new("L", (S, S), 0)
ImageDraw.Draw(clip).rectangle(top, fill=255)
page.paste(rays, (0, 0), Image.composite(rays.getchannel("A"), Image.new("L", (S, S), 0), clip))
pd.rectangle(top, outline=INK, width=22)
# lightning bolt
bolt = [(tcx - 40, top[1] + 30), (tcx + 120, top[1] + 30), (tcx + 20, tcy - 10), (tcx + 150, tcy - 10), (tcx - 90, top[3] - 30), (tcx - 20, tcy + 40), (tcx - 150, tcy + 40)]
pd.polygon([(x + 14, y + 14) for x, y in bolt], fill=INK)
pd.polygon(bolt, fill=(255, 255, 255), outline=INK)

# bottom-left: black panel with a white eye-glint
bl = (ix0, split_y + g // 2, split_x - g // 2, iy1)
pd.rectangle(bl, fill=INK, outline=INK, width=22)
bx, by = (bl[0] + bl[2]) // 2, (bl[1] + bl[3]) // 2
pd.ellipse((bx - 130, by - 130, bx + 130, by + 130), fill=RED, outline=CREAM, width=18)
pd.ellipse((bx - 40, by - 70, bx + 10, by - 20), fill=CREAM)

# bottom-right: halftone panel
br = (split_x + g // 2, split_y + g // 2, ix1, iy1)
pd.rectangle(br, fill=(255, 120, 130), outline=INK, width=22)
for yy in range(br[1] + 26, br[3] - 10, 44):
    for xx in range(br[0] + 26 + (22 if ((yy - br[1]) // 44) % 2 else 0), br[2] - 10, 44):
        rr = 3 + 11 * (yy - br[1]) / (br[3] - br[1])
        pd.ellipse((xx - rr, yy - rr, xx + rr, yy + rr), fill=RED)
pd.rectangle(br, outline=INK, width=22)

page = page.rotate(-7, resample=Image.BICUBIC, center=(cx, cy))
img.paste(page, (0, 0), page)

# yellow "snap" corner brackets around the whole page
d = ImageDraw.Draw(img)
def bracket(px, py, sx, sy, L=250, w=70):
    for col, extra in ((INK, 22), (YELLOW, 0)):
        ww = w + extra
        d.line((px, py, px + sx * L, py), fill=col, width=ww)
        d.line((px, py, px, py + sy * L), fill=col, width=ww)
m = 150
bracket(m, m, 1, 1)
bracket(S - m, m, -1, 1)
bracket(m, S - m, 1, -1)
bracket(S - m, S - m, -1, -1)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
