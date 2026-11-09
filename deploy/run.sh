#!/usr/bin/env sh
# 纯 Python 直跑（Linux / macOS / 群晖）
set -eu
cd "$(dirname "$0")/.."
: "${AMANE_DATA:?请先设置 AMANE_DATA 指向 amane 的 data 目录}"
export AMANE_BASE="${AMANE_BASE:-http://127.0.0.1:8000}"
export DATA_DIR="${DATA_DIR:-./data}"
export PORT="${PORT:-8770}"
exec python3 server/server.py "$@"
