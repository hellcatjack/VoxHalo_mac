#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCRATCH_PATH=""
ICON_WORK=""
cleanup() {
    [[ -z "$SCRATCH_PATH" ]] || rm -rf "$SCRATCH_PATH"
    [[ -z "$ICON_WORK" ]] || rm -rf "$ICON_WORK"
}
trap cleanup EXIT

if [[ "${VOXHALO_RUN_PACKAGING_TESTS:-0}" == "1" ]]; then
    SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/voxhalo-package-build.XXXXXX")"
    swift build -c release --arch arm64 --product VoxHalo \
        --scratch-path "$SCRATCH_PATH"
    BINARY="$SCRATCH_PATH/arm64-apple-macosx/release/VoxHalo"
else
    swift build -c release --arch arm64 --product VoxHalo
    BINARY="$ROOT/.build/arm64-apple-macosx/release/VoxHalo"
fi

APP_REL="dist/VoxHalo.app"
EXECUTABLE_REL="dist/VoxHalo.app/Contents/MacOS/VoxHalo"
APP="$ROOT/$APP_REL"
EXECUTABLE="$ROOT/$EXECUTABLE_REL"
ICON_SOURCE="$ROOT/Config/PCCSAppIconSource.png"
ICON="$APP/Contents/Resources/VoxHalo.icns"

if [[ ! -x "$BINARY" ]]; then
    print -u2 "Release executable was not produced at $BINARY"
    exit 1
fi
if [[ ! -f "$ICON_SOURCE" ]]; then
    print -u2 "Official PCCS app icon source is missing: $ICON_SOURCE"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 0755 "$BINARY" "$EXECUTABLE"
install -m 0644 Config/Info.plist "$APP/Contents/Info.plist"

ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/voxhalo-icon-build.XXXXXX")"
ICONSET="$ICON_WORK/VoxHalo.iconset"
mkdir -p "$ICONSET"

render_icon() {
    local size="$1"
    local name="$2"
    sips -s format png -z "$size" "$size" "$ICON_SOURCE" \
        --out "$ICONSET/$name" >/dev/null
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$ICON"
chmod 0644 "$ICON"

codesign --force --sign - --timestamp=none --options runtime \
    --entitlements Config/VoxHalo.entitlements \
    --requirements '=designated => identifier "com.hellcatjack.voxhalo"' \
    "$APP"

scripts/verify-app.sh "$APP_REL"
print "Built and verified $APP_REL"
