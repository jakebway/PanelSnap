# PanelSnap

A clean, iOS-style comic reader that **snaps from panel to panel** so comics are easy to read on a phone, with a built-in **Companion** that looks up who's who, the series, creators and story arc for whatever you're reading.

Built for iPhone (including the foldable "Duo": on the wide inner screen the Companion docks beside the comic).

## Get the app on your iPhone (no computer needed)

1. Open this repo on GitHub → **Actions** tab → **Build IPA** → **Run workflow** → green **Run workflow** button.
2. Wait ~6–10 minutes until the run shows a green check.
3. Go to the repo's **Releases** (right side of the main page), open the newest one, and tap **PanelSnap.ipa**.
4. Open the downloaded IPA with **FlareStore** (or your sideloader) to sign and install it.

Shortcut link that always points at the newest build:
`https://github.com/jakebway/PanelSnap/releases/latest/download/PanelSnap.ipa`

> If a build ever fails, open the failed run → the summary at the top shows the first errors. Copy and paste them to Claude.
> If only the optional RAR/7z libraries fail, the workflow automatically builds a **lite** version (CBZ/PDF/EPUB) so you still get an IPA.

## Using it

- **+** adds comics (CBZ, CBR, CB7, PDF, EPUB). Wrong file extension? It checks the real file type.
- **Tap the right/left side** of the screen: next / previous panel. **Swipe** works too. **Tap the middle** to show or hide the controls.
- **Pinch in** to see the whole page, **pinch out** to jump back into the panels.
- **Swipe up** (or tap ✨) to open the **Companion**.
- Manga: long-press a comic in the library → *Read right-to-left*. (Files tagged as manga in ComicInfo.xml switch automatically.)

## Organising your library

- **Shelves**: the chips under the top band. Tap `+` to make one; long-press a chip to rename or delete it (comics stay in your library).
- **Sort**: Recently read, Newest added, Title A–Z, or My order.
- **Organize**: select several comics, then move them to a shelf, mark read/unread or delete. Drag a comic onto another to set My order.
- Long-press any comic to rename it, move it to a shelf, mark it read, flip manga direction or delete it.

## Companion: where the info comes from

| Source | Needs a key? | Gives you |
| --- | --- | --- |
| Built-in guide (`Resources/Characters.json`, works offline) | no | ~1,700 Marvel/DC characters: real name, aliases, first appearance, teams, family. From the Superhero API (MIT) and FiveThirtyEight's comic-characters data (CC BY 4.0). Rebuild with `Scripts/build_glossary.py` |
| The comic file itself (`ComicInfo.xml`) | no | series, issue, summary, creators, characters, teams, arc |
| Grand Comics Database | no | credits, cast and synopses for many issues (CC BY-SA 4.0) |
| Marvel / DC fan wikis | no | issue synopsis (behind a spoiler shield), creators, who appears |
| Wikipedia, Open Library | no | series background, "who is this character?" |
| AniList | no | manga info and characters |

Nothing in the app needs an account or API key.

## How panel snapping works

Everything runs on-device, with no third-party code: the page is shrunk, the gutter colour (white, cream or black) is found, and the page is recursively cut along gutters (XY-cut) to get panels in reading order. Pages with diagonal or irregular panels fall back to connected-component analysis. Results are cached per comic. See `PanelSnap/Services/PanelDetector.swift`.

## Project layout

- `project.yml` – XcodeGen spec (the Xcode project is generated in CI)
- `project.lite.yml` – same, without RAR/7z (automatic fallback)
- `Scripts/build-ipa.sh` – builds the unsigned IPA
- `.github/workflows/build.yml` – the one-tap workflow
