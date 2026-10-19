#!/bin/bash
# 构建官网并上传到你的服务器（rsync over SSH）。用法：
#   DEPLOY_TARGET=root@1.2.3.4:/var/www/aaswitch ./deploy.sh
# 可选：
#   VITE_DOWNLOAD_URL=https://aaswitch.example.com/download/AA%20Switch.dmg   官网下载按钮指向的地址（文件名带空格，URL 里写 %20，浏览器保存时还原成“AA Switch.dmg”）
#   DMG=../menubar/dist/AA\ Switch.dmg                                       一起上传的 macOS 安装包（默认这个路径，不存在则跳过）
#   WIN_EXE=../windows/dist/AA\ Switch.exe                                   一起上传的 Windows 版（windows/build.sh 的产物，不存在则跳过）
# 会顺带上传 AASwitch.app.tar.gz 并生成 download/latest.json（两个平台各自的版本号、日期、下载地址与 sha256），
# 官网在下载按钮下显示版本，程序用它检查更新并在应用内自动更新。这次没带上的平台，服务器上已有的安装包和版本信息原样保留。
set -euo pipefail
cd "$(dirname "$0")"
[ -n "${DEPLOY_TARGET:-}" ] || { echo "请设置 DEPLOY_TARGET=用户@服务器:/网站目录" >&2; exit 1; }
DMG="${DMG:-../menubar/dist/AA Switch.dmg}"
WIN_EXE="${WIN_EXE:-../windows/dist/AA Switch.exe}"
DL_URL="${VITE_DOWNLOAD_URL:-}"
DL_DIR="${DL_URL%/*}"
CHECK_DIR="$(mktemp -d)"; trap 'rm -rf "$CHECK_DIR"' EXIT

# 先检查再构建网站或上传：旧 dist、源码改后没重打的包、同版本重打都不能发布。
[ ! -f "$DMG" ] || python3 ../scripts/release_artifacts.py verify mac "$(dirname "$DMG")"
[ ! -f "$WIN_EXE" ] || python3 ../scripts/release_artifacts.py verify windows "$(dirname "$WIN_EXE")"
if [ -f "$DMG" ] || [ -f "$WIN_EXE" ]; then
  [ -n "$DL_DIR" ] || { echo "发布安装包必须设置 VITE_DOWNLOAD_URL" >&2; exit 1; }
  HTTP="$(curl -sS -o "$CHECK_DIR/current.json" -w '%{http_code}' -m 20 "$DL_DIR/latest.json")"
  case "$HTTP" in
    200) python3 -c 'import json,sys; assert isinstance(json.load(open(sys.argv[1])), dict)' "$CHECK_DIR/current.json" ;;
    404) echo '{}' > "$CHECK_DIR/current.json" ;;
    *) echo "读取线上版本失败（HTTP $HTTP），停止发布" >&2; exit 1 ;;
  esac
fi

echo "· 构建"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run build >/dev/null
mkdir -p dist/download
# 这次没带上的安装包，服务器上已有的那份要留着（rsync --delete 默认会把本地没有的删掉）
PROTECT=()
MAC_JSON=""; WIN_JSON=""
if [ -f "$DMG" ]; then
  cp "$(dirname "$DMG")/release-manifest.json" dist/download/release-manifest-mac.json
  cp "$DMG" "dist/download/AA Switch.dmg"   # 用户下载到的文件名就是这个（带空格）
  cp "$DMG" dist/download/AA-Switch.dmg     # 2.3.0 及之前的地址，留着让旧链接不失效
  echo "· 附带 macOS 安装包 $(du -h "$DMG" | cut -f1)"
  case "${VITE_DOWNLOAD_URL:-}" in
    ''|*/AA%20Switch.dmg) ;;
    *) echo "提示：VITE_DOWNLOAD_URL 应以 /AA%20Switch.dmg 结尾，否则下载到的文件名不是“AA Switch.dmg”" >&2 ;;
  esac
  # 版本号从同目录的 AASwitch.app.tar.gz 里的 Info.plist 读
  TGZ="$(dirname "$DMG")/AASwitch.app.tar.gz"
  if [ -f "$TGZ" ]; then
    cp "$TGZ" dist/download/AASwitch.app.tar.gz   # App 应用内更新下载的就是这个包（也供 setup.sh 用）
    VER="$(tar -xzOf "$TGZ" "AA Switch.app/Contents/Info.plist" | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null || true)"
    if [ -n "$VER" ]; then
      MAC_JSON="$(printf '{"version": "%s", "date": "%s", "url": "%s", "sha256": "%s", "tgz_url": "%s", "tgz_sha256": "%s"}' \
        "$VER" "$(date +%Y-%m-%d)" "${VITE_DOWNLOAD_URL:-}" "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" \
        "${VITE_DOWNLOAD_URL:+$DL_DIR/AASwitch.app.tar.gz}" "$(shasum -a 256 "$TGZ" | cut -d' ' -f1)")"
      echo "· macOS 版：$VER"
    fi
  fi
else
  PROTECT+=(--filter 'protect /download/AA Switch.dmg' --filter 'protect /download/AA-Switch.dmg' --filter 'protect /download/AASwitch.app.tar.gz' --filter 'protect /download/release-manifest-mac.json')
fi
# Windows 版：windows/build.sh 的产物，版本号在同目录的 version.txt
if [ -f "$WIN_EXE" ]; then
  cp "$(dirname "$WIN_EXE")/release-manifest.json" dist/download/release-manifest-windows.json
  cp "$WIN_EXE" "dist/download/AA Switch.exe"
  WIN_VER="$(cat "$(dirname "$WIN_EXE")/version.txt" 2>/dev/null || true)"
  echo "· 附带 Windows 安装包 $(du -h "$WIN_EXE" | cut -f1)"
  if [ -n "$WIN_VER" ]; then
    WIN_JSON="$(printf '{"version": "%s", "date": "%s", "url": "%s", "sha256": "%s"}' \
      "$WIN_VER" "$(date +%Y-%m-%d)" "${VITE_DOWNLOAD_URL:+$DL_DIR/AA%20Switch.exe}" "$(shasum -a 256 "$WIN_EXE" | cut -d' ' -f1)")"
    echo "· Windows 版：$WIN_VER"
  fi
else
  PROTECT+=(--filter 'protect /download/AA Switch.exe' --filter 'protect /download/release-manifest-windows.json')
fi
# latest.json：官网显示当前版本，两个平台的程序都用它检查更新。顶层是 macOS 版的字段（老版本的 App 只认这个位置），Windows 版在
# "windows" 段。以线上现有的那份为底，只替换这次带了安装包的平台，单独发布一个平台时另一个平台的信息不会丢。
if [ -n "$MAC_JSON$WIN_JSON" ]; then
  MAC_JSON="$MAC_JSON" WIN_JSON="$WIN_JSON" python3 - "$CHECK_DIR/current.json" > dist/download/latest.json <<'PY'
import json, os, sys
cur = json.load(open(sys.argv[1]))
mac, win = os.environ["MAC_JSON"], os.environ["WIN_JSON"]
out = json.loads(mac) if mac else {k: v for k, v in cur.items() if k != "windows"}
if win: out["windows"] = json.loads(win)
elif "windows" in cur: out["windows"] = cur["windows"]
print(json.dumps(out, indent=2, ensure_ascii=False))
PY
  python3 ../scripts/release_artifacts.py check-upgrade "$CHECK_DIR/current.json" dist/download/latest.json
  echo "· latest.json：$(tr -d '\n' < dist/download/latest.json | cut -c1-160)…"
else
  PROTECT+=(--filter 'protect /download/latest.json')
fi

echo "· 上传到 $DEPLOY_TARGET"
# 安装包全部上传完成后才替换索引，避免用户先拿到新版本号却下载到旧文件。
rsync -az --delay-updates --delete-delay --exclude '.DS_Store' --exclude '/download/latest.json' ${PROTECT[@]+"${PROTECT[@]}"} dist/ "$DEPLOY_TARGET/"
if [ -n "$MAC_JSON$WIN_JSON" ]; then
  REMOTE_HOST="${DEPLOY_TARGET%%:*}"; REMOTE_DIR="${DEPLOY_TARGET#*:}"
  case "$REMOTE_DIR" in *[!a-zA-Z0-9/_.-]*) echo "部署目录包含不支持的字符" >&2; exit 1 ;; esac
  rsync -az dist/download/latest.json "$DEPLOY_TARGET/download/latest.json.next"
  ssh "$REMOTE_HOST" "mv -- '$REMOTE_DIR/download/latest.json.next' '$REMOTE_DIR/download/latest.json'"
fi
echo "完成。若是首次部署，请按 DEVELOPMENT.md 配置 Caddy 或 Nginx。"
