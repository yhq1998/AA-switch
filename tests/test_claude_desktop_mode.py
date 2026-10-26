"""Exercise desktop switching with isolated config and simulated app processes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "macOS JavaScript for Automation required")
class DesktopModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aaswitch-desktop-mode-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.account_config = self.root / "desktop/Claude/claude_desktop_config.json"
        self.gateway_config = self.root / "desktop/Claude-3p/claude_desktop_config.json"
        self.library = self.gateway_config.parent / "configLibrary"
        self.library.mkdir(parents=True)
        self.account_config.parent.mkdir(parents=True)
        (self.library / "_meta.json").write_text('{"appliedId":"fixture","entries":[{"id":"fixture"}]}')
        (self.library / "fixture.json").write_text('{"inferenceProvider":"gateway","inferenceGatewayApiKey":"fixture-key"}')
        (self.root / "Applications/Claude.app").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Real JXA handles config; only process/app/network/keychain operations are fake.
        stubs = {
            "pgrep": '[ -f "$DESKTOP_TEST_RUNNING" ]',
            "osascript": '''if [ "$1" = -l ]; then exec /usr/bin/osascript "$@"; fi
if [ -f "$DESKTOP_TEST_RUNNING" ]; then
  /usr/bin/osascript -l JavaScript - "$DESKTOP_TEST_CONFIG" <<'JS'
ObjC.import('Foundation');
function run(args) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(args[0], $.NSUTF8StringEncoding, null);
  const o = JSON.parse(ObjC.unwrap(s));
  o.deploymentMode = '3p'; // App flushes its old in-memory mode when quitting.
  $.NSString.alloc.initWithUTF8String(JSON.stringify(o)).writeToFileAtomicallyEncodingError(args[0], true, $.NSUTF8StringEncoding, null);
}
JS
  rm "$DESKTOP_TEST_RUNNING"
fi''',
            "security": 'printf fixture-key',
            "curl": 'printf 200',
            "open": 'printf "%s\\n" "$@" > "$DESKTOP_TEST_OPEN_ARGS"',
        }
        for name, body in stubs.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.root),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_CONFIG_DIR=str(self.root / ".claude"),
                        CODEX_HOME=str(self.root / ".codex"),
                        CLAUDE_DESKTOP_DATA_DIR=str(self.account_config.parent),
                        CLAUDE_MODE_NO_REOPEN="1", CLAUDE_MODE_NONINTERACTIVE="1",
                        DESKTOP_TEST_RUNNING=str(self.root / "running"),
                        DESKTOP_TEST_OPEN_ARGS=str(self.root / "open-args"),
                        DESKTOP_TEST_CONFIG=str(self.gateway_config))
        conf = self.root / ".claude/claude-mode.conf"
        conf.parent.mkdir()
        conf.write_text("base_url=https://gateway.example.test\n")

    def run_mode(self, *args):
        result = subprocess.run(["/bin/bash", str(ROOT / "claude-mode.sh"), *args],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def seed(self, account_mode, gateway_mode):
        for file, mode in ((self.account_config, account_mode), (self.gateway_config, gateway_mode)):
            obj = {"preferences": {"theme": "dark"}}
            if mode is not None:
                obj["deploymentMode"] = mode
            file.write_text(json.dumps(obj))

    def test_saved_gateway_without_explicit_mode_is_detected(self):
        self.seed("3p", None)
        self.assertEqual(self.run_mode("desktop-mode"), "gateway")

    def disable_account_sign_in(self):
        entry = self.library / "fixture.json"
        obj = json.loads(entry.read_text())
        obj["disableDeploymentModeChooser"] = True
        entry.write_text(json.dumps(obj))

    def test_disabled_sign_in_overrides_persisted_account_mode(self):
        self.seed(None, "1p")
        self.disable_account_sign_in()
        self.assertEqual(self.run_mode("desktop-mode"), "gateway")

    def test_account_switch_restores_sign_in_option(self):
        self.seed(None, "3p")
        self.disable_account_sign_in()
        self.run_mode("desktop", "account")
        obj = json.loads((self.library / "fixture.json").read_text())
        self.assertFalse(obj.get("disableDeploymentModeChooser", False),
                         "Claude hides account login even with deploymentMode=1p")
        self.assertEqual(obj["inferenceGatewayApiKey"], "fixture-key")

    def test_gateway_switch_does_not_disable_future_account_sign_in(self):
        self.seed(None, "3p")
        self.disable_account_sign_in()
        self.run_mode("desktop", "gateway")
        self.assertFalse(json.loads((self.library / "fixture.json").read_text())
                         .get("disableDeploymentModeChooser", False))

    def test_switch_to_account_explicitly_overrides_saved_gateway(self):
        self.seed("3p", None)
        self.run_mode("desktop", "account")
        self.assertEqual(json.loads(self.gateway_config.read_text())["deploymentMode"], "1p")
        self.assertEqual(self.run_mode("desktop-mode"), "account")
        self.assertEqual(json.loads(self.account_config.read_text())["preferences"]["theme"], "dark")
        self.assertEqual(json.loads((self.library / "fixture.json").read_text())["inferenceGatewayApiKey"], "fixture-key")
        self.assertEqual(json.loads(self.account_config.read_text())["deploymentMode"], "3p")

    def test_gateway_mode_comes_from_3p_config_not_account_profile(self):
        self.seed("1p", "3p")
        self.assertEqual(self.run_mode("desktop-mode"), "gateway")

    def test_gateway_is_detected_when_account_profile_has_no_mode(self):
        self.seed(None, "3p")
        self.assertEqual(self.run_mode("desktop-mode"), "gateway")

    def test_empty_mode_with_saved_gateway_is_detected(self):
        self.seed("1p", "")
        self.assertEqual(self.run_mode("desktop-mode"), "gateway")

    def test_fresh_install_without_gateway_is_account(self):
        self.seed(None, None)
        (self.library / "_meta.json").unlink()
        self.assertEqual(self.run_mode("desktop-mode"), "account")

    def test_gateway_switch_preserves_account_profile(self):
        self.seed("1p", "1p")
        self.run_mode("desktop", "gateway")
        self.assertEqual(json.loads(self.gateway_config.read_text())["deploymentMode"], "3p")
        self.assertEqual(json.loads(self.account_config.read_text())["deploymentMode"], "1p")
        self.assertEqual(self.run_mode("desktop-mode"), "gateway")

    def test_app_shutdown_cannot_overwrite_new_account_mode(self):
        self.seed("3p", "3p")
        Path(self.env["DESKTOP_TEST_RUNNING"]).touch()
        self.run_mode("desktop", "account")
        self.assertFalse(Path(self.env["DESKTOP_TEST_RUNNING"]).exists())
        self.assertEqual(json.loads(self.gateway_config.read_text())["deploymentMode"], "1p",
                         "Claude still enters the custom gateway welcome page")

    def test_account_switch_opens_explicit_sign_in_even_when_app_was_closed(self):
        self.seed(None, None)
        self.env.pop("CLAUDE_MODE_NO_REOPEN")
        self.run_mode("desktop", "account")
        opened = Path(self.env["DESKTOP_TEST_OPEN_ARGS"])
        self.assertTrue(opened.exists(), "Account sign-in must open before Claude drops unsigned-in 1p choice")
        self.assertEqual(opened.read_text().splitlines(),
                         ["-a", "Claude", "--args", "--claude-first-party-sign-in"])

    def test_running_account_switch_also_uses_explicit_sign_in(self):
        self.seed(None, "3p")
        self.env.pop("CLAUDE_MODE_NO_REOPEN")
        Path(self.env["DESKTOP_TEST_RUNNING"]).touch()
        self.run_mode("desktop", "account")
        self.assertIn("--claude-first-party-sign-in",
                      Path(self.env["DESKTOP_TEST_OPEN_ARGS"]).read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
