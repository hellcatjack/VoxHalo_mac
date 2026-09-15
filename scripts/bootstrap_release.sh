#!/bin/zsh
# Build tooling only. End users launch the prebuilt App.
set -euo pipefail
RELEASE_ROOT="${0:A:h:h}"
RELEASE_TOOLS="$RELEASE_ROOT/runtime/release-tools"
mkdir -p "$RELEASE_TOOLS"
if [[ ! -x "$RELEASE_TOOLS/uv" ]]; then
  curl --fail --location --retry 3 --output "$RELEASE_TOOLS/uv.tar.gz.part" \
    'https://github.com/astral-sh/uv/releases/download/0.12.13/uv-aarch64-apple-darwin.tar.gz'
  print '7e6ddb9316acc00f2296c82ff4d99977870ee34b2f0ddcae9444d714db9364ed  '"$RELEASE_TOOLS/uv.tar.gz.part" | shasum -a 256 --check
  tar -xzf "$RELEASE_TOOLS/uv.tar.gz.part" -C "$RELEASE_TOOLS"
  cp "$RELEASE_TOOLS/uv-aarch64-apple-darwin/uv" "$RELEASE_TOOLS/uv"
fi
export UV_PYTHON_INSTALL_DIR="$RELEASE_TOOLS/python"
export UV_CACHE_DIR="$RELEASE_TOOLS/cache"
"$RELEASE_TOOLS/uv" python install 3.12.14
RELEASE_PYTHON="$("$RELEASE_TOOLS/uv" python find --managed-python 3.12.14)"
RELEASE_PYTHON_HOME="${RELEASE_PYTHON:h:h}"
RELEASE_VALIDATION_ARGS=()
if [[ "${VOXHALO_CI_ALLOW_NO_METAL:-0}" == 1 ]]; then
  RELEASE_VALIDATION_ARGS+=(--allow-no-metal)
fi
"$RELEASE_PYTHON" "$RELEASE_ROOT/scripts/build_desktop_release.py" payload \
  --output "$RELEASE_ROOT/dist/release-payload" --uv "$RELEASE_TOOLS/uv" \
  --python-home "$RELEASE_PYTHON_HOME" --cache-dir "$UV_CACHE_DIR" "${RELEASE_VALIDATION_ARGS[@]}"
"$RELEASE_PYTHON" "$RELEASE_ROOT/VoxBridge/tools/build_macos_app.py" \
  --destination "$RELEASE_ROOT/dist/同声传译.app" --release-payload "$RELEASE_ROOT/dist/release-payload"
"$RELEASE_PYTHON" "$RELEASE_ROOT/scripts/build_desktop_release.py" package \
  --app "$RELEASE_ROOT/dist/同声传译.app" --output "$RELEASE_ROOT/dist/release"
