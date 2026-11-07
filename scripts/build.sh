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
mkdir -p "$APP/Contents/Resources"
cp scripts/export_models.py "$APP/Contents/Resources/"  # run by the in-app .pt converter
cp Support/AppIcon.icns "$APP/Contents/Resources/"  # from scripts/make_icon.swift
cp -R Support/Fonts "$APP/Contents/Resources/"  # Archivo and Geist Mono, SIL OFL (licenses alongside)
cp -R Sources/YoloMeet/Stories/Assets "$APP/Contents/Resources/Stories"  # found by Story.asset(_:in:)
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp Support/AppIcon.icns "$STAGE/.VolumeIcon.icns"
    rm -f build/YOLO-meet.dmg build/YOLO-meet-rw.dmg
    hdiutil create -quiet -volname "YOLO-meet" -srcfolder "$STAGE" -format UDRW build/YOLO-meet-rw.dmg
    rm -rf "$STAGE"
    # The volume's custom-icon flag is not copied from the source folder, so set it on the mounted image.
    MOUNT="$(hdiutil attach -nobrowse build/YOLO-meet-rw.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')"
    xcrun SetFile -a C "$MOUNT"
    hdiutil detach -quiet "$MOUNT"
    hdiutil convert -quiet build/YOLO-meet-rw.dmg -format UDZO -o build/YOLO-meet.dmg
    rm build/YOLO-meet-rw.dmg
    echo "Built build/YOLO-meet.dmg"
fi
