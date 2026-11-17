#!/usr/bin/env python3
"""Regenerates the PanelSnap app icon: red manga speed lines, one tilted comic book page made of abstract, brightly coloured panels.
Needs Pillow: pip install pillow"""
from PIL import Image, ImageDraw
import math, os

OUT = os.path.join(os.path.dirname(__file__), "..", "PanelSnap", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
S = 2048
INK = (14, 10, 16)
RED = (226, 28, 36)
SOFT_RED = (206, 20, 30)      # speed lines: only a hint darker than the background
YELLOW = (255, 208, 20)
CYAN, PINK, LIME, VIOLET = (0, 190, 255), (255, 40, 150), (120, 220, 40), (110, 70, 255)   # one bright colour per panel

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
# A tall comic-book page with its panel layout, each panel a different bright colour.
BW, BH = 800, 1120
box = (cx - BW // 2, cy - BH // 2, cx + BW // 2, cy + BH // 2)
off = 44
ld.rounded_rectangle((box[0] + off, box[1] + off, box[2] + off, box[3] + off), radius=36, fill=INK)     # shadow
ld.rounded_rectangle(box, radius=36, fill=YELLOW)
m, gap = 104, 36
x0, y0, x1, y1 = box[0] + m, box[1] + m, box[2] - m, box[3] - m
h1 = int((y1 - y0) * 0.42)
h2 = int((y1 - y0) * 0.26)
midx = (x0 + x1) // 2
ld.rectangle((x0, y0, x1, y0 + h1), fill=CYAN)                                                   # wide panel
ld.rectangle((x0, y0 + h1 + gap, midx - gap // 2, y0 + h1 + gap + h2), fill=PINK)                # two small
ld.rectangle((midx + gap // 2, y0 + h1 + gap, x1, y0 + h1 + gap + h2), fill=LIME)
ld.rectangle((x0, y0 + h1 + h2 + 2 * gap, x1, y1), fill=VIOLET)                                    # wide bottom

layer = layer.rotate(-7, resample=Image.BICUBIC, center=(cx, cy))
img.paste(layer, (0, 0), layer)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
