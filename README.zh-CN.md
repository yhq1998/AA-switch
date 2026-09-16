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

AA Switch 住在 Mac 的菜单栏里，点开就能看到 Codex 和 Claude Code 现在各走的是哪边。再点一下就切。

- **两种模式，一键切换。** 用订阅账号，或者走你自己的 API key，想换随时换。Codex 和 Claude Code 各自独立切换。
- **历史会话跟着走。** 切换前后，所有对话都还在，都能继续聊。
- **不用重新登录。** AA Switch 记得你的 ChatGPT 登录态，切回账号时不用再登一次；Claude 账号的登录态则根本不会被动。
- **默认就安全。** 每次切换前先备份设置，出了问题自动恢复。
- **一个 key 两边用。** 同一个网关的 key 只需要填一次，Codex 和 Claude Code 共用。

## 安装

1. 到官网 [aaswitch.omniapexroute.com](https://aaswitch.omniapexroute.com) 下载 **AA Switch.dmg**（国内直连；也可从 [Releases](https://github.com/yhq1998/AA-switch/releases) 下载）。
2. 把 **AA Switch** 拖进“应用程序”文件夹，打开它。
3. 屏幕右上角会出现一个小开关。

需要 macOS 13 或更新版本。Codex 桌面应用、Claude Code（终端或 IDE 插件）至少装一个。

## 使用

点一下菜单栏里的开关。

- 菜单分 **Codex** 和 **Claude Code** 两组，各自显示当前模式和请求发往哪里，当前所在的模式打着勾。
- 选择 **切换到 API 模式** 或 **切换到账号**。Codex 会自动退出并重新打开，几秒钟就好；Claude Code 不用重启，终端和 IDE 插件里新开的会话立即生效。
- 第一次切到 API 时，AA Switch 会请你填写 API 地址和 key。key 只存在 macOS 钥匙串里，不会写进任何文件。
- 第一次切换 Codex 时，macOS 会问是否允许 AA Switch 控制 Codex。选 **允许**，它需要这个权限来重启 Codex。

在菜单里打开 **开机自动启动**，AA Switch 就一直都在。

## 小提示

- 如果终端或 IDE 里也开着 Codex，先把它们关掉。AA Switch 会提醒你。
- 切回账号后如果 Codex 让你登录，只是登录态过期了，登一次就好。
- 每次切换的备份都在 `~/.codex/codex-mode-backups` 和 `~/.claude/claude-mode-backups`，菜单里的 **打开备份文件夹** 可以直达。
- Claude Code 走 API 时，依赖 Claude 账号的功能（发布 Artifact、云端会话、/schedule、connectors）暂时不可用，切回账号就恢复。
- Claude Code 的开关同时管终端 / IDE 插件和 Claude 桌面应用的 Code 标签。桌面应用启动 Code 会话时会强制使用自己的登录凭据，所以切到 API 时 AA Switch 会把整个桌面应用切到第三方推理模式并重启它，会话列表自动同步；API 模式下桌面应用的普通聊天不可用，切回账号即恢复。

---

<sub>开发者与维护者请看 [DEVELOPMENT.md](DEVELOPMENT.md)。</sub>
