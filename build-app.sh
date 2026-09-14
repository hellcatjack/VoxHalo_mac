#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -x .venv/bin/python ]]; then
  print -u2 '尚未安装本地环境，请先运行 ./setup.sh。'
  exit 1
fi
exec .venv/bin/python VoxBridge/tools/build_macos_app.py \
  --destination "${VOXHALO_APP_PATH:-$HOME/Applications/教会同声传译.app}" "$@"
