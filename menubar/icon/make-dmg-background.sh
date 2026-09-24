#!/bin/bash
# 生成 dmg 窗口的背景图 dmg/background.tiff：640x400 pt，带 @2x，箭头从左边的 App 指向右边的 Applications，
# 上面一句“拖进去安装”，下面一句“也可以直接双击”。图标位置要和 make-dmg.sh 里的一致（170,190 和 470,190）。
set -eu
cd "$(dirname "$0")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/bg.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4F7FF"/><stop offset="1" stop-color="#EAF6F2"/></linearGradient>
    <linearGradient id="ar" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#8ED6C2"/><stop offset="1" stop-color="#7CC8F0"/></linearGradient>
  </defs>
  <rect width="640" height="400" fill="url(#bg)"/>
  <text x="320" y="62" font-family="PingFang SC, Helvetica Neue, sans-serif" font-weight="600" font-size="21" fill="#2E3A59" text-anchor="middle">把 AA Switch 拖到 Applications 文件夹</text>
  <text x="320" y="88" font-family="Helvetica Neue, sans-serif" font-size="13" fill="#6B7590" text-anchor="middle">Drag AA Switch into Applications</text>
  <path d="M252 190 H372" fill="none" stroke="url(#ar)" stroke-width="7" stroke-linecap="round" stroke-dasharray="2 14"/>
  <path d="M370 174 L392 190 L370 206" fill="none" stroke="#7CC8F0" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
  <rect x="120" y="318" width="400" height="44" rx="22" fill="#FFFFFF" opacity="0.75"/>
  <text x="320" y="336" font-family="PingFang SC, Helvetica Neue, sans-serif" font-size="13" fill="#2E3A59" text-anchor="middle">也可以直接双击 AA Switch，它会自己装进“应用程序”</text>
  <text x="320" y="353" font-family="Helvetica Neue, sans-serif" font-size="11" fill="#6B7590" text-anchor="middle">Or just double-click it — it installs itself</text>
</svg>
SVG
swift render-svg.swift "$WORK/bg.svg" "$WORK/bg.png" 640 400
swift render-svg.swift "$WORK/bg.svg" "$WORK/bg@2x.png" 1280 800
mkdir -p dmg
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out dmg/background.tiff 2>/dev/null
echo "已生成 $(pwd)/dmg/background.tiff"
