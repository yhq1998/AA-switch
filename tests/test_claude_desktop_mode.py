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

    def test_gateway_switch_enables_mcp_tool_search(self):
        self.seed(None, "3p")
        self.run_mode("desktop", "gateway")
        entry = json.loads((self.library / "fixture.json").read_text())
        self.assertIs(entry.get("toolSearchEnabled"), True,
                      "Desktop otherwise disables MCP deferral in gateway sessions")

    def test_reapply_gateway_enables_previously_disabled_tool_search(self):
        self.seed(None, "3p")
        file = self.library / "fixture.json"
        entry = json.loads(file.read_text())
        entry.update(toolSearchEnabled=False, customSetting={"keep": True})
        file.write_text(json.dumps(entry))
        self.run_mode("desktop", "gateway")
        applied = json.loads(file.read_text())
        self.assertIs(applied.get("toolSearchEnabled"), True)
        self.assertEqual(applied["customSetting"], {"keep": True})
        self.run_mode("desktop", "account")
        self.assertIs(json.loads(file.read_text()).get("toolSearchEnabled"), True)

    def test_new_gateway_enables_tool_search(self):
        self.seed(None, None)
        (self.library / "_meta.json").unlink()
        self.run_mode("desktop", "gateway")
        id = json.loads((self.library / "_meta.json").read_text())["appliedId"]
        entry = json.loads((self.library / (id + ".json")).read_text())
        self.assertIs(entry.get("toolSearchEnabled"), True)

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

    def cowork_session(self, directory, name, last=100, body_name=None):
        session = directory / (body_name or name)
        (session / "outputs").mkdir(parents=True, exist_ok=True)
        (session / "outputs/result.txt").write_text("fixture output")
        cwd = str(session / "outputs")
        project = session / ".claude/projects" / "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
        project.mkdir(parents=True, exist_ok=True)
        (project / "chat.jsonl").write_text(json.dumps({"cwd": cwd, "text": "fixture conversation"}) + "\n")
        (session / "audit.jsonl").write_text("signed fixture: " + cwd)
        (directory / (name + ".json")).write_text(json.dumps({
            "sessionId": name, "cwd": cwd, "lastActivityAt": last,
        }))

    def cowork_paths(self):
        account = "11111111-2222-3333-4444-555555555555"
        org = "66666666-7777-8888-9999-000000000000"
        (self.root / ".claude.json").write_text(json.dumps({
            "oauthAccount": {"accountUuid": account, "organizationUuid": org},
        }))
        return (self.account_config.parent / "local-agent-mode-sessions" / account / org,
                self.gateway_config.parent / "local-agent-mode-sessions/aaaaaaaa/00000000")

    def test_cowork_history_reaches_new_gateway_profile(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        self.cowork_session(a, "local_account")
        self.cowork_session(b, "local_gateway")
        self.run_mode("desktop", "gateway")
        self.assertTrue((b / "local_account.json").exists())
        # Desktop initializes a different local identity; this is not a deletion
        # of individual conversations in the previous profile.
        b.parent.rename(self.root / "previous-gateway-profile")
        new_b = b.parent.parent / "bbbbbbbb/00000000"
        self.cowork_session(new_b, "local_new")
        self.run_mode("desktop", "gateway")
        self.assertTrue((new_b / "local_account.json").exists(),
                        "Account history is missing after switching to the new API profile")
        self.assertTrue((new_b / "local_account/outputs/result.txt").exists())

    def test_cowork_history_with_underscores_reaches_api(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        self.cowork_session(a, "local_regular")
        self.cowork_session(a, "local_ditto_12345678_g1")
        self.cowork_session(b, "local_gateway")
        self.run_mode("desktop", "gateway")
        self.assertTrue((b / "local_regular.json").exists())
        self.assertTrue((b / "local_ditto_12345678_g1.json").exists(),
                        "Only the Cowork conversation with underscores disappeared in API mode")
        self.assertTrue((b / "local_ditto_12345678_g1/outputs/result.txt").exists())

    def test_cowork_short_storage_body_is_copied_with_history(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        name = "local_12345678-1111-2222-3333-444444444444"
        self.cowork_session(a, name, body_name="12345678")
        self.cowork_session(b, "local_gateway")
        self.run_mode("desktop", "gateway")
        self.assertTrue((b / (name + ".json")).exists())
        self.assertTrue((b / name / "outputs/result.txt").exists(),
                        "Metadata was copied without the Cowork conversation's short storage directory")
        self.assertEqual(json.loads((b / (name + ".json")).read_text())["cwd"],
                         str(b / name / "outputs"))
        transcripts = list((b / name / ".claude/projects").glob("*/chat.jsonl"))
        self.assertEqual(len(transcripts), 1)
        self.assertEqual(json.loads(transcripts[0].read_text())["cwd"], str(b / name / "outputs"))
        expected_project = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(b / name / "outputs"))
        self.assertEqual(transcripts[0].parent.name, expected_project)
        self.assertEqual((b / name / "audit.jsonl").read_bytes(), (a / "12345678/audit.jsonl").read_bytes())

    def test_cowork_short_account_directory_is_selected(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        short_a = a.parent.parent / a.parent.name[:8] / a.name[:8]
        self.cowork_session(a, "local_legacy")
        self.cowork_session(short_a, "local_current")
        self.cowork_session(b, "local_gateway")
        self.run_mode("desktop", "gateway")
        self.assertTrue((b / "local_current.json").exists(),
                        "Cowork's active short account directory was ignored in favor of the old UUID directory")

    def test_cowork_agent_subdirectory_reaches_api(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        self.cowork_session(a, "local_legacy")
        self.cowork_session(a / "agent", "local_newtask")
        self.cowork_session(b, "local_gateway")
        self.run_mode("desktop", "gateway")
        self.assertTrue((b / "local_legacy.json").exists())
        self.assertTrue((b / "agent/local_newtask.json").exists(),
                        "Only Cowork tasks in the agent subdirectory disappeared in API mode")
        self.assertTrue((b / "agent/local_newtask/outputs/result.txt").exists())

    def test_cowork_sync_repairs_old_metadata_only_copy(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        name = "local_12345678-1111-2222-3333-444444444444"
        self.cowork_session(a / "agent", name, body_name="12345678")
        (b / "agent").mkdir(parents=True)
        (b / "agent" / (name + ".json")).write_bytes((a / "agent" / (name + ".json")).read_bytes())
        self.run_mode("desktop", "gateway")
        self.assertTrue((b / "agent" / name / "outputs/result.txt").exists())
        self.assertEqual(json.loads((b / "agent" / (name + ".json")).read_text())["cwd"],
                         str(b / "agent" / name / "outputs"))

    def test_cowork_agent_deletion_and_conflict_still_respected(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        self.cowork_session(a / "agent", "local_task")
        b.mkdir(parents=True)
        self.run_mode("desktop", "gateway")
        self.cowork_session(a / "agent", "local_task", 200)
        self.cowork_session(b / "agent", "local_task", 300)
        self.run_mode("desktop", "sync")
        self.assertEqual(json.loads((a / "agent/local_task.json").read_text())["lastActivityAt"], 200)
        self.assertEqual(json.loads((b / "agent/local_task.json").read_text())["lastActivityAt"], 300)
        (b / "agent/local_task.json").unlink()
        self.run_mode("desktop", "sync")
        self.assertFalse((b / "agent/local_task.json").exists(), "Deleted conversations must stay deleted")
        self.assertTrue((a / "agent/local_task.json").exists())

    def test_cowork_missing_source_body_is_reported_and_retried(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        a.mkdir(parents=True)
        b.mkdir(parents=True)
        (a / "local_task.json").write_text('{"lastActivityAt":100}')
        self.run_mode("desktop", "gateway")
        self.assertFalse((b / "local_task.json").exists())
        self.assertNotIn("local_task", (self.root / ".claude/claude-mode-cowork-sync").read_text())
        self.cowork_session(a, "local_task")
        self.run_mode("desktop", "sync")
        self.assertTrue((b / "local_task/outputs/result.txt").exists())

    def test_cowork_deletion_ledger_survives_switching_profiles_back(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        self.cowork_session(a, "local_task")
        self.cowork_session(b, "local_gateway")
        self.run_mode("desktop", "gateway")
        (b / "local_task.json").unlink()
        self.run_mode("desktop", "sync")
        saved = self.root / "previous-gateway-profile"
        b.parent.rename(saved)
        new_b = b.parent.parent / "bbbbbbbb/00000000"
        self.cowork_session(new_b, "local_new")
        self.run_mode("desktop", "gateway")
        self.assertTrue((new_b / "local_task.json").exists())
        new_b.parent.rename(self.root / "next-gateway-profile")
        saved.rename(b.parent)
        self.run_mode("desktop", "sync")
        self.assertFalse((b / "local_task.json").exists(),
                         "Returning to an old profile resurrected its deleted conversation")

    def test_cowork_legacy_deletion_ledger_is_preserved(self):
        self.seed("1p", "3p")
        a, b = self.cowork_paths()
        self.cowork_session(a, "local_task")
        self.cowork_session(b, "local_gateway")
        ledger = self.root / ".claude/claude-mode-cowork-sync"
        ledger.write_text("local_task 100\n")
        self.run_mode("desktop", "gateway")
        self.assertFalse((b / "local_task.json").exists())
        self.assertTrue((a / "local_task.json").exists())
        self.assertIn("# aa-switch-cowork-pair-v1 ", ledger.read_text())


if __name__ == "__main__":
    unittest.main()
