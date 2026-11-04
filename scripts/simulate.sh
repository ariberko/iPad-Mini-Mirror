#!/usr/bin/env bash
# Runs Mirror on an iPhone and an iPad Simulator side by side, takes screenshots
# of every screen, and records the two devices mirroring each other.
#
# Usage (on a Mac with Xcode and XcodeGen): scripts/simulate.sh [output-folder]
set -euo pipefail

OUT="${1:-$PWD/simulation}"
BUNDLE="${APP_BUNDLE_ID:-com.ariberko.mirror}"
rm -rf "$OUT" && mkdir -p "$OUT/logs"

echo "▶︎ Building for Simulator"
xcodegen generate >/dev/null
xcodebuild \
  -project Mirror.xcodeproj -scheme Mirror -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/sim \
  APP_BUNDLE_ID="$BUNDLE" CODE_SIGNING_ALLOWED=NO \
  -quiet build
APP="build/sim/Build/Products/Debug-iphonesimulator/Mirror.app"

# Newest iOS runtime first, then the first device whose name matches.
pick() {
  xcrun simctl list devices available -j | jq -r --arg re "$1" '
    [.devices | to_entries | sort_by(.key) | reverse[] | select(.key | test("iOS")) | .value[]
     | select(.name | test($re))] | first | .udid // empty'
}
IPHONE=$(pick '^iPhone [0-9]+ Pro$'); [ -n "$IPHONE" ] || IPHONE=$(pick '^iPhone')
IPAD=$(pick '^iPad mini'); [ -n "$IPAD" ] || IPAD=$(pick '^iPad Air'); [ -n "$IPAD" ] || IPAD=$(pick '^iPad')
echo "▶︎ iPhone: $(xcrun simctl list devices | grep "$IPHONE" | sed 's/ (.*//' | xargs)"
echo "▶︎ iPad:   $(xcrun simctl list devices | grep "$IPAD" | sed 's/ (.*//' | xargs)"

defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false || true
for DEVICE in "$IPHONE" "$IPAD"; do
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
done
for DEVICE in "$IPHONE" "$IPAD"; do
  xcrun simctl bootstatus "$DEVICE" -b >/dev/null
  xcrun simctl ui "$DEVICE" appearance light
  xcrun simctl status_bar "$DEVICE" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$DEVICE" "$APP"
done
sleep 5

launch() { # device logname args...
  local device=$1 name=$2; shift 2
  xcrun simctl terminate "$device" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch --stdout="$OUT/logs/$name.log" --stderr="$OUT/logs/$name.log" "$device" "$BUNDLE" "$@" >/dev/null
}
shot() { xcrun simctl io "$1" screenshot "$OUT/$2.png" >/dev/null 2>&1 && echo "  📸 $2"; }

PHONE_ARGS=(-MirrorDemoName "Ari's iPhone" -MirrorDemoCode 135790)
PAD_ARGS=(-MirrorDemoName "Ari's iPad" -MirrorDemoCode 482913)

echo "▶︎ Welcome screens"
launch "$IPHONE" welcome-iphone -MirrorDemo onboarding "${PHONE_ARGS[@]}"
launch "$IPAD" welcome-ipad -MirrorDemo onboarding "${PAD_ARGS[@]}"
sleep 6
shot "$IPHONE" 01-iphone-welcome
shot "$IPAD" 01-ipad-welcome

echo "▶︎ Home screens (each finds the other)"
launch "$IPAD" home-ipad -MirrorDemo home "${PAD_ARGS[@]}"
launch "$IPHONE" home-iphone -MirrorDemo home "${PHONE_ARGS[@]}"
sleep 9
shot "$IPHONE" 02-iphone-home
shot "$IPAD" 02-ipad-home

echo "▶︎ Pairing with a code"
launch "$IPHONE" pair-iphone -MirrorDemo connect -MirrorDemoTypeCode 482913 "${PHONE_ARGS[@]}"
sleep 6
shot "$IPHONE" 03-iphone-enter-code
shot "$IPAD" 03-ipad-shows-code
sleep 7
shot "$IPHONE" 04-iphone-paired-ready
shot "$IPAD" 04-ipad-paired

echo "▶︎ Settings and Inbox"
launch "$IPHONE" settings-iphone -MirrorDemo settings "${PHONE_ARGS[@]}"
sleep 5
shot "$IPHONE" 05-iphone-settings
launch "$IPHONE" inbox-iphone -MirrorDemo inbox "${PHONE_ARGS[@]}"
sleep 5
shot "$IPHONE" 06-iphone-inbox

echo "▶︎ Live: iPhone screen on the iPad"
launch "$IPAD" live1-ipad -MirrorDemo home -MirrorDemoSendFile -MirrorDemoStats "${PAD_ARGS[@]}"
sleep 3
xcrun simctl io "$IPAD" recordVideo --codec=h264 --force "$OUT/video-iphone-on-ipad.mp4" >/dev/null 2>&1 &
REC=$!
sleep 1
launch "$IPHONE" live1-iphone -MirrorDemo sender -MirrorDemoPairWith 482913 "${PHONE_ARGS[@]}"
sleep 9
shot "$IPAD" 07-ipad-showing-iphone
shot "$IPHONE" 07-iphone-sharing
sleep 7
shot "$IPAD" 08-ipad-file-sent
kill -INT "$REC" 2>/dev/null || true
wait "$REC" 2>/dev/null || true

echo "▶︎ Live: iPad screen on the iPhone"
launch "$IPHONE" live2-iphone -MirrorDemo home -MirrorDemoStats "${PHONE_ARGS[@]}"
sleep 3
xcrun simctl io "$IPHONE" recordVideo --codec=h264 --force "$OUT/video-ipad-on-iphone.mp4" >/dev/null 2>&1 &
REC=$!
sleep 1
launch "$IPAD" live2-ipad -MirrorDemo sender -MirrorDemoPairWith 135790 "${PAD_ARGS[@]}"
sleep 11
shot "$IPHONE" 09-iphone-showing-ipad
shot "$IPAD" 09-ipad-sharing
sleep 3
kill -INT "$REC" 2>/dev/null || true
wait "$REC" 2>/dev/null || true

echo "▶︎ Done. Files:"
ls -1 "$OUT"
