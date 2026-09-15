<p align="center">
  <img src="menubar/icon/aa-switch.svg" width="160" alt="AA Switch 图标">
</p>

<h1 align="center">AA Switch</h1>

<p align="center">
  让 Codex 在 ChatGPT 账号和你自己的 API 之间一键切换。<br>
  会话不丢，登录不掉。
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

## 它能做什么

AA Switch 住在 Mac 的菜单栏里，一眼就能看到 Codex 现在走的是哪边。点一下就切。

- **两种模式，一键切换。** 用 ChatGPT 订阅，或者让 Codex 走你自己的 API key，想换随时换。
- **历史会话跟着走。** 切换前后，所有对话都还在，都能继续聊。
- **不用重新登录。** AA Switch 记得你的 ChatGPT 登录态，切回账号时不用再登一次。
- **默认就安全。** 每次切换前先备份设置，出了问题自动恢复。

## 安装

1. 从 [Releases](https://github.com/yhq1998/AA-switch/releases) 页面下载 **AA Switch.dmg**。
2. 把 **AA Switch** 拖进“应用程序”文件夹，打开它。
3. 屏幕右上角会出现一个小开关。

需要 macOS 13 或更新版本，以及 Codex 桌面应用。

## 使用

点一下菜单栏里的开关。

- 菜单顶部显示当前模式和请求发往哪里。
- 选择 **切换到 API 模式** 或 **切换到 ChatGPT 账号**。Codex 会自动退出并重新打开，几秒钟就好。
- 第一次切到 API 时，AA Switch 会请你填写 API 地址和 key。key 只存在 macOS 钥匙串里，不会写进任何文件。
- 第一次切换时，macOS 会问是否允许 AA Switch 控制 Codex。选 **允许**，它需要这个权限来重启 Codex。

在菜单里打开 **开机自动启动**，AA Switch 就一直都在。

## 小提示

- 如果终端或 IDE 里也开着 Codex，先把它们关掉。AA Switch 会提醒你。
- 切回账号后如果 Codex 让你登录，只是登录态过期了，登一次就好。
- 每次切换的备份都在 `~/.codex/codex-mode-backups`，菜单里的 **打开备份文件夹** 可以直达。

---

<sub>开发者与维护者请看 [DEVELOPMENT.md](DEVELOPMENT.md)。</sub>
