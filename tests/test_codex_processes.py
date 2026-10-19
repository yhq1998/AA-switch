"""Replay the actual switch process guard without touching live processes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "codex-mode.sh").read_text()
START = SOURCE.index("app_running()")
GUARD = SOURCE[START:SOURCE.index("\nauth_mode()", START)]

# A process table row is: uid pid name. All process operations are shell
# functions so a regression can never signal a real desktop or IDE session.
FAKES = r'''
set -eu
APP_NAME=ChatGPT
say() { echo "$*" >&2; }
die() { echo "错误：$*" >&2; exit 1; }
pgrep() {
  local owner="" name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -u) owner="$2"; shift 2 ;;
      -x) name="$2"; shift 2 ;;
      *) return 2 ;;
    esac
  done
  awk -v owner="$owner" -v name="$name" '
    ($1 == owner || owner == "") && $3 == name { print $2; found=1 }
    END { exit !found }
  ' "$PROCESS_TABLE"
}
pkill() {
  local signal="$1" owner="" name=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -u) owner="$2"; shift 2 ;;
      -x) name="$2"; shift 2 ;;
      *) return 2 ;;
    esac
  done
  echo "$signal $owner $name" >> "$SIGNAL_LOG"
  [ "${STUCK:-}" != 1 ] || return 1
  if [ "${RESIST_TERM:-}" = 1 ] && [ "$signal" = -TERM ]; then return 0; fi
  awk -v owner="$owner" -v name="$name" '
    !(($1 == owner || owner == "") && $3 == name)
  ' "$PROCESS_TABLE" > "$PROCESS_TABLE.next"
  mv "$PROCESS_TABLE.next" "$PROCESS_TABLE"
}
osascript() {
  [ "${APP_STUCK:-}" != 1 ] || return 0
  local name
  case "$*" in *'"ChatGPT"'*) name=ChatGPT ;; *'"Codex"'*) name=Codex ;; *) return 2 ;; esac
  awk -v owner="$(id -u)" -v name="$name" '!($1 == owner && $3 == name)' \
    "$PROCESS_TABLE" > "$PROCESS_TABLE.next"
  mv "$PROCESS_TABLE.next" "$PROCESS_TABLE"
}
sleep() { :; }
open() { echo "$*" >> "$OPEN_LOG"; }
'''


class CodexProcessTests(unittest.TestCase):
    def replay(self, names=(), foreign=(), **flags):
        with tempfile.TemporaryDirectory(prefix="aaswitch-process-test-") as tmp:
            folder = Path(tmp)
            table, signals, opened = [folder / n for n in ("table", "signals", "opened")]
            uid = os.getuid()
            table.write_text("".join(
                f"{uid} {1000 + i} {name}\n" for i, name in enumerate(names)
            ) + "".join(
                f"{uid + 1} {2000 + i} {name}\n" for i, name in enumerate(foreign)
            ))
            env = {k: v for k, v in os.environ.items() if not k.startswith("CODEX_MODE_")}
            env.update(PROCESS_TABLE=str(table), SIGNAL_LOG=str(signals), OPEN_LOG=str(opened))
            env.update(flags)
            result = subprocess.run(
                ["/bin/bash"], input=FAKES + GUARD + "\nquit_app\nreopen_app\n",
                env=env, text=True, capture_output=True, timeout=5,
            )
            return result, table.read_text(), signals.read_text() if signals.exists() else "", \
                opened.read_text() if opened.exists() else ""

    def test_no_processes(self):
        result, _, signals, _ = self.replay()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(signals, "")

    def test_idle_cli_and_ide_are_closed_before_switch(self):
        result, table, signals, _ = self.replay(["codex", "codex-app-server"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(table, "")
        self.assertIn("-TERM", signals)

    def test_both_desktop_apps_are_closed_and_reopened(self):
        result, table, _, opened = self.replay(["ChatGPT", "Codex", "codex"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(table, "")
        self.assertIn("-a ChatGPT", opened)
        self.assertIn("-a Codex", opened)

    def test_term_resistant_process_is_killed(self):
        result, table, signals, _ = self.replay(["codex"], RESIST_TERM="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(table, "")
        self.assertIn("-TERM", signals)
        self.assertIn("-KILL", signals)

    def test_unresponsive_desktop_is_closed(self):
        result, table, signals, _ = self.replay(["ChatGPT", "codex"], APP_STUCK="1", RESIST_TERM="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(table, "")
        self.assertIn("-KILL", signals)

    def test_other_users_and_unrelated_programs_are_preserved(self):
        result, table, signals, _ = self.replay(
            ["codex", "Claude", "node", "Code"], foreign=["codex", "codex-app-server", "ChatGPT"],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{os.getuid() + 1} 2000 codex", table)
        self.assertIn("Claude", table)
        self.assertIn("node", table)
        self.assertIn("Code", table)
        self.assertNotIn("Claude", signals)

    def test_failed_shutdown_aborts_and_restores_desktop(self):
        result, table, _, opened = self.replay(["ChatGPT", "codex"], STUCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("codex", table)
        self.assertIn("1001", result.stderr)
        self.assertIn("-a ChatGPT", opened)


if __name__ == "__main__":
    unittest.main()
