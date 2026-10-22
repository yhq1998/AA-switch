#!/bin/bash
# AA Switch adapter only. All 14 checks are upstream code in vendor/claude-switcher/checks.sh.
# Arguments: private-state-directory proxy-mode country timezone locale proxy-group
set -u
export LC_ALL=en_US.UTF-8
umask 077

if [ "$#" -ne 6 ]; then
    echo 'ERROR:账号环境检测参数不完整。'
    exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$SCRIPT_DIR/vendor/claude-switcher"
BASE="$1"
PROXY_MODE="$2"
COUNTRY_TARGET="$3"
TZ_TARGET="$4"
LOCALE_TARGET="$5"
PROXY_GROUP="$6"
CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
ROUTE_MISSED=""

case "$PROXY_MODE" in
    clash-verge|shadowrocket|sing-box|clashx|surge|auto) ;;
    *) echo 'ERROR:不支持的代理客户端。'; exit 2 ;;
esac
if [ ! -f "$VENDOR/checks.sh" ] || [ ! -f "$VENDOR/stun-probe.py" ]; then
    echo 'ERROR:缺少原版检测资源，请重新安装 AA Switch。'
    exit 2
fi
PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ] || { [ "$PYTHON" = /usr/bin/python3 ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; }; then
    echo 'ERROR:原版 WebRTC/STUN 检测需要 Python 3。请先安装 Python 3，再重新检测。'
    exit 2
fi
mkdir -p "$BASE" || exit 2
chmod 700 "$BASE" || exit 2
cp "$VENDOR/stun-probe.py" "$BASE/stun-probe.py" || exit 2

# This file contains only unchanged upstream function definitions; no switch/fix/daemon commands.
source "$VENDOR/checks.sh"

# Original checkdetail dispatch, with BASE redirected to AA Switch's own private state directory.
OUT_FILE="$BASE/last-check.txt"
{
    echo "# $(date '+%F %T') pid=$$ 开始"
    checkdetail
    echo "# 结束"
} > "$OUT_FILE" 2>&1 || { echo 'ERROR:无法写入本次检测结果。'; exit 2; }
cat "$OUT_FILE"
