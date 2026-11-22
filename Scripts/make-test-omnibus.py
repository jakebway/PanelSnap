"""A fake omnibus for the simulator test: a cover, then three "issues", each opening with a title page that prints the
series, the issue number and the credits, followed by ordinary interior pages."""
import sys, zipfile
from PIL import Image, ImageDraw, ImageFont

out, page_src = sys.argv[1], sys.argv[2]
W, H = 1200, 1800

def font(size, bold=True):
    for p in ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"]:
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()

def centered(d, y, text, f, fill="white"):
    w = d.textlength(text, font=f)
    d.text(((W - w) / 2, y), text, font=f, fill=fill)

def cover():
    im = Image.new("RGB", (W, H), (20, 20, 60)); d = ImageDraw.Draw(im)
    centered(d, 500, "THE AMAZING", font(110)); centered(d, 640, "SPIDER-MAN", font(150))
    centered(d, 880, "OMNIBUS", font(120), "yellow"); centered(d, 1050, "VOLUME 1", font(80))
    return im

def issue_page(n, writer, artist):
    im = Image.new("RGB", (W, H), (240, 230, 200)); d = ImageDraw.Draw(im)
    centered(d, 260, "THE AMAZING SPIDER-MAN #%d" % n, font(92), "black")
    centered(d, 520, "WRITER: " + writer, font(52), "black")
    centered(d, 600, "ARTIST: " + artist, font(52), "black")
    centered(d, 680, "LETTERER: ART SIMEK", font(52), "black")
    centered(d, 760, "EDITOR: STAN LEE", font(52), "black")
    return im

def plain(n):
    im = Image.new("RGB", (W, H), (200, 220, 235)); d = ImageDraw.Draw(im)
    centered(d, 850, "page %d" % n, font(60), (90, 90, 120))
    return im
xml = """<?xml version="1.0"?>
<ComicInfo><Series>Amazing Spider-Man Omnibus</Series><Volume>1</Volume><Publisher>Marvel</Publisher><Year>2007</Year></ComicInfo>"""
pages = [cover()]
for n in (1, 2, 3):
    pages.append(issue_page(n, "STAN LEE", "STEVE DITKO"))
    for _ in range(11):
        pages.append(plain(len(pages) + 1))
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    z.writestr("ComicInfo.xml", xml)
    for i, im in enumerate(pages):
        tmp = "/tmp/omni-%03d.jpg" % i
        im.save(tmp, quality=85)
        z.write(tmp, "page%03d.jpg" % (i + 1))
print(len(pages), "pages")
