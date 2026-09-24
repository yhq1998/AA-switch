#!/bin/bash
# 把 .app 打成带引导的 dmg：窗口 640x400、背景图画着“拖到 Applications”的箭头、两个图标摆在箭头两端。
#   ./make-dmg.sh "dist/AA Switch.app" "dist/AA Switch.dmg"
# 窗口布局靠 Finder 写进 dmg 里的 .DS_Store（osascript 控制 Finder，第一次会弹自动化授权）；
# Finder 那步失败就退回普通窗口，dmg 照样能用，只是没有背景图。签名和公证由 build.sh 负责。
set -eu
cd "$(dirname "$0")"
APP="$1"; DMG="$2"
APP_BASE="$(basename "$APP")"; VOLNAME="${APP_BASE%.app}"
[ -f icon/dmg/background.tiff ] && [ icon/dmg/background.tiff -nt icon/make-dmg-background.sh ] || icon/make-dmg-background.sh >/dev/null

WORK="$(mktemp -d)"; MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach "$MNT" -force -quiet 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/src/.background"
cp -R "$APP" "$WORK/src/"
ln -s /Applications "$WORK/src/Applications"
cp icon/dmg/background.tiff "$WORK/src/.background/background.tiff"
chflags hidden "$WORK/src/.background"
hdiutil create -volname "$VOLNAME" -srcfolder "$WORK/src" -ov -fs HFS+ -format UDRW -quiet "$WORK/rw.dmg"
MNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[ -d "$MNT" ] || { echo "挂载 dmg 失败" >&2; exit 1; }

# 已经挂着同名的盘时，新挂上的叫“AA Switch 1”，Finder 要按实际名字找
if ! osascript - "$(basename "$MNT")" "$APP_BASE" >/dev/null <<'OSA'
on run argv
  set diskName to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk diskName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      try
        set pathbar visible of container window to false
      end try
      set bounds of container window to {200, 120, 840, 548} -- 内容区 640x400，再加 28 的标题栏
      set opts to icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 112
      set text size of opts to 13
      set background picture of opts to file ".background:background.tiff"
      set position of item appName of container window to {170, 190}
      set position of item "Applications" of container window to {470, 190}
      -- 开了“显示隐藏文件”的人也会看到这两个，挪到窗口外面
      repeat with hiddenName in {".background", ".fseventsd", ".DS_Store"}
        try
          set position of item hiddenName of container window to {900, 900}
        end try
      end repeat
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
OSA
then
  echo "提示：没能用 Finder 设置 dmg 窗口布局（可能没给自动化权限），这次的 dmg 没有背景图。" >&2
fi
sync
hdiutil detach "$MNT" -quiet || { sleep 2; hdiutil detach "$MNT" -force -quiet; }
MNT=""
rm -f "$DMG"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"
