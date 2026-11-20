import sys, zipfile
from PIL import Image
out, src = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGB")
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    for i in range(1, 6):
        tmp = f"/tmp/uitest-page-{i}.jpg"
        im.save(tmp, quality=88)
        z.write(tmp, f"page{i:02d}.jpg")
