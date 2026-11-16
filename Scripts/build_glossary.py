#!/usr/bin/env python3
"""Builds PanelSnap/Resources/Characters.json: the built-in "who's who" the Companion uses with no internet.

Sources (both open, no API keys):
  * akabab/superhero-api  (MIT)         - bios, aliases, affiliations, relatives, portraits
  * FiveThirtyEight comic-characters (CC BY 4.0) - Marvel/DC wikia character lists with appearance counts

Usage: build_glossary.py <superhero-api all.json> <marvel-wikia-data.csv> <dc-wikia-data.csv> <out.json>
"""
import csv, json, re, sys

sh_path, marvel_csv, dc_csv, out_path = sys.argv[1:5]

def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())

def trim_list(text, limit):
    text = (text or "").strip()
    if text in ("", "-", "None", "null"):
        return ""
    text = re.sub(r"\s+", " ", text)
    if len(text) <= limit:
        return text
    cut = text[:limit]
    m = max(cut.rfind(","), cut.rfind(";"))
    return (cut[:m] if m > limit // 2 else cut).rstrip(" ,;") + "…"

PUBLISHERS = {"Marvel Comics": "Marvel", "DC Comics": "DC", "Dark Horse Comics": "Dark Horse",
              "Image Comics": "Image", "IDW Publishing": "IDW", "Wildstorm": "WildStorm",
              "Icon Comics": "Icon", "Shueisha": "Shueisha"}

entries = {}   # key: normalized hero name

def parse_fte(path, pub, host):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            name = r["name"].replace("\\", "").strip()
            try:
                ap = int(r["APPEARANCES"]) if r["APPEARANCES"] else 0
            except ValueError:
                ap = 0
            m = re.match(r"^(.*?)\s*\((.*)\)\s*$", name)
            hero, real = (m.group(1).strip(), m.group(2).strip()) if m else (name, "")
            if real.lower().startswith("earth-") or "earth-" in real.lower():
                real = ""
            slug = r["urlslug"].replace("\\/", "/").replace("\\", "")
            if not slug.startswith("/wiki/"):
                slug = "/wiki" + slug
            year = int(r["Year"]) if r.get("Year") and r["Year"].isdigit() else 0
            rows.append(dict(hero=hero, real=real, ap=ap, slug=slug, year=year, first=r["FIRST APPEARANCE"], pub=pub, host=host))
    rows.sort(key=lambda x: -x["ap"])
    return rows

fte_rows = parse_fte(marvel_csv, "Marvel", "marvel.fandom.com") + parse_fte(dc_csv, "DC", "dc.fandom.com")

# keep the well-known ones (enough appearances), at most one per hero name
for r in sorted(fte_rows, key=lambda x: -x["ap"]):
    if r["ap"] < 45:
        continue
    k = norm(r["hero"])
    if not k or k in entries:
        continue
    entries[k] = {
        "n": r["hero"], "r": r["real"], "p": r["pub"], "ap": r["ap"], "y": r["year"],
        "w": "https://%s%s" % (r["host"], r["slug"]),
    }

# superhero-api: richer bios, merged by hero name or real name
sh = json.load(open(sh_path, encoding="utf-8"))
by_real = {norm(e["r"]): k for k, e in entries.items() if e["r"]}
for x in sh:
    bio, conn, work, img = x["biography"], x["connections"], x["work"], x["images"]
    pub = PUBLISHERS.get(bio.get("publisher") or "", None)
    k = norm(x["name"])
    full = bio.get("fullName") or ""
    fk = norm(full) if full not in ("", "-") else ""
    target = None
    if k in entries:
        target = k
    elif fk and fk in by_real:
        target = by_real[fk]
    elif fk and fk in entries:
        target = fk                       # the wikia lists the hero under the civilian name
    if target is None:
        if pub is None:
            continue                      # TV/film/other universes: not comics
        target = k
        entries[target] = {"n": x["name"], "r": "" if not fk else full, "p": pub, "ap": 0, "y": 0, "w": ""}
    e = entries[target]
    if norm(e["n"]) == fk and norm(x["name"]) != fk:
        e["r"] = e["n"]                   # e.g. "Wanda Maximoff" is really Scarlet Witch
        e["n"] = x["name"]
    if not e.get("r") and fk:
        e["r"] = full
    aliases = [a for a in bio.get("aliases", []) if a and a != "-" and norm(a) != norm(e["n"])][:5]
    if aliases:
        e["al"] = aliases
    fa = (bio.get("firstAppearance") or "").strip()
    if fa and fa != "-":
        e["fa"] = fa
    g = trim_list(conn.get("groupAffiliation"), 150)
    if g: e["g"] = g
    rel = trim_list(conn.get("relatives"), 170)
    if rel: e["rel"] = rel
    occ = trim_list(work.get("occupation"), 80)
    if occ: e["occ"] = occ
    e["img"] = img.get("md", "")

out = sorted(entries.values(), key=lambda e: (-e.get("ap", 0), e["n"]))
json.dump(out, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "characters ->", out_path)
