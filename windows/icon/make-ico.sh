#!/bin/bash
# 由 macOS 版的图标 SVG 生成 Windows 用的两个 .ico（需要在 macOS 上跑：用 ../../menubar/icon/render-svg.swift 渲染）：
#   app.ico   程序图标：整个应用图标，去掉 macOS 图标四周的留白
#   tray.ico  托盘图标：只取那只笑脸按钮——托盘图标只有 16～32 像素，整个开关缩下去看不清
# 生成的 .ico 提交进仓库，Windows 上的 CI 不用再生成。
set -eu
cd "$(dirname "$0")"
SRC=../../menubar/icon/aa-switch.svg
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sed 's/width="1024" height="1024" viewBox="0 0 1024 1024"/width="824" height="824" viewBox="100 100 824 824"/' "$SRC" > "$tmp/app.svg"
# 托盘图标：只留 <defs> 和“按钮（笑脸）”之后的元素，四角透明
python3 - "$SRC" > "$tmp/tray.svg" <<'PY'
import re, sys
svg = open(sys.argv[1], encoding='utf-8').read()
defs = re.search(r'<defs>.*?</defs>', svg, re.S).group(0)
knob = svg.split('<!-- 按钮（笑脸） -->', 1)[1]
print('<svg xmlns="http://www.w3.org/2000/svg" width="272" height="272" viewBox="526 386 272 272">' + defs + knob)
PY
for name in app tray; do
  for s in 16 20 24 32 40 48 64 256; do swift ../../menubar/icon/render-svg.swift "$tmp/$name.svg" "$tmp/$name-$s.png" $s $s; done
  python3 - "$name.ico" "$tmp"/$name-{16,20,24,32,40,48,64,256}.png <<'PY'
import struct, sys
out, files = sys.argv[1], sys.argv[2:]
images = [open(f, 'rb').read() for f in files]
sizes = [struct.unpack('>I', d[16:20])[0] for d in images]   # PNG IHDR 里的宽度
header = struct.pack('<HHH', 0, 1, len(images))
offset = 6 + 16 * len(images)
entries = b''
for size, data in zip(sizes, images):
    entries += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
open(out, 'wb').write(header + entries + b''.join(images))
PY
done
ls -la app.ico tray.ico
