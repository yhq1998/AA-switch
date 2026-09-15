#!/bin/bash
# setup.sh — 把 codex-mode 安装到 ~/.codex/codex-mode
#
#   本地安装：bash setup.sh                                （同目录下要有 codex-mode.sh）
#   远程安装：curl -fsSL https://你的托管目录/setup.sh | bash
#
# 部署方把托管目录和默认 API 参数填在下面，同事安装后直接 ~/.codex/codex-mode api 即可；
# 留空则由 codex-mode 在首次切换时交互询问（或从已有的 config.toml 推断）。
# 若托管目录（或本地同目录、menubar/dist/）里有 AASwitch.app.tar.gz，会一并安装菜单栏小工具到 ~/Applications；
# 不想装可设 CODEX_SETUP_NO_MENUBAR=1。
set -eu

# ======== 部署方预填（都可留空）========
DEFAULT_DOWNLOAD_URL=""            # codex-mode.sh 所在目录，例如 https://files.example.com/codex-mode
DEFAULT_BASE_URL=""                # API Base URL，例如 https://api.example.com/v1
DEFAULT_HEADERS=""                 # 额外请求头，TOML 内联表，例如 { "x-my-header" = "value" }
DEFAULT_LEGACY_KEYCHAIN_SERVICE="" # 旧版脚本保存 key 用的钥匙串服务名，填了会自动迁移已保存的 key
# =======================================

DOWNLOAD_URL="${CODEX_SETUP_URL:-$DEFAULT_DOWNLOAD_URL}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TARGET="$CODEX_HOME/codex-mode"
CONF="$CODEX_HOME/codex-mode.conf"

[ "$(uname -s)" = Darwin ] || { echo "此脚本用于 macOS。" >&2; exit 1; }
for t in awk sqlite3 security osascript; do
  command -v "$t" >/dev/null || { echo "缺少 $t 命令，无法安装。" >&2; exit 1; }
done
mkdir -p "$CODEX_HOME"

SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; fi
TMP="$(mktemp "$CODEX_HOME/.codex-mode.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/codex-mode.sh" ]; then
  cp "$SRC_DIR/codex-mode.sh" "$TMP"
elif [ -n "$DOWNLOAD_URL" ]; then
  curl -fsSL --connect-timeout 15 --max-time 60 "${DOWNLOAD_URL%/}/codex-mode.sh" -o "$TMP"
else
  echo "远程安装需要托管地址：请在 setup.sh 里填写 DEFAULT_DOWNLOAD_URL，或设置环境变量 CODEX_SETUP_URL。" >&2; exit 1
fi
head -n1 "$TMP" | grep -q '^#!/bin/bash' || { echo "下载到的不是脚本（可能是网页），请检查托管地址。" >&2; exit 1; }
bash -n "$TMP"

if [ -f "$TARGET" ]; then
  mkdir -p "$CODEX_HOME/codex-mode-backups"
  cp "$TARGET" "$CODEX_HOME/codex-mode-backups/codex-mode.old-$(date +%Y%m%d-%H%M%S)"
fi
chmod 755 "$TMP"; mv "$TMP" "$TARGET"; trap - EXIT
echo "已安装 $TARGET"

if [ ! -f "$CONF" ]; then
  : > "$CONF"; chmod 600 "$CONF"
  if [ -n "$DEFAULT_BASE_URL" ]; then echo "base_url=${DEFAULT_BASE_URL%/}" >> "$CONF"; fi
  if [ -n "$DEFAULT_HEADERS" ]; then echo "headers=$DEFAULT_HEADERS" >> "$CONF"; fi
  if [ -n "$DEFAULT_LEGACY_KEYCHAIN_SERVICE" ]; then echo "legacy_keychain_service=$DEFAULT_LEGACY_KEYCHAIN_SERVICE" >> "$CONF"; fi
  if [ -s "$CONF" ]; then echo "已写入默认 API 配置 $CONF"; else rm -f "$CONF"; fi
fi

# ---------- 菜单栏小工具（可选，装不上不影响命令行） ----------
MENUBAR_MSG=""
if [ "${CODEX_SETUP_NO_MENUBAR:-}" != 1 ]; then
  APP_TGZ=""; APP_TMP=""
  for c in "$SRC_DIR/menubar/dist/AASwitch.app.tar.gz" "$SRC_DIR/AASwitch.app.tar.gz"; do
    if [ -n "$SRC_DIR" ] && [ -f "$c" ]; then APP_TGZ="$c"; break; fi
  done
  if [ -z "$APP_TGZ" ] && [ -n "$DOWNLOAD_URL" ]; then
    APP_TMP="$(mktemp "$CODEX_HOME/.codex-mode-app.XXXXXX")"
    if curl -fsSL --connect-timeout 15 --max-time 120 "${DOWNLOAD_URL%/}/AASwitch.app.tar.gz" -o "$APP_TMP" 2>/dev/null; then APP_TGZ="$APP_TMP"; fi
  fi
  if [ -n "$APP_TGZ" ] && tar -tzf "$APP_TGZ" 2>/dev/null | grep -q '^AA Switch.app/Contents/MacOS/AASwitch$'; then
    APP_DIR=/Applications; [ -w /Applications ] || { APP_DIR="$HOME/Applications"; mkdir -p "$APP_DIR"; }
    pkill -x AASwitch 2>/dev/null || true; sleep 0.5
    rm -rf "/Applications/AA Switch.app" "$HOME/Applications/AA Switch.app" 2>/dev/null || true   # 只保留一份，避免启动台出现多个
    tar -xzf "$APP_TGZ" -C "$APP_DIR"
    xattr -dr com.apple.quarantine "$APP_DIR/AA Switch.app" 2>/dev/null || true
    if open -a "$APP_DIR/AA Switch.app" 2>/dev/null; then
      MENUBAR_MSG="菜单栏小工具 AA Switch 已安装到 $APP_DIR 并已启动，看屏幕右上角的图标；点开可直接切换。"
    else
      MENUBAR_MSG="菜单栏小工具已安装到 $APP_DIR/AA Switch.app，请手动打开一次。"
    fi
  elif [ -n "$APP_TGZ" ]; then
    MENUBAR_MSG="菜单栏小工具的安装包无效，已跳过（命令行照常可用）。"
  fi
  [ -n "$APP_TMP" ] && rm -f "$APP_TMP"
fi

cat <<MSG

安装完成。接下来：
  用 API key：       $TARGET api        （首次会提示输入 key，可存进钥匙串）
  用 ChatGPT 账号：  $TARGET chatgpt
  查看状态：         $TARGET status
  修改地址或 key：   $TARGET configure
切换会退出并重开 Codex，历史会话在两种模式下都能继续；改动前会备份到 $CODEX_HOME/codex-mode-backups/。
${MENUBAR_MSG}
MSG
