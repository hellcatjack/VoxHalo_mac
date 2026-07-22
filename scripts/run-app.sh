#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

scripts/build-app.sh
open -n dist/VoxHalo.app
