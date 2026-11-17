#!/usr/bin/env python3
"""Regenerates the PanelSnap app icon: red manga speed lines, one tilted yellow comic book with a spine, staples, page edges and a cover of panels.
Needs Pillow: pip install pillow"""
from PIL import Image, ImageDraw
import math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "PanelSnap", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
S = 2048
INK = (14, 10, 16)
RED = (226, 28, 36)
SOFT_RED = (206, 20, 30)      # speed lines: only a hint darker than the background
YELLOW = (255, 208, 20)

img = Image.new("RGB", (S, S), RED)
d = ImageDraw.Draw(img)
cx, cy = S // 2, S // 2

n = 48
for i in range(n):
    a0 = 2 * math.pi * i / n
    a1 = a0 + math.pi / n
    R = S * 1.2
    d.polygon([(cx, cy), (cx + R * math.cos(a0), cy + R * math.sin(a0)), (cx + R * math.cos(a1), cy + R * math.sin(a1))], fill=SOFT_RED)

layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ld = ImageDraw.Draw(layer)
# A comic book: tall cover, a spine on the left with staples, and a block of pages showing on the right and bottom.
BW, BH = 800, 1120
box = (cx - BW // 2, cy - BH // 2, cx + BW // 2, cy + BH // 2)
CREAM = (250, 240, 214)
ORANGE = (240, 150, 20)
off = 56
ld.rounded_rectangle((box[0] + off + 30, box[1] + off + 30, box[2] + off + 30, box[3] + off + 30), radius=34, fill=INK)  # shadow
# pages
pg = 38
ld.rounded_rectangle((box[0] + 24, box[1] + 24, box[2] + pg, box[3] + pg), radius=30, fill=CREAM, outline=INK, width=30)
for k in range(1, 4):
    ld.line((box[2] + pg - 10 - k * 9, box[1] + 90, box[2] + pg - 10 - k * 9, box[3] - 40), fill=(205, 190, 160), width=6)
    ld.line((box[0] + 90, box[3] + pg - 10 - k * 9, box[2] - 40, box[3] + pg - 10 - k * 9), fill=(205, 190, 160), width=6)
# cover
ld.rounded_rectangle(box, radius=30, fill=YELLOW, outline=INK, width=40)
# spine
sp = 120
ld.rounded_rectangle((box[0], box[1], box[0] + sp, box[3]), radius=30, fill=ORANGE, outline=INK, width=40)
ld.rectangle((box[0] + sp - 40, box[1] + 40, box[0] + sp, box[3] - 40), fill=ORANGE)
ld.line((box[0] + sp, box[1] + 20, box[0] + sp, box[3] - 20), fill=INK, width=26)
for fy in (box[1] + 200, box[3] - 200):
    ld.rounded_rectangle((box[0] + 34, fy - 22, box[0] + sp - 30, fy + 22), radius=14, fill=(235, 235, 240), outline=INK, width=10)
# cover art: a masthead and a page of panels, so it reads as a comic book at a glance
fx0, fx1 = box[0] + sp + 56, box[2] - 56
fy0, fy1 = box[1] + 56, box[3] - 56
mast_h = 170
ld.rounded_rectangle((fx0, fy0, fx1, fy0 + mast_h), radius=18, fill=RED, outline=INK, width=22)
for k in range(3):                      # lettering strokes standing in for a title
    x = fx0 + 50 + k * 150
    ld.rounded_rectangle((x, fy0 + 52, x + 110, fy0 + mast_h - 52), radius=14, fill=(255, 255, 255))
gap = 26
py0 = fy0 + mast_h + gap
mid = py0 + (fy1 - py0) // 2
panels = [
    (fx0, py0, fx1, mid - gap // 2),                              # wide panel on top
    (fx0, mid + gap // 2, fx0 + (fx1 - fx0) // 2 - gap // 2, fy1),  # two below
    (fx0 + (fx1 - fx0) // 2 + gap // 2, mid + gap // 2, fx1, fy1),
]
SKY, PINK = (112, 196, 240), (250, 190, 200)
for pnl, col in zip(panels, (SKY, (255, 255, 255), PINK)):
    ld.rectangle(pnl, fill=col, outline=INK, width=22)
# one action burst in the big panel
bx, by = (panels[0][0] + panels[0][2]) // 2, (panels[0][1] + panels[0][3]) // 2
pts = []
for i in range(20):
    ang = math.pi * 2 * i / 20
    r = 118 if i % 2 == 0 else 62
    pts.append((bx + r * math.cos(ang), by + r * math.sin(ang)))
ld.polygon(pts, fill=YELLOW, outline=INK, width=10)

layer = layer.rotate(-7, resample=Image.BICUBIC, center=(cx, cy))
img.paste(layer, (0, 0), layer)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
