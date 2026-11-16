#!/usr/bin/env python3
"""Builds the browser's ad-block lists (WebKit content-blocker JSON) from EasyList, which is published on GitHub
under the GPLv3 / CC BY-SA 3.0. Output: PanelSnap/Resources/shield-*.json. Re-run any time to refresh the lists:

    python3 Scripts/build_adblock.py

Only conservative rules are converted (domain blocks, plain URL fragments and simple element hiding), so a bad
rule can never take a page or a download down with it.
"""
import json, os, re, sys, urllib.request

BASE = "https://raw.githubusercontent.com/easylist/easylist/master/"
SOURCES = [
    "easylist/easylist_adservers.txt",
    "easylist/easylist_thirdparty.txt",
    "easylist/easylist_general_block.txt",
    "easylist/easylist_general_hide.txt",
    "easyprivacy/easyprivacy_trackingservers.txt",
    "easyprivacy/easyprivacy_trackingservers_international.txt",
    "easyprivacy/easyprivacy_general.txt",
    "easyprivacy/easyprivacy_thirdparty.txt",
]
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "PanelSnap", "Resources")
PER_LIST = 9000

TYPE = {"script": "script", "image": "image", "stylesheet": "style-sheet", "xmlhttprequest": "raw",
        "subdocument": "document", "media": "media", "font": "font", "popup": "popup", "ping": "ping", "other": "other",
        "object": "media"}

def fetch(path):
    with urllib.request.urlopen(BASE + path, timeout=60) as r:
        return r.read().decode("utf-8", "ignore").splitlines()

DOMAIN = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")

def esc(s):
    return re.sub(r"([.+?(){}\[\]\\^$|*])", r"\\\1", s)

def convert_net(line):
    """One EasyList network rule -> a content-blocker rule, or None if it is not safe/simple."""
    if line.startswith("@@") or "$" in line and line.count("$") > 1:
        return None
    opts = []
    if "$" in line:
        line, o = line.rsplit("$", 1)
        opts = o.split(",")
    third = False
    types = []
    for o in opts:
        if o == "third-party":
            third = True
        elif o in TYPE:
            types.append(TYPE[o])
        else:
            return None                   # negations, domain=, csp, redirect ... are skipped on purpose
    if not line or line.startswith("/") and line.endswith("/"):
        return None                       # regex rules
    m = re.match(r"^\|\|([^/^*|?:]+)(\^|/|$)(.*)$", line)
    if m:
        dom, sep, rest = m.groups()
        dom = dom.lower()
        if not DOMAIN.match(dom):
            return None
        pat = r"^[^:]+://+([^:/]+\.)?" + esc(dom)
        if sep == "/":
            tail = "/" + rest
            if re.search(r"[*^|]", tail) or len(tail) < 4:
                return None
            pat += r"(:[0-9]+)?" + esc(tail)
        elif rest:
            return None
        else:
            pat += r"[/:]"
    else:
        frag = line.lstrip("|")
        if len(frag) < 6 or re.search(r"[*^|]", frag) or not re.match(r"^[\x21-\x7e]+$", frag):
            return None
        pat = esc(frag)
    trig = {"url-filter": pat}
    if third:
        trig["load-type"] = ["third-party"]
    if types:
        trig["resource-type"] = sorted(set(types))
    return {"trigger": trig, "action": {"type": "block"}}

HIDE = re.compile(r"^[#.][A-Za-z0-9_-]+(\[[A-Za-z-]+([\^$*]?=\"[A-Za-z0-9_ ./:-]*\")?\])?$")

def convert_hide(line):
    if not line.startswith("##"):
        return None
    sel = line[2:]
    return sel if HIDE.match(sel) else None

def main():
    net, seen, hide = [], set(), []
    for src in SOURCES:
        try:
            lines = fetch(src)
        except Exception as e:
            print("skip", src, e, file=sys.stderr)
            continue
        n0, h0 = len(net), len(hide)
        for ln in lines:
            ln = ln.strip()
            if not ln or ln.startswith("!") or ln.startswith("["):
                continue
            if "##" in ln or "#@#" in ln or "#?#" in ln or "#$#" in ln:
                s = convert_hide(ln)
                if s and s not in seen:
                    seen.add(s)
                    hide.append(s)
                continue
            r = convert_net(ln)
            if r:
                key = json.dumps(r, sort_keys=True)
                if key not in seen:
                    seen.add(key)
                    net.append(r)
        print(f"{src}: +{len(net)-n0} blocks, +{len(hide)-h0} hides")

    # Hand-written rules that matter most for comic download sites: pop-ups and pop-unders.
    extra = [
        {"trigger": {"url-filter": ".*", "resource-type": ["popup"]}, "action": {"type": "block"}},
        *[{"trigger": {"url-filter": pat, "resource-type": ["script", "document", "popup"], "load-type": ["third-party"]},
           "action": {"type": "block"}} for pat in (r"[/.-]popunders?[/.-]", r"[/.-]popups?[/.-]", r"[/.-]clickunder[/.-]")],
        *[{"trigger": {"url-filter": pat, "resource-type": ["script"], "load-type": ["third-party"]},
           "action": {"type": "block"}} for pat in (r"/adserver", r"/ads/[^/]*\.js", r"/banners?/[^/]*\.js")],
    ]
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.startswith("shield-"):
            os.remove(os.path.join(OUT, f))
    allnet = extra + net
    for i in range(0, len(allnet), PER_LIST):
        chunk = allnet[i:i + PER_LIST]
        with open(os.path.join(OUT, f"shield-net-{i // PER_LIST + 1}.json"), "w") as f:
            json.dump(chunk, f, separators=(",", ":"))
    rules = []
    for i in range(0, len(hide), 25):
        rules.append({"trigger": {"url-filter": ".*"},
                      "action": {"type": "css-display-none", "selector": ", ".join(hide[i:i + 25])}})
    with open(os.path.join(OUT, "shield-hide.json"), "w") as f:
        json.dump(rules, f, separators=(",", ":"))
    print("network rules:", len(allnet), " element-hiding selectors:", len(hide))

main()
