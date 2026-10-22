# Claude Switcher environment checks

Source: https://github.com/YOURSJEYO/claude-switcher

Pinned commit: `303cd1057cc1ab2f24cfac5b4c0a43094011caa1` (MIT).
`UPSTREAM.json` records original paths, SHA256 hashes and extraction boundaries.

- `upstream/core/claude-switch.sh` is the complete, unchanged source retained for comparison. It is **not executed or bundled**.
- `checks.sh` consists of two verbatim source ranges: the detection helpers before `check()`, and `webrtc_test()` / `checkdetail()`. All 14 original checks, thresholds and output strings are preserved.
- `stun-probe.py` and `LICENSE` are unchanged upstream files.
- `../../claude-account-environment.sh` only supplies configuration, checks the Python prerequisite, redirects local detection history, and invokes `checkdetail()`.

No upstream installer, automatic repair, updater, account snapshots or daemon is invoked. The original checks still inspect an independently installed `local.claude-bodyguard`; without it the original result is `保镖=fail:未安装`.

The upstream detector assumes fake-IP/TUN, disabled IPv6, matching country/timezone/locale and English Claude desktop language. These are the upstream's criteria, not a guarantee of account availability or protection against IP disclosure. The original `WebRTC` row is a Python UDP/STUN probe; it does not execute browser WebRTC.

Detection contacts Cloudflare, ipinfo.io, Anthropic/Claude, and the STUN servers listed in the original probe. It stores `lastip`, `iphistory.log` (48-hour window), `last-check.txt`, and a copy of the unchanged STUN probe under `~/Library/Application Support/AA Switch/claude-account-environment/`. It does not access login credentials. IP history is local and remains until that directory is deleted; old entries are pruned by the original code during subsequent successful checks. Exported reports contain IP information and are only saved on request.

Run `python3 -m unittest discover -s tests -p test_claude_account_environment.py` from the repository root to verify provenance and exercise all original checks with isolated command substitutes. No real network probes or process termination are used in those tests.
