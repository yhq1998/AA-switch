#!/bin/bash
# 生成菜单栏和菜单里用的小图标（都是 @2x 像素图，程序里按一半尺寸显示）：
#   menubar/menubar.png         菜单栏图标，72x36 px（36x18 pt）：应用图标里的那只 AA 笑脸开关，静态，不表示状态
#   menubar/product-codex.png   菜单里 Codex 分组的备用标记，32x32 px（16 pt），黑色模板图（风车结）；本机装了 Codex / ChatGPT 时用它们自己的图标
#   menubar/product-claude.png  菜单里 Claude Code 分组的备用标记，32x32 px（16 pt），黑色模板图（星芒）；本机装了 Claude 时用它自己的图标
set -eu
cd "$(dirname "$0")"
mkdir -p menubar
render() {  # render 名字 宽 高 <<SVG
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/$1.svg"
  swift render-svg.swift "$tmp/$1.svg" "menubar/$1.png" "$2" "$3"; rm -rf "$tmp"
}
render menubar 72 36 <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="72" height="36" viewBox="0 0 72 36">
  <defs>
    <linearGradient id="t" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#8ED6C2"/><stop offset="1" stop-color="#7CC8F0"/></linearGradient>
    <linearGradient id="k" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFE08A"/><stop offset="1" stop-color="#FFC94D"/></linearGradient>
  </defs>
  <rect x="1" y="3" width="70" height="30" rx="15" fill="url(#t)"/>
  <rect x="4" y="5" width="64" height="11" rx="5.5" fill="#FFFFFF" opacity="0.22"/>
  <text x="21" y="23.5" font-family="Arial Rounded MT Bold, Helvetica Neue, Arial, sans-serif" font-weight="800" font-size="15.5" fill="#FFFFFF" text-anchor="middle" letter-spacing="-0.5">AA</text>
  <circle cx="54" cy="19" r="13" fill="#3B4F8A" opacity="0.22"/>
  <circle cx="54" cy="18" r="13" fill="url(#k)"/>
  <circle cx="54" cy="18" r="13" fill="none" stroke="#FFFFFF" stroke-width="1.6" opacity="0.9"/>
  <circle cx="50" cy="16.5" r="1.7" fill="#3A2E2A"/><circle cx="58" cy="16.5" r="1.7" fill="#3A2E2A"/>
  <ellipse cx="47" cy="21" rx="2.4" ry="1.4" fill="#FF8FA3" opacity="0.8"/><ellipse cx="61" cy="21" rx="2.4" ry="1.4" fill="#FF8FA3" opacity="0.8"/>
  <path d="M51 21.5 q3 3.2 6 0" fill="none" stroke="#3A2E2A" stroke-width="1.5" stroke-linecap="round"/>
</svg>
SVG
# Codex：六边形的六条边各向外延出一截，绕成一个风车结（OpenAI 风格的简化）
render product-codex 32 32 <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
  <g transform="translate(16 16)" fill="none" stroke="#000" stroke-width="3.4" stroke-linecap="round">
    <path d="M-4.6 -8 L9.8 -8"/>
    <path d="M-4.6 -8 L9.8 -8" transform="rotate(60)"/>
    <path d="M-4.6 -8 L9.8 -8" transform="rotate(120)"/>
    <path d="M-4.6 -8 L9.8 -8" transform="rotate(180)"/>
    <path d="M-4.6 -8 L9.8 -8" transform="rotate(240)"/>
    <path d="M-4.6 -8 L9.8 -8" transform="rotate(300)"/>
  </g>
</svg>
SVG
# Claude：从中心放射的十二道长短不一的星芒
render product-claude 32 32 <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
  <g transform="translate(16 16)" stroke="#000" stroke-width="3.2" stroke-linecap="round">
    <line x1="0" y1="0" x2="0" y2="-13.5"/>
    <line x1="0" y1="0" x2="0" y2="-9" transform="rotate(30)"/>
    <line x1="0" y1="0" x2="0" y2="-13" transform="rotate(60)"/>
    <line x1="0" y1="0" x2="0" y2="-8.5" transform="rotate(90)"/>
    <line x1="0" y1="0" x2="0" y2="-13.5" transform="rotate(120)"/>
    <line x1="0" y1="0" x2="0" y2="-9" transform="rotate(150)"/>
    <line x1="0" y1="0" x2="0" y2="-13" transform="rotate(180)"/>
    <line x1="0" y1="0" x2="0" y2="-8.5" transform="rotate(210)"/>
    <line x1="0" y1="0" x2="0" y2="-13.5" transform="rotate(240)"/>
    <line x1="0" y1="0" x2="0" y2="-9" transform="rotate(270)"/>
    <line x1="0" y1="0" x2="0" y2="-13" transform="rotate(300)"/>
    <line x1="0" y1="0" x2="0" y2="-8.5" transform="rotate(330)"/>
  </g>
</svg>
SVG
echo "已生成 $(pwd)/menubar/"
