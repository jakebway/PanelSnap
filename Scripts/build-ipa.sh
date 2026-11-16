#!/usr/bin/env bash
# Builds an UNSIGNED PanelSnap.ipa. Tries the full build first (CBZ + CBR + CB7 + PDF + EPUB).
# If the optional RAR/7z libraries ever fail to compile, it automatically falls back to a
# "lite" build (CBZ + PDF + EPUB) so you ALWAYS get an IPA.
set -uo pipefail
cd "$(dirname "$0")/.."

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

build() {
  local spec="$1" log="$2"
  rm -rf build PanelSnap.xcodeproj
  echo "::group::XcodeGen ($spec)"
  xcodegen generate --spec "$spec" || { echo "::endgroup::"; return 1; }
  echo "::endgroup::"
  echo "::group::xcodebuild ($spec)"
  xcodebuild \
    -project PanelSnap.xcodeproj \
    -scheme PanelSnap \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  echo "::endgroup::"
  return $status
}

report_errors() {
  local log="$1"
  {
    echo "## Build failed"
    echo ""
    echo "Copy the lines below and paste them to Claude. They are the first errors:"
    echo ""
    echo '```'
    grep -E "error:|error: |fatal error|Resolve Package|could not resolve" "$log" | sort -u | head -40
    echo '```'
  } >> "$SUMMARY"
}

MODE=full
if ! build project.yml build-full.log; then
  echo "::warning::Full build failed - retrying without RAR/7z support (lite build)"
  MODE=lite
  if ! build project.lite.yml build-lite.log; then
    report_errors build-lite.log
    echo "mode=failed" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 1
  fi
fi

APP="$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)"
if [ -z "$APP" ]; then
  echo "Could not find the built .app" >&2
  exit 1
fi

# iPhone Duo (iOS 27) lays out apps linked against an older SDK with a blank strip on the right.
# Stamping the binary as linked against SDK 27.1 turns on the native full-screen layout (same trick as iOXcode).
BIN="$APP/PanelSnap"
MINOS=$(xcrun vtool -show-build "$BIN" 2>/dev/null | awk '/minos/{print $2; exit}')
if xcrun vtool -set-build-version ios "${MINOS:-17.0}" 27.1 -replace -output "$BIN.new" "$BIN"; then
  mv "$BIN.new" "$BIN" && chmod +x "$BIN"
  echo "Stamped SDK 27.1:"; xcrun vtool -show-build "$BIN" | grep -E "platform|minos|sdk" || true
else
  echo "::warning::Could not stamp the SDK version (layout may show a strip on iPhone Duo)"
fi

# Also stamp the Info.plist the same way (iOXcode does both): the Duo layout check looks at the SDK the app claims.
PL="$APP/Info.plist"
for kv in "DTPlatformVersion:27.1" "DTSDKName:iphoneos27.1"; do
  k="${kv%%:*}"; v="${kv#*:}"
  /usr/libexec/PlistBuddy -c "Set :$k $v" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$k string $v" "$PL" || true
done
/usr/libexec/PlistBuddy -c "Print :DTSDKName" "$PL" || true
/usr/libexec/PlistBuddy -c "Print :UIFileSharingEnabled" "$PL" || true
/usr/libexec/PlistBuddy -c "Print :UILaunchScreen" "$PL" || true

rm -rf Payload PanelSnap.ipa
mkdir Payload
cp -R "$APP" Payload/
zip -qry PanelSnap.ipa Payload
ls -lh PanelSnap.ipa

echo "mode=$MODE" >> "${GITHUB_OUTPUT:-/dev/null}"
