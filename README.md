<p align="center">
  <img src="menubar/icon/aa-switch.svg" width="160" alt="AA Switch icon">
</p>

<h1 align="center">AA Switch</h1>

<p align="center">
  Switch Codex and Claude Code between your account and your own API.<br>
  One click. Nothing lost.
</p>

<p align="center">
  <a href="https://aaswitch.omniapexroute.com">Website</a>
  &nbsp;·&nbsp;
  <a href="README.zh-CN.md">中文</a>
</p>

---

## Why "AA"?

**AA** stands for **API – Account**. AA Switch does exactly one thing: it flips Codex and Claude Code between your own **API** key and your official **Account**.

## What it does

AA Switch lives in your Mac's menu bar. Open it to see which side Codex and Claude Code are each on right now, and click to flip.

- **Two modes, one click.** Use your subscription, or route through your own API key. Switch back and forth as often as you like; Codex and Claude Code flip independently.
- **Your history comes with you.** Every conversation stays visible and usable on both sides.
- **No re-login.** AA Switch remembers your ChatGPT session, so coming back to your account doesn't mean signing in again. Your Claude account login is never touched at all.
- **Safe by default.** Settings are backed up before every switch and restored automatically if anything goes wrong.
- **One key, both tools.** Enter a gateway's key once; Codex and Claude Code share it.

## Install

1. Download **AA Switch.dmg** from [aaswitch.omniapexroute.com](https://aaswitch.omniapexroute.com) (or from the [Releases](https://github.com/yhq1998/AA-switch/releases) page).
2. Drag **AA Switch** into your Applications folder and open it.
3. Look for the little switch at the top right of your screen.

Requires macOS 13 or later on either Intel or Apple silicon (the app is a universal binary), and at least one of: the Codex desktop app, or Claude Code (terminal or IDE extension).

## Use

Click the switch in the menu bar.

- The menu has a **Codex** group and a **Claude Code** group. Each shows its current mode and where requests are going, with the active mode checked.
- Choose **Switch to API** or **Switch to account**. Codex closes and reopens by itself; it takes a few seconds. Claude Code needs no restart: new sessions in the terminal and in IDE extensions pick it up immediately.
- The first time you go to API, AA Switch asks for your API address and key. The key is stored in the macOS Keychain and never written to a file.
- The first time you switch Codex, macOS asks whether AA Switch may control Codex. Choose **Allow**; it needs this to restart Codex.

Turn on **Launch at login** in the menu and AA Switch is always there.

## Good to know

- If Codex is also running in a terminal or an IDE, close those first. AA Switch will remind you.
- If Codex asks you to sign in after switching back to your account, your session simply expired. Sign in once and you're set.
- Backups taken before every switch are kept in `~/.codex/codex-mode-backups` and `~/.claude/claude-mode-backups` (the latest 20). **Open backups** under each product's **More** menu takes you there.
- While Claude Code is on API, features that need your Claude account (publishing Artifacts, cloud sessions, /schedule, connectors) are unavailable until you switch back.
- The Claude Code switch covers both the terminal / IDE extensions and the Claude desktop app's Code tab. The desktop app forces its own login credential onto the Code sessions it starts, so switching to API also moves the whole desktop app into its third-party inference mode and restarts it, syncing the session list across. In API mode the desktop app's regular Chat is unavailable; switching back to the account restores it.

---

<sub>Developers and maintainers: see [DEVELOPMENT.md](DEVELOPMENT.md).</sub>
