#!/bin/zsh
set -eu
cd "${0:A:h}"
exec ../.venv/bin/python tools/macos_service.py "${1:-start}"
