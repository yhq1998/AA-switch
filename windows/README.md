# AA Switch Windows 版（开发中）

macOS 版是「Swift 菜单栏壳 + 两个 bash 脚本」；Windows 上没有 bash、钥匙串和 osascript，所以这里用 C#（.NET 10）把同样的逻辑重写了一遍，
macOS 那边的脚本和 App 不受影响。

| 目录 | 内容 |
|---|---|
| `src/AASwitch.Core` | 切换逻辑，跨平台（不依赖 Windows API 的部分在 macOS 上也能编译和测试） |
| `src/AASwitch.Cli` | 命令行 `aaswitch.exe`，验证阶段先用它；以后的托盘程序调用同一套 Core |
| `tests/AASwitch.Core.Tests` | 单元测试，用临时目录当 home，不碰真实配置 |
| `probe.ps1` | 只读的环境探测脚本，用来确认 Windows 上各家工具的数据路径 |

与 macOS 版保持一致的地方：配置文件 `~\.claude\claude-mode.conf`（key=value）、备份目录 `~\.claude\claude-mode-backups\<时间>\`（留 20 次）、
key 的条目名 `codex-mode:域名`（存在 Windows 凭据管理器的“普通凭据”里，Codex 和 Claude Code 共用）。

## 进度

- [x] Claude Code（终端和 IDE 插件）切换：`aaswitch claude api|account|status|configure|…`
- [ ] Codex 切换（config.toml、auth.json、会话的 model_provider、state_*.sqlite）
- [ ] Claude 桌面应用的第三方推理模式、会话列表同步（等 probe 结果确认路径）
- [ ] 托盘程序、配置表单、开机自启
- [ ] 自更新、官网下载按钮、deploy.sh

## 开发（macOS 上即可）

```bash
brew install dotnet
cd windows
dotnet test
dotnet publish src/AASwitch.Cli -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:PublishTrimmed=true -p:DebugType=none -o out
```

推到 GitHub 后 `.github/workflows/windows.yml` 会在 Windows 机器上跑测试（含真实的凭据管理器读写）并产出 `aaswitch-windows-x64`。

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
