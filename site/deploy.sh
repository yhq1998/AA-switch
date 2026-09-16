#!/bin/bash
# 构建官网并上传到你的服务器（rsync over SSH）。用法：
#   DEPLOY_TARGET=root@1.2.3.4:/var/www/aaswitch ./deploy.sh
# 可选：
#   VITE_DOWNLOAD_URL=https://aaswitch.example.com/download/AA-Switch.dmg   官网下载按钮指向的地址
#   DMG=../menubar/dist/AA\ Switch.dmg                                       一起上传的安装包（默认这个路径，不存在则跳过）
# 会顺带生成 download/latest.json（版本号、日期、地址、sha256），官网在下载按钮下显示版本，App 用它检查更新。
set -eu
cd "$(dirname "$0")"
[ -n "${DEPLOY_TARGET:-}" ] || { echo "请设置 DEPLOY_TARGET=用户@服务器:/网站目录" >&2; exit 1; }
DMG="${DMG:-../menubar/dist/AA Switch.dmg}"

echo "· 构建"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run build >/dev/null
if [ -f "$DMG" ]; then
  mkdir -p dist/download; cp "$DMG" dist/download/AA-Switch.dmg; echo "· 附带安装包 $(du -h "$DMG" | cut -f1)"
  # latest.json：官网显示当前版本，App 用它检查更新（版本号从同目录的 AASwitch.app.tar.gz 里的 Info.plist 读）
  TGZ="$(dirname "$DMG")/AASwitch.app.tar.gz"
  if [ -f "$TGZ" ]; then
    VER="$(tar -xzOf "$TGZ" "AA Switch.app/Contents/Info.plist" | plutil -extract CFBundleShortVersionString raw -o - - 2>/dev/null || true)"
    if [ -n "$VER" ]; then
      printf '{\n  "version": "%s",\n  "date": "%s",\n  "url": "%s",\n  "sha256": "%s"\n}\n' \
        "$VER" "$(date +%Y-%m-%d)" "${VITE_DOWNLOAD_URL:-}" "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" > dist/download/latest.json
      echo "· latest.json：$VER"
    fi
  fi
fi

echo "· 上传到 $DEPLOY_TARGET"
rsync -az --delete --exclude '.DS_Store' dist/ "$DEPLOY_TARGET/"
echo "完成。若是首次部署，请按 DEVELOPMENT.md 配置 Caddy 或 Nginx。"
