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
../.venv/bin/python - <<'PYTHON'
import json
import sys
from pathlib import Path
root = Path.cwd().parent
sys.path.insert(0, str(root / 'scripts'))
from setup_assets import install_asset, install_japanese_dictionary, MANIFEST
asset = next(a for a in json.loads(MANIFEST.read_text())['assets']
             if a['path'] == 'downloads/open_jtalk_dic_utf_8-1.11.tar.gz')
install_asset(root, asset)
install_japanese_dictionary(root)
PYTHON
./macos.sh check
