#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_INPUT="${1:-dist/VoxHalo.app}"
if [[ "$APP_INPUT" = /* ]]; then
    APP="$APP_INPUT"
else
    APP="$ROOT/$APP_INPUT"
fi
INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/VoxHalo"
ICON="$APP/Contents/Resources/VoxHalo.icns"

fail() {
    print -u2 "VoxHalo bundle verification failed: $1"
    exit 1
}

[[ -d "$APP" ]] || fail "bundle does not exist: $APP_INPUT"
[[ -f "$INFO" ]] || fail "Info.plist is missing"
[[ -x "$EXECUTABLE" ]] || fail "VoxHalo executable is missing or not executable"
[[ -f "$ICON" ]] || fail "VoxHalo app icon is missing"

plutil -lint "$INFO" >/dev/null

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null
}

[[ "$(plist_value CFBundleIdentifier)" == "com.hellcatjack.voxhalo" ]] \
    || fail "unexpected bundle identifier"
[[ "$(plist_value CFBundleExecutable)" == "VoxHalo" ]] \
    || fail "unexpected executable name"
[[ "$(plist_value CFBundleIconFile)" == "VoxHalo" ]] \
    || fail "unexpected app icon name"
[[ "$(plist_value LSMinimumSystemVersion)" == "26.0" ]] \
    || fail "LSMinimumSystemVersion must be 26.0"
[[ "$(plist_value NSHighResolutionCapable)" == "true" ]] \
    || fail "high-resolution support is missing"

ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
[[ "$ARCHITECTURES" == "arm64" ]] \
    || fail "executable must contain only arm64, found: $ARCHITECTURES"
otool -L "$EXECUTABLE" | grep -q '/Security.framework/' \
    || fail "native Security.framework linkage is missing"

codesign --verify --deep --strict "$APP" 2>/dev/null \
    || fail "code signature is invalid"
SIGNATURE_DETAILS="$(codesign -dvvv "$APP" 2>&1)"
[[ "$SIGNATURE_DETAILS" == *"runtime"* ]] \
    || fail "Hardened Runtime flag is missing"
DESIGNATED_REQUIREMENT="$(codesign -dr - "$APP" 2>&1)"
[[ "$DESIGNATED_REQUIREMENT" == \
    *'designated => identifier "com.hellcatjack.voxhalo"'* ]] \
    || fail "stable designated requirement is missing"
[[ "$DESIGNATED_REQUIREMENT" != *"cdhash"* ]] \
    || fail "designated requirement must not change with every rebuild"

TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/voxhalo-verify.XXXXXX")"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT
ICONSET="$TEMPORARY_DIRECTORY/VoxHalo.iconset"
iconutil -c iconset "$ICON" -o "$ICONSET" >/dev/null 2>&1 \
    || fail "app icon is not a valid ICNS file"
[[ -f "$ICONSET/icon_512x512@2x.png" ]] \
    || fail "app icon is missing its 1024-pixel representation"
SIGNED_ENTITLEMENTS="$TEMPORARY_DIRECTORY/entitlements.plist"
codesign -d --entitlements :- "$APP" >"$SIGNED_ENTITLEMENTS" 2>/dev/null \
    || fail "signed entitlements could not be read"
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null \
    || fail "signed entitlements are malformed"
[[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.device.audio-input' \
    "$SIGNED_ENTITLEMENTS" 2>/dev/null)" == "true" ]] \
    || fail "com.apple.security.device.audio-input entitlement is missing"
if /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.app-sandbox' \
    "$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
    fail "com.apple.security.app-sandbox must be absent"
fi

if find "$APP" -type f \( \
    -iname 'settings.json' -o \
    -iname 'client.log' -o \
    -iname '*.exe' -o \
    -iname '*.dll' -o \
    -iname '*.pdb' -o \
    -iname '*.swift' \
\) -print -quit | grep -q .; then
    fail "private runtime, Windows, or source file was copied into the bundle"
fi

for marker in settings.json client.log AuthPassword voxhalo-packaging-test-secret; do
    if grep -R -a -i -q -- "$marker" "$APP/Contents/Resources" "$INFO"; then
        fail "forbidden resource content found: $marker"
    fi
done

if [[ -n "${VOXHALO_TEST_SECRET_SENTINEL:-}" ]] && \
   grep -R -a -F -q -- "$VOXHALO_TEST_SECRET_SENTINEL" \
       "$APP/Contents/Resources" "$INFO"; then
    fail "test secret sentinel was copied into the bundle"
fi

print "Verified $APP_INPUT (arm64, Hardened Runtime, locally signed)"
