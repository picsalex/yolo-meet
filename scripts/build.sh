#!/usr/bin/env bash
# Build "YOLO-meet.app" (ad-hoc signed) into build/. Pass --dmg to also package build/YOLO-meet.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --product YoloMeet
BIN="$(swift build -c release --show-bin-path)/YoloMeet"

APP="build/YOLO-meet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/YOLO-meet"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f build/YOLO-meet.dmg
    hdiutil create -volname "YOLO-meet" -srcfolder "$STAGE" -ov -format UDZO build/YOLO-meet.dmg
    rm -rf "$STAGE"
    echo "Built build/YOLO-meet.dmg"
fi
