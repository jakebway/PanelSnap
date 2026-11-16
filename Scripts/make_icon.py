#!/usr/bin/env python3
"""Regenerates the PanelSnap app icon: red manga speed lines, one tilted yellow comic panel, one bolt.
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
PW, PH = 1000, 1100
box = (cx - PW // 2, cy - PH // 2, cx + PW // 2, cy + PH // 2)
off = 56
ld.rounded_rectangle((box[0] + off, box[1] + off, box[2] + off, box[3] + off), radius=40, fill=INK)
ld.rounded_rectangle(box, radius=40, fill=YELLOW, outline=INK, width=44)

bolt = [(cx + 90, box[1] + 120), (cx - 230, cy + 60), (cx - 20, cy + 60), (cx - 110, box[3] - 120),
        (cx + 250, cy - 90), (cx + 30, cy - 90)]
ld.polygon([(x + 22, y + 22) for x, y in bolt], fill=INK)
ld.polygon(bolt, fill=(255, 255, 255), outline=INK, width=14)

layer = layer.rotate(-7, resample=Image.BICUBIC, center=(cx, cy))
img.paste(layer, (0, 0), layer)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
