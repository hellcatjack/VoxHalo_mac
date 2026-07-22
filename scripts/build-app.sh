#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ "${VOXHALO_RUN_PACKAGING_TESTS:-0}" == "1" ]]; then
    SCRATCH_PATH="$(mktemp -d "${TMPDIR:-/tmp}/voxhalo-package-build.XXXXXX")"
    trap 'rm -rf "$SCRATCH_PATH"' EXIT
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

if [[ ! -x "$BINARY" ]]; then
    print -u2 "Release executable was not produced at $BINARY"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 0755 "$BINARY" "$EXECUTABLE"
install -m 0644 Config/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none --options runtime \
    --entitlements Config/VoxHalo.entitlements "$APP"

scripts/verify-app.sh "$APP_REL"
print "Built and verified $APP_REL"
