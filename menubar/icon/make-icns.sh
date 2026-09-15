#!/bin/bash
# 由 aa-switch.svg 生成 AppIcon.icns（只用 macOS 自带的 swift、sips、iconutil）
set -eu
cd "$(dirname "$0")"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swift render-svg.swift aa-switch.svg "$WORK/aa-switch.svg.png" 1024 1024
mkdir -p "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/aa-switch.svg.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/aa-switch.svg.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o AppIcon.icns
echo "已生成 $(pwd)/AppIcon.icns"
