# AA Switch Windows 版（开发中）

macOS 版是「Swift 菜单栏壳 + 两个 bash 脚本」；Windows 上没有 bash、钥匙串和 osascript，所以这里用 C#（.NET 10）把同样的逻辑重写了一遍，
macOS 那边的脚本和 App 不受影响。

| 目录 | 内容 |
|---|---|
| `src/AASwitch.Core` | 切换逻辑，跨平台（不依赖 Windows API 的部分在 macOS 上也能编译和测试） |
| `src/AASwitch.Cli` | 命令行 `aaswitch.exe`，验证阶段先用它；以后的托盘程序调用同一套 Core |
| `tests/AASwitch.Core.Tests` | 单元测试，用临时目录当 home，不碰真实配置 |
| `src/AASwitch.Tray` | 托盘程序（WinForms，只能在 Windows 上运行；macOS 上靠 `EnableWindowsTargeting` 也能编译）。`--render <目录>` 把界面画成 PNG，`--click <codex\|claude> <api\|account>` 不显示界面走一遍切换，都是给 CI 用的 |
| `icon/` | `app.ico` / `tray.ico`，由 macOS 版的 SVG 生成（`make-ico.sh`，要在 macOS 上跑），生成物提交进仓库 |
| `probe.ps1` | 只读的环境探测脚本，用来确认 Windows 上各家工具的数据路径 |

与 macOS 版保持一致的地方：配置文件 `~\.claude\claude-mode.conf`（key=value）、备份目录 `~\.claude\claude-mode-backups\<时间>\`（留 20 次）、
key 的条目名 `codex-mode:域名`（存在 Windows 凭据管理器的“普通凭据”里，Codex 和 Claude Code 共用）。

## 进度

- [x] Claude Code（终端和 IDE 插件）切换：`aaswitch claude api|account|status|configure|…`
- [x] Codex 切换：`aaswitch codex api|chatgpt|fix-threads|status|…`（config.toml 的 provider 别名、会话和 state_*.sqlite 的 provider 统一、
      ChatGPT 登录态存档与恢复、失败回滚）。与 macOS 的 codex-mode.sh 用同一份数据做过对照，产出一致。切换前要自己关掉 Codex 应用和 codex 进程，
      自动退出 / 重开应用放在下一步
- [ ] Claude 桌面应用的第三方推理模式、会话列表同步（等 probe 结果确认路径）
- [x] 托盘程序 `AA Switch.exe`（`src/AASwitch.Tray`，WinForms）：每个产品一行“账号 | API”分段控件、配置表单（规范化地址，用 key 探测网关：401/403 拦下，
      连不上或 404 可坚持保存）、初始设置、开机自启（HKCU 的 Run 项）、导出诊断信息、单实例。菜单该显示什么由 Core 的 `TrayView` 决定，有单元测试。
      还没有的：切换前已打开的终端会话提醒、深色菜单
- [x] 应用内更新：每 6 小时和手动“检查更新”读官网 latest.json 的 `windows` 段，有新版就下载、校验 sha256、把自己改名成 `.old` 再放入新版并重新打开。
      没有代码签名，所以只信 https、且下载地址必须和 latest.json 同一个主机
- [x] 发布：`build.sh` 出发布包，`site/deploy.sh` 顺带上传并写 latest.json 的 `windows` 段，官网按访客系统给下载按钮（见 DEVELOPMENT.md）
- [x] 安装：从安装目录以外双击时提议装到 `%LOCALAPPDATA%\Programs\AA Switch\`（开始菜单快捷方式、“设置 → 应用”里的卸载入口、开机自启改指向新位置，删掉“下载”里的那份）；
      `--install` / `--uninstall [--quiet]` 不问直接装 / 卸。用户自己打开时（包括已经在运行时再打开）弹出一个窗口，内容由托盘菜单原样转换，
      顶上说明图标可能收在“^”里；开机自启带 `--autostart`，安静地待在托盘
- [ ] 代码签名（没签名的 exe 首次运行会被 SmartScreen 拦一下）

## 开发（macOS 上即可）

```bash
brew install dotnet
cd windows
dotnet test
dotnet publish src/AASwitch.Cli -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:PublishTrimmed=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -o out

# 端到端（真的 claude / codex + 本地假网关），本机用临时目录，不碰自己的配置；先按上面的参数发布一份 -r osx-arm64 到 out-mac
E2E_ISOLATED=1 node e2e/claude-e2e.mjs out-mac/aaswitch
E2E_ISOLATED=1 CODEX_BIN=/Applications/ChatGPT.app/Contents/Resources/codex node e2e/codex-e2e.mjs out-mac/aaswitch
```

推到 GitHub 后 `.github/workflows/windows.yml` 会在 Windows 机器上跑测试（含真实的凭据管理器读写）、两个端到端、托盘的 `--click` 和 `--render`，
再真的启动一次托盘程序并截屏。产物：`aaswitch-windows-x64`（两个 exe）和 `shots`（界面截图 + 探测结果，很小，`gh run download <id> -n shots` 取回来看）。

## 在 Windows 上验证

1. 先打开 Codex 和 Claude 桌面应用，然后跑探测脚本，把生成的 `aa-switch-probe.txt` 发回来（不含任何 key）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File probe.ps1
   ```

2. 验证 Claude Code 切换：

   ```powershell
   .\aaswitch.exe claude status
   .\aaswitch.exe claude api        # 首次会问地址和 key
   claude                           # 新开的会话应该走网关
   .\aaswitch.exe claude account
   claude                           # 回到账号登录
   ```

   出问题时把命令输出和 `~\.claude\settings.json` 的 env 块（去掉 token）贴回来；每次切换前的原文件在 `~\.claude\claude-mode-backups\`。
