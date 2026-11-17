#!/usr/bin/env python3
"""Regenerates the PanelSnap app icon: red manga speed lines, one tilted yellow comic book with a spine and page edges, one bolt.
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
# bolt on the cover
mx = box[0] + sp + (BW - sp) // 2
bolt = [(mx + 80, box[1] + 150), (mx - 220, cy + 70), (mx - 20, cy + 70), (mx - 100, box[3] - 150),
        (mx + 230, cy - 90), (mx + 30, cy - 90)]
ld.polygon([(x + 20, y + 20) for x, y in bolt], fill=INK)
ld.polygon(bolt, fill=(255, 255, 255), outline=INK, width=14)

layer = layer.rotate(-7, resample=Image.BICUBIC, center=(cx, cy))
img.paste(layer, (0, 0), layer)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
