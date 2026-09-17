#!/bin/bash
# 构建 Windows 版的发布包（在 macOS 上交叉编译即可，需要 brew install dotnet）：
#   VERSION=0.2.0 UPDATE_URL=https://aaswitch.example.com/download/latest.json ./build.sh
# 产物在 dist/：
#   AA Switch.exe   托盘程序，单文件、自带 .NET 运行时，用户不用装任何东西
#   aaswitch.exe    命令行版（排查问题用）
#   version.txt     版本号，site/deploy.sh 用它写 latest.json 的 windows 段
# UPDATE_URL 是官网 latest.json 的地址，写进程序里用来检查更新；不设则这个包不检查更新。
# VERSION 不设则用 src/AASwitch.Tray/AASwitch.Tray.csproj 里的 <Version>。
set -eu
cd "$(dirname "$0")"
export DOTNET_ROOT="${DOTNET_ROOT:-/opt/homebrew/opt/dotnet/libexec}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
VERSION="${VERSION:-$(sed -n 's/.*<Version>\(.*\)<\/Version>.*/\1/p' src/AASwitch.Tray/AASwitch.Tray.csproj | head -n1)}"
[ -n "$VERSION" ] || { echo "没有版本号：请设置 VERSION=x.y.z" >&2; exit 1; }
case "${UPDATE_URL:-}" in ''|https://*) ;; *) echo "UPDATE_URL 必须是 https 地址" >&2; exit 1 ;; esac

echo "· 测试"
dotnet test -c Release --nologo -v q | tail -n 1
rm -rf dist
COMMON=(-c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none "-p:Version=$VERSION" -v q)
echo "· 托盘程序 $VERSION"
dotnet publish src/AASwitch.Tray "${COMMON[@]}" -p:EnableCompressionInSingleFile=true "-p:UpdateUrl=${UPDATE_URL:-}" -o dist >/dev/null
echo "· 命令行"
dotnet publish src/AASwitch.Cli "${COMMON[@]}" -p:PublishTrimmed=true -o dist >/dev/null
printf '%s\n' "$VERSION" > dist/version.txt
ls -lh dist | sed 1d
[ -n "${UPDATE_URL:-}" ] || echo "提示：没有设置 UPDATE_URL，这个包不会检查更新。"
