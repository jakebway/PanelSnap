#!/usr/bin/env bash
# Compiles the app for the iOS Simulator (full build, then the lite one if the RAR/7z packages fail) and writes
# a short report to report/ that anyone (including regular Claude, via GitHub) can read.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p report

build() {
  local spec="$1" log="$2"
  rm -rf build-sim PanelSnap.xcodeproj
  xcodegen generate --spec "$spec" || return 1
  xcodebuild \
    -project PanelSnap.xcodeproj -scheme PanelSnap -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build-sim \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

MODE=full RESULT=passed
if ! build project.yml report/build-full.log; then
  MODE=lite
  if ! build project.lite.yml report/build-lite.log; then RESULT=FAILED; fi
fi

LOG=report/build-$MODE.log
grep -E "error:|fatal error|could not resolve" "$LOG" | sort -u | head -60 > report/errors.txt || true
grep -E "warning:" "$LOG" | sed 's#^.*/PanelSnap/#PanelSnap/#' | sort -u | head -60 > report/warnings.txt || true
# keep the committed log small: only the tail
for f in report/build-*.log; do [ -f "$f" ] && tail -n 400 "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

{
  echo "# Simulator build: $RESULT"
  echo ""
  echo "- Branch: \`${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-local}}\`"
  echo "- Commit: \`${GITHUB_SHA:-unknown}\`"
  echo "- Build type: $MODE (lite = without the RAR/7z libraries)"
  echo "- Errors: $(grep -c . report/errors.txt)   Warnings: $(grep -c . report/warnings.txt)"
  echo ""
  if [ -s report/errors.txt ]; then echo "## Errors"; echo '```'; cat report/errors.txt; echo '```'; fi
  if [ -s report/warnings.txt ]; then echo "## Warnings"; echo '```'; cat report/warnings.txt; echo '```'; fi
} > report/status.md

cat report/status.md >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ "$RESULT" = passed ]
