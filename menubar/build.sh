#!/bin/bash
# 构建 AA Switch：编译通用二进制、打包 .app（自带 codex-mode.sh、claude-mode.sh 和默认配置）、签名、打 dmg、公证。
# 只需要 Xcode Command Line Tools；同事的机器不需要任何开发工具。
#
#   开发 / 内部测试（ad-hoc 签名，产出 dist/AASwitch.app.tar.gz 供 setup.sh 用）：
#     ./build.sh
#   正式发布（Developer ID 签名 + 公证，产出 dist/AA Switch.dmg）：
#     SIGN_IDENTITY="Developer ID Application: 公司名 (TEAMID)" NOTARY_PROFILE=aaswitch ./build.sh
#
# 可用环境变量（都有默认值）：
#   APP_NAME      应用名，默认 "AA Switch"
#   BUNDLE_ID     默认 com.omniapexroute.aaswitch（发出去后不要再改）
#   VERSION       默认取 codex-mode.sh 里的 CODEX_MODE_VERSION
#   SIGN_IDENTITY 签名身份；不设或 "-" 为 ad-hoc
#   NOTARY_PROFILE  xcrun notarytool store-credentials 保存的凭据名；设了才公证
#   DEFAULT_BASE_URL / DEFAULT_HEADERS / DEFAULT_LEGACY_KEYCHAIN_SERVICE  打进包里的默认配置（同 setup.sh）
#   UPDATE_URL    官网上 latest.json 的地址（site/deploy.sh 会生成它）；设了 App 会每天检查一次，有新版本就在菜单里提示
set -eu
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo "需要 swiftc：xcode-select --install" >&2; exit 1; }

# 打包前先在一个空的临时家目录里把两个脚本的主要路径跑一遍（模拟新用户），不通过就不出包
echo "· 冒烟测试"
../smoke-test.sh || { echo "冒烟测试没有通过，已停止打包。" >&2; exit 1; }

APP_NAME="${APP_NAME:-AA Switch}"
EXEC_NAME="${EXEC_NAME:-AASwitch}"
BUNDLE_ID="${BUNDLE_ID:-com.omniapexroute.aaswitch}"
SCRIPT_VERSION="$(sed -n 's/^CODEX_MODE_VERSION="\([^"]*\)".*/\1/p' ../codex-mode.sh | head -n1)"
VERSION="${VERSION:-${SCRIPT_VERSION:-1.0.0}}"
BUILD="$(date +%Y%m%d%H%M)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
COPYRIGHT="${COPYRIGHT:-© $(date +%Y)}"
UPDATE_URL="${UPDATE_URL:-}"

OUT=dist; APP="$OUT/$APP_NAME.app"; RES="$APP/Contents/Resources"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$RES"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup_app() {  # 打包完就删掉解包的 .app 并从 LaunchServices 注销，否则 Spotlight / 启动台会多出一份
  "$LSREGISTER" -u "$(cd "$OUT" && pwd)/$APP_NAME.app" >/dev/null 2>&1 || true
  rm -rf "$APP"
}

echo "· 编译（arm64 + x86_64）"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -o "$OUT/$EXEC_NAME-$arch" AASwitch.swift
done
lipo -create -output "$APP/Contents/MacOS/$EXEC_NAME" "$OUT/$EXEC_NAME-arm64" "$OUT/$EXEC_NAME-x86_64"
rm -f "$OUT/$EXEC_NAME-arm64" "$OUT/$EXEC_NAME-x86_64"

echo "· 打包资源"
[ -f icon/AppIcon.icns ] && [ icon/AppIcon.icns -nt icon/aa-switch.svg ] || icon/make-icns.sh >/dev/null
[ -f icon/menubar/menubar.png ] && [ icon/menubar/menubar.png -nt icon/make-menubar.sh ] || icon/make-menubar.sh >/dev/null
cp icon/AppIcon.icns "$RES/AppIcon.icns"
cp icon/menubar/menubar.png icon/menubar/product-*.png "$RES/"
cp ../codex-mode.sh "$RES/codex-mode.sh"
cp ../claude-mode.sh "$RES/claude-mode.sh"
: > "$RES/defaults.conf"
[ -n "${DEFAULT_BASE_URL:-}" ] && echo "base_url=${DEFAULT_BASE_URL%/}" >> "$RES/defaults.conf"
[ -n "${DEFAULT_HEADERS:-}" ] && echo "headers=$DEFAULT_HEADERS" >> "$RES/defaults.conf"
[ -n "${DEFAULT_LEGACY_KEYCHAIN_SERVICE:-}" ] && echo "legacy_keychain_service=$DEFAULT_LEGACY_KEYCHAIN_SERVICE" >> "$RES/defaults.conf"
sed -e "s|@APP_NAME@|$APP_NAME|g" -e "s|@EXEC_NAME@|$EXEC_NAME|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
    -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" -e "s|@COPYRIGHT@|$COPYRIGHT|g" -e "s|@UPDATE_URL@|$UPDATE_URL|g" Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "· ad-hoc 签名"
  codesign --force --sign - "$APP"
  tar -C "$OUT" -czf "$OUT/AASwitch.app.tar.gz" "$APP_NAME.app"
  cleanup_app
  echo "已生成 $OUT/AASwitch.app.tar.gz（内部测试用；正式发布请设置 SIGN_IDENTITY）"
  exit 0
fi

echo "· Developer ID 签名（Hardened Runtime）"
codesign --force --timestamp --options runtime --entitlements entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "· 公证 App（先公证并装订 App，dmg 里的副本离线也能通过检查）"
  ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
  xcrun notarytool submit "$STAGE/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait | grep -E "status:|id:" | tail -2
  xcrun stapler staple "$APP" | tail -1
fi

echo "· 打 dmg"
mkdir -p "$STAGE/dmg"; cp -R "$APP" "$STAGE/dmg/"; ln -s /Applications "$STAGE/dmg/Applications"
DMG="$OUT/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE/dmg" -ov -format UDZO -quiet "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
tar -C "$OUT" -czf "$OUT/AASwitch.app.tar.gz" "$APP_NAME.app"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "· 公证 dmg"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | grep -E "status:|id:" | tail -2
  xcrun stapler staple "$DMG" | tail -1
  spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
  echo "已生成并公证：$DMG"
else
  echo "已生成 $DMG（未公证；设置 NOTARY_PROFILE 可自动公证）"
fi
cleanup_app
