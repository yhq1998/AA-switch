README 里的截图，用的都是演示数据（地址 `api.example.com`），不含任何真实的网关地址或账号。界面改了之后按下面的办法重出一遍覆盖这里即可。

## Windows（三张）

由 CI 生成：`.github/workflows/windows.yml` 里 `"AA Switch.exe" --render <目录> --demo` 用固定的演示数据把界面画成 PNG，在 `shots` 产物的 `demo/` 下
（`gh run download <运行号> -n shots`）。`menu.png → windows-menu.png`，`configure-codex.png → windows-configure.png`，`onboarding.png → windows-onboarding.png`。

## macOS（`macos-menu.png`）

程序自己拍：设了环境变量 `AASWITCH_RENDER_MENU=输出.png` 时，它等状态读完后把菜单弹在屏幕中间、后面垫一个渐变色的窗口，拍下来然后退出
（拍自己的窗口不需要屏幕录制权限，别的应用不会被拍进去）。配合 `CODEX_HOME` / `CLAUDE_CONFIG_DIR` 指到一份演示数据，不碰自己的真实配置：

```bash
D=$(mktemp -d); export CODEX_HOME=$D/.codex CLAUDE_CONFIG_DIR=$D/.claude; mkdir -p "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
# 1. 用脚本造一份“Codex 在 API 模式、Claude Code 在账号模式”的演示数据（假 key 会进钥匙串，最后一步删掉）
export CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex CODEX_MODE_FORCE=1 CODEX_MODE_NO_REOPEN=1 CODEX_MODE_NONINTERACTIVE=1
printf 'sk-demo-not-a-real-key\n' | CODEX_MODE_BASE_URL=https://api.example.com/v1 CODEX_MODE_KEY_STDIN=1 bash codex-mode.sh configure
bash codex-mode.sh api
# 2. 程序只允许一个实例，所以用一份换了 bundle id 的副本来拍，不用退出正在用的那个
cp -R "/Applications/AA Switch.app" "$D/" && APP="$D/AA Switch.app"
(cd menubar && swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/AASwitch" AASwitch.swift)      # 换成当前源码编出来的
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.omniapexroute.aaswitch.demo" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"; defaults write com.omniapexroute.aaswitch.demo onboardingDone -bool true
AASWITCH_RENDER_MENU="$PWD/docs/screenshots/macos-menu.png" "$APP/Contents/MacOS/AASwitch"
# 3. 清理
security delete-generic-password -s "codex-mode:api.example.com"; defaults delete com.omniapexroute.aaswitch.demo; rm -rf "$D"
```
