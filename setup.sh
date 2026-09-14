#!/bin/zsh
# Bootstrap the verified local Mac runtime without using system Python.
set -euo pipefail
cd "${0:A:h}"
ROOT="$PWD"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  print -u2 '需要 Apple Silicon Mac；请勿在 Rosetta 终端中安装。'
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 '请先运行 xcode-select --install，完成命令行工具安装后再运行本脚本。'
  exit 1
fi

mkdir -p runtime/bin downloads
UV_VERSION=0.12.13
UV_ARCHIVE="$ROOT/downloads/uv-$UV_VERSION-aarch64-apple-darwin.tar.gz"
UV_SHA=7e6ddb9316acc00f2296c82ff4d99977870ee34b2f0ddcae9444d714db9364ed
if [[ ! -f "$UV_ARCHIVE" ]] || [[ "$(shasum -a 256 "$UV_ARCHIVE" | cut -d ' ' -f 1)" != "$UV_SHA" ]]; then
  curl --fail --location --retry 3 --connect-timeout 20 \
    "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz" \
    --output "$UV_ARCHIVE.part"
  [[ "$(shasum -a 256 "$UV_ARCHIVE.part" | cut -d ' ' -f 1)" == "$UV_SHA" ]] || {
    print -u2 'uv 下载校验失败。'; exit 1
  }
  mv "$UV_ARCHIVE.part" "$UV_ARCHIVE"
fi
tar -xzf "$UV_ARCHIVE" -C runtime/bin --strip-components=1 uv-aarch64-apple-darwin/uv
UV="$ROOT/runtime/bin/uv"
export UV_PYTHON_INSTALL_DIR="$ROOT/runtime/python"
export UV_CACHE_DIR="$ROOT/runtime/uv-cache"
if [[ ! -x .venv/bin/python ]]; then
  "$UV" venv --managed-python --python 3.12.14 .venv
fi
.venv/bin/python -c 'import sys; assert sys.version_info[:2] == (3, 12), "需要 Python 3.12 项目环境"'
"$UV" pip install --python "$ROOT/.venv/bin/python" -r VoxBridge/deploy/macos/requirements.lock
"$UV" pip install --python "$ROOT/.venv/bin/python" --no-deps -e VoxBridge

# ONNX graph tooling is isolated from the speech service's pinned packages.
if [[ ! -x runtime/model-tools/bin/python ]]; then
  "$UV" venv --managed-python --python 3.12.14 runtime/model-tools
fi
"$UV" pip install --python "$ROOT/runtime/model-tools/bin/python" -r scripts/model-tools.lock
.venv/bin/python scripts/setup_assets.py --repair-python "$ROOT/runtime/model-tools/bin/python"
./macos.sh check
./build-app.sh
print '安装完成。打开上方路径中的「教会同声传译.app」选择设备并开始传译。'
