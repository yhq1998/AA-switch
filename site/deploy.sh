#!/bin/bash
# 构建官网并上传到你的服务器（rsync over SSH）。用法：
#   DEPLOY_TARGET=root@1.2.3.4:/var/www/aaswitch ./deploy.sh
# 可选：
#   VITE_DOWNLOAD_URL=https://aaswitch.example.com/download/AA-Switch.dmg   官网下载按钮指向的地址
#   DMG=../menubar/dist/AA\ Switch.dmg                                       一起上传的安装包（默认这个路径，不存在则跳过）
set -eu
cd "$(dirname "$0")"
[ -n "${DEPLOY_TARGET:-}" ] || { echo "请设置 DEPLOY_TARGET=用户@服务器:/网站目录" >&2; exit 1; }
DMG="${DMG:-../menubar/dist/AA Switch.dmg}"

echo "· 构建"
[ -d node_modules ] || npm install --no-audit --no-fund
npm run build >/dev/null
if [ -f "$DMG" ]; then mkdir -p dist/download; cp "$DMG" dist/download/AA-Switch.dmg; echo "· 附带安装包 $(du -h "$DMG" | cut -f1)"; fi

echo "· 上传到 $DEPLOY_TARGET"
rsync -az --delete --exclude '.DS_Store' dist/ "$DEPLOY_TARGET/"
echo "完成。若是首次部署，请按 DEVELOPMENT.md 配置 Caddy 或 Nginx。"
