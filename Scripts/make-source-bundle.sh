#!/usr/bin/env bash
# Writes the app's source as a few plain-text files, so a chat that can only read GitHub files can see it all at once.
#   report/source/reader.txt : the reader and its gestures (the part that changes most)
#   report/source/all.txt    : every Swift file, the project spec, scripts and docs
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=report/source
mkdir -p "$OUT"

bundle() {
  local dest="$1"; shift
  : > "$dest"
  for f in "$@"; do
    [ -f "$f" ] || continue
    printf '\n===== %s =====\n' "$f" >> "$dest"
    cat "$f" >> "$dest"
  done
}

bundle "$OUT/reader.txt" ARCHITECTURE.md \
  PanelSnap/Views/ReaderView.swift PanelSnap/Views/ZoomLayer.swift PanelSnap/Views/PanelCanvas.swift \
  PanelSnap/Services/ReaderModel.swift PanelSnap/Services/PanelDetector.swift PanelSnap/Services/PanelCache.swift

# shellcheck disable=SC2046
bundle "$OUT/all.txt" ARCHITECTURE.md README.md project.yml project.lite.yml \
  $(git ls-files 'PanelSnap/*.swift' 'Scripts/*.sh' 'Scripts/*.py' 'Scripts/PanelCheck/*.swift' '.github/workflows/*.yml')
ls -l "$OUT"
