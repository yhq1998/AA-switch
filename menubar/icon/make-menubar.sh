#!/bin/bash
# 生成菜单栏用的小图标（72x36 px，即 36x18 pt @2x）：只保留笑脸拨动开关，按钮位置表示模式。
#   menubar-api.png      按钮在右，薄荷蓝轨道（API 模式）
#   menubar-chatgpt.png  按钮在左，粉色轨道（ChatGPT 账号）
#   menubar-off.png      灰色，无表情（未知 / 未安装 / 切换中）
set -eu
cd "$(dirname "$0")"
mkdir -p menubar
render() {  # render 名字 轨道色1 轨道色2 按钮x 按钮色1 按钮色2 有无表情
  local name=$1 c1=$2 c2=$3 kx=$4 k1=$5 k2=$6 face=$7 tmp
  tmp="$(mktemp -d)"
  cat > "$tmp/$name.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="72" height="36" viewBox="0 0 72 36">
  <defs>
    <linearGradient id="t" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="$c1"/><stop offset="1" stop-color="$c2"/></linearGradient>
    <linearGradient id="k" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="$k1"/><stop offset="1" stop-color="$k2"/></linearGradient>
  </defs>
  <rect x="1" y="3" width="70" height="30" rx="15" fill="url(#t)"/>
  <rect x="4" y="5" width="64" height="11" rx="5.5" fill="#FFFFFF" opacity="0.22"/>
  <circle cx="$kx" cy="19" r="13" fill="#3B4F8A" opacity="0.22"/>
  <circle cx="$kx" cy="18" r="13" fill="url(#k)"/>
  <circle cx="$kx" cy="18" r="13" fill="none" stroke="#FFFFFF" stroke-width="1.6" opacity="0.9"/>
  $( [ "$face" = 1 ] && printf '%s' "
  <circle cx=\"$((kx-4))\" cy=\"16.5\" r=\"1.7\" fill=\"#3A2E2A\"/><circle cx=\"$((kx+4))\" cy=\"16.5\" r=\"1.7\" fill=\"#3A2E2A\"/>
  <ellipse cx=\"$((kx-7))\" cy=\"21\" rx=\"2.4\" ry=\"1.4\" fill=\"#FF8FA3\" opacity=\"0.8\"/><ellipse cx=\"$((kx+7))\" cy=\"21\" rx=\"2.4\" ry=\"1.4\" fill=\"#FF8FA3\" opacity=\"0.8\"/>
  <path d=\"M$((kx-3)) 21.5 q3 3.2 6 0\" fill=\"none\" stroke=\"#3A2E2A\" stroke-width=\"1.5\" stroke-linecap=\"round\"/>" )
</svg>
SVG
  swift render-svg.swift "$tmp/$name.svg" "menubar/$name.png" 72 36; rm -rf "$tmp"
}
render menubar-api     "#8ED6C2" "#7CC8F0" 54 "#FFE08A" "#FFC94D" 1
render menubar-chatgpt "#F7B7CC" "#C9B6F0" 18 "#FFE08A" "#FFC94D" 1
render menubar-off     "#C9CDD3" "#B9BEC6" 36 "#E6E8EB" "#D2D5DA" 0
echo "已生成 $(pwd)/menubar/"
