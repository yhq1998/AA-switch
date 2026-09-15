<p align="center">
  <img src="menubar/icon/aa-switch.svg" width="160" alt="AA Switch icon">
</p>

<h1 align="center">AA Switch</h1>

<p align="center">
  Switch Codex between your ChatGPT account and your own API.<br>
  One click. Nothing lost.
</p>

<p align="center">
  <a href="https://aaswitch.omniapexroute.com">Website</a>
  &nbsp;·&nbsp;
  <a href="README.zh-CN.md">中文</a>
</p>

---

## Why "AA"?

**AA** stands for **API – Account**. AA Switch does exactly one thing: it flips Codex between your own **API** key and your ChatGPT **Account**.

## What it does

AA Switch lives in your Mac's menu bar and shows which side Codex is on right now. Click it to flip.

- **Two modes, one click.** Use your ChatGPT subscription, or route Codex through your own API key. Switch back and forth as often as you like.
- **Your history comes with you.** Every conversation stays visible and usable on both sides.
- **No re-login.** AA Switch remembers your ChatGPT session, so coming back to your account doesn't mean signing in again.
- **Safe by default.** Settings are backed up before every switch and restored automatically if anything goes wrong.

## Install

1. Download **AA Switch.dmg** from [aaswitch.omniapexroute.com](https://aaswitch.omniapexroute.com) (or from the [Releases](https://github.com/yhq1998/AA-switch/releases) page).
2. Drag **AA Switch** into your Applications folder and open it.
3. Look for the little switch at the top right of your screen.

Requires macOS 13 or later and the Codex desktop app.

## Use

Click the switch in the menu bar.

- The top of the menu tells you the current mode and where requests are going.
- Choose **Switch to API** or **Switch to ChatGPT account**. Codex closes and reopens by itself; it takes a few seconds.
- The first time you go to API, AA Switch asks for your API address and key. The key is stored in the macOS Keychain and never written to a file.
- The first time you switch, macOS asks whether AA Switch may control Codex. Choose **Allow**; it needs this to restart Codex.

Turn on **Launch at login** in the menu and AA Switch is always there.

## Good to know

- If Codex is also running in a terminal or an IDE, close those first. AA Switch will remind you.
- If Codex asks you to sign in after switching back to your account, your session simply expired. Sign in once and you're set.
- Backups from every switch are kept in `~/.codex/codex-mode-backups`. **Open backups** in the menu takes you there.

---

<sub>Developers and maintainers: see [DEVELOPMENT.md](DEVELOPMENT.md).</sub>
