#!/bin/zsh
# Refresh dependencies for an already bootstrapped workspace.
set -euo pipefail
cd "${0:A:h}/../.."
if [[ ! -x ../.venv/bin/python || ! -x ../runtime/bin/uv ]]; then
  print -u2 '请先在仓库根目录运行 ./setup.sh，安装 Python、模型及运行时。'
  exit 1
fi
../runtime/bin/uv pip install --python ../.venv/bin/python -r deploy/macos/requirements.lock
../runtime/bin/uv pip install --python ../.venv/bin/python --no-deps -e .
./macos.sh check
