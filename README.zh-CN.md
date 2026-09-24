<p align="center">
  <img src="menubar/icon/aa-switch.svg" width="160" alt="AA Switch 图标">
</p>

<h1 align="center">AA Switch</h1>

<p align="center">
  让 Codex 和 Claude Code 在账号和你自己的 API 之间一键切换。<br>
  会话不丢，登录不掉。
</p>

<p align="center">
  <a href="https://aaswitch.omniapexroute.com">官网</a>
  &nbsp;·&nbsp;
  <a href="README.md">English</a>
</p>

---

## 为什么叫 "AA"？

**AA** 是 **API – Account** 的缩写。AA Switch 只做一件事：让 Codex 和 Claude Code 在你自己的 **API** key 和官方 **账号（Account）** 之间来回切换。

## 它能做什么

AA Switch 住在 Mac 的菜单栏（或 Windows 的托盘）里，点开就能看到 Codex 和 Claude Code 现在各走的是哪边。再点一下就切。

<table align="center">
  <tr>
    <td align="center" valign="top"><img src="docs/screenshots/macos-menu.png" width="330" alt="macOS 菜单栏里的 AA Switch 菜单"><br><sub>macOS</sub></td>
    <td align="center" valign="top"><img src="docs/screenshots/windows-menu.png" width="330" alt="Windows 托盘里的 AA Switch 菜单"><br><sub>Windows</sub></td>
  </tr>
</table>

- **两种模式，一键切换。** 用订阅账号，或者走你自己的 API key，想换随时换。Codex 和 Claude Code 各自独立切换。
- **历史会话跟着走。** 切换前后，所有对话都还在，都能继续聊。
- **不用重新登录。** AA Switch 记得你的 ChatGPT 登录态，切回账号时不用再登一次；Claude 账号的登录态则根本不会被动。
- **默认就安全。** 每次切换前先备份设置，出了问题自动恢复。
- **一个 key 两边用。** 同一个网关的 key 只需要填一次，Codex 和 Claude Code 共用。

## 安装

### macOS

1. 到官网 [aaswitch.omniapexroute.com](https://aaswitch.omniapexroute.com) 下载 **AA Switch.dmg**（国内直连；也可从 [Releases](https://github.com/yhq1998/AA-switch/releases) 下载）。
2. 打开 dmg，把 **AA Switch** 拖进“应用程序”文件夹，再从“应用程序”打开它。直接在 dmg 里双击也行，它会提示把自己装进“应用程序”并推出安装盘。
3. 屏幕右上角会出现一个小开关。

需要 macOS 13 或更新版本，Intel 和 Apple 芯片都支持（通用二进制）。Codex 桌面应用、Claude Code（终端或 IDE 插件）至少装一个。

### Windows

1. 到官网 [aaswitch.omniapexroute.com](https://aaswitch.omniapexroute.com) 下载 **AA Switch.exe**（也可从 [Releases](https://github.com/yhq1998/AA-switch/releases) 下载）。
2. 把它放到一个固定的位置（比如“文档”或 `D:\Tools`），双击运行。免安装，也不用装任何运行时。
3. 屏幕右下角的托盘里会出现一个笑脸图标（可能收在 **^** 里，可以把它拖出来）。

需要 Windows 10 或 11（64 位）。Windows 版目前没有代码签名，第一次运行可能被 SmartScreen 拦下：点 **更多信息 → 仍要运行**。
Codex（命令行或 IDE 插件）、Claude Code（终端或 IDE 插件）至少装一个。

<p align="center">
  <img src="docs/screenshots/windows-onboarding.png" width="548" alt="第一次打开时的初始设置">
</p>

## 使用

点一下菜单栏（Windows 是托盘）里的图标。

- 菜单分 **Codex** 和 **Claude Code** 两组，每组一行 **账号 | API** 开关，亮着的那格就是当前模式，下面的小字写着请求发往哪里。
- 点另一格就切换。macOS 上 Codex 会自动退出并重新打开，几秒钟就好；Claude Code 不用重启，终端和 IDE 插件里新开的会话立即生效。
- 第一次切到 API 时，AA Switch 会请你填写 API 地址和 key，保存前会用 key 试一下这个地址通不通。key 只存在 macOS 钥匙串（Windows 是凭据管理器）里，不会写进任何文件。
- 第一次切换 Codex 时，macOS 会问是否允许 AA Switch 控制 Codex。选 **允许**，它需要这个权限来重启 Codex。

<p align="center">
  <img src="docs/screenshots/windows-configure.png" width="536" alt="配置 API 地址和 key 的表单">
</p>

在菜单里打开 **开机自动启动**，AA Switch 就一直都在。有新版本时菜单底部会提示，点一下就自动更新。

### Windows 版暂时的不同

- 切换 Codex 前要自己先关掉 Codex（应用、命令行和 IDE 里的会话），AA Switch 不会替你退出和重开；没关的话它会提醒你，什么都不会改。
- Claude 桌面应用的 Code 标签还不能切到 API（见下面“小提示”的最后一条），终端和 IDE 插件里的 Claude Code 不受影响。
- 开机自动启动记的是 exe 当时所在的位置，打开它之后就别再移动 exe 了。

## 小提示

- 如果终端或 IDE 里也开着 Codex，先把它们关掉。AA Switch 会提醒你。
- 切回账号后如果 Codex 让你登录，只是登录态过期了，登一次就好。
- 每次切换前的备份在 `~/.codex/codex-mode-backups` 和 `~/.claude/claude-mode-backups`（Windows 上 `~` 是 `C:\Users\你的用户名`；只留最近 20 次），各自"更多"里的 **打开备份文件夹** 可以直达。
- Claude Code 走 API 时，依赖 Claude 账号的功能（发布 Artifact、云端会话、/schedule、connectors）暂时不可用，切回账号就恢复。
- macOS 上，Claude Code 的开关同时管终端 / IDE 插件和 Claude 桌面应用的 Code 标签。桌面应用启动 Code 会话时会强制使用自己的登录凭据，所以切到 API 时 AA Switch 会把整个桌面应用切到第三方推理模式并重启它，会话列表自动同步；API 模式下桌面应用的普通聊天不可用，切回账号即恢复。

---

<sub>开发者与维护者请看 [DEVELOPMENT.md](DEVELOPMENT.md)。</sub>
