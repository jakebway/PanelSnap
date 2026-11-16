#!/usr/bin/env python3
"""Regenerates the PanelSnap app icon (comic-book style). Needs Pillow: pip install pillow"""
from PIL import Image, ImageDraw, ImageFont
import math, random, os

OUT = os.path.join(os.path.dirname(__file__), "..", "PanelSnap", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
S = 2048
INK = (14, 12, 22)
img = Image.new("RGB", (S, S), (255, 214, 38))
d = ImageDraw.Draw(img)

step = 64
for gy in range(-1, S // step + 2):
    for gx in range(-1, S // step + 2):
        cx = gx * step + (step // 2 if gy % 2 else 0)
        cy = gy * step
        t = (cx * 0.45 + cy * 0.55) / S
        r = 4 + 26 * max(0, min(1, t)) ** 1.1
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(235, 52, 52))

cx, cy = S // 2, int(S * 0.50)
def burst(ro, ri, points, rot=0.0, jitter=0.0, seed=3):
    rnd = random.Random(seed)
    pts = []
    for i in range(points * 2):
        ang = rot + math.pi * i / points
        base = ro if i % 2 == 0 else ri
        rr = base * (1 + rnd.uniform(-jitter, jitter))
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    return pts

off = 36
d.polygon([(x + off, y + off) for x, y in burst(800, 500, 13, -0.2, 0.07)], fill=INK)
d.polygon(burst(800, 500, 13, -0.2, 0.07), fill=INK)
d.polygon(burst(762, 468, 13, -0.2, 0.07), fill=(255, 255, 255))
d.polygon(burst(710, 430, 13, -0.2, 0.07), fill=(255, 92, 40))
d.polygon(burst(540, 345, 13, -0.2, 0.05, seed=9), fill=(255, 196, 40))

font = ImageFont.truetype("/usr/share/fonts/truetype/freefont/FreeSansBoldOblique.ttf", 450)
word = "SNAP!"
layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ld = ImageDraw.Draw(layer)
bbox = ld.textbbox((0, 0), word, font=font, stroke_width=34)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
pos = (cx - tw // 2 - bbox[0], cy - th // 2 - bbox[1] - 10)
ld.text((pos[0] + 22, pos[1] + 26), word, font=font, fill=INK, stroke_width=34, stroke_fill=INK)
ld.text(pos, word, font=font, fill=(255, 255, 255), stroke_width=34, stroke_fill=INK)
layer = layer.rotate(9, resample=Image.BICUBIC, center=(cx, cy))
img.paste(layer, (0, 0), layer)

d = ImageDraw.Draw(img)
for (x0, y0, x1, y1) in [(250, 330, 400, 250), (1650, 250, 1800, 330), (270, 1760, 420, 1830), (1630, 1830, 1780, 1760)]:
    d.line((x0, y0, x1, y1), fill=INK, width=34)

# Full-bleed square ink edge: iOS's own rounded mask supplies the curve, so nothing is inset
# and nothing can look misaligned with the icon corners.
d.rectangle((0, 0, S - 1, S - 1), outline=INK, width=70)

img.resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)
