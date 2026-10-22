"""Verify upstream provenance and run account checks without real network/system changes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import shutil

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "menubar/vendor/claude-switcher"
ADAPTER = ROOT / "menubar/claude-account-environment.sh"
NAMES = {"代理内核", "TUN网卡", "出口IP", "IP一致", "时区", "地区", "IPv6", "DNS", "WebRTC", "保镖", "规则置顶", "客户端语言", "ASN属性", "生态可达性"}

STUB = r'''
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["ENV_TEST_CALLS"], "a") as f:
    f.write(json.dumps([name] + args) + "\n")
ip = os.environ.get("ENV_TEST_IP", "203.0.113.7")
if name == "ifconfig":
    print("utun8: inet 198.18.0.1")
elif name == "pgrep":
    print("12345")
elif name == "scutil":
    print("(Connected) com.liguangming.Shadowrocket")
elif name == "curl":
    url = next((arg for arg in args if arg.startswith("https://")), "")
    if "cloudflare" in url:
        print("ip=" + ip + "\nloc=US")
    elif "ipinfo" in url:
        print('{"org": "AS7922 Comcast Cable"}')
    elif url in ("https://claude.ai/", "https://api.anthropic.com/v1/models"):
        print("000" if os.environ.get("ENV_TEST_OFFLINE") else "401", end="")
    else:
        raise SystemExit("Unexpected network target: " + url)
elif name == "readlink":
    print("/var/db/timezone/zoneinfo/America/New_York")
elif name == "defaults":
    if "AppleLocale" in args:
        print("en_US")
    else:
        print('(\n    "en-US"\n)')
elif name == "networksetup":
    assert args == ["-getinfo", "Wi-Fi"], args
    print("IPv6: Off")
elif name == "dig":
    print("198.18.0.7")
elif name == "launchctl":
    assert args == ["print", "system/local.claude-bodyguard"], args
    raise SystemExit(1 if os.environ.get("ENV_TEST_NO_BODYGUARD") else 0)
elif name == "python3":
    print("RESULT:" + os.environ.get("ENV_TEST_STUN_IP", ip))
else:
    raise SystemExit("Forbidden command: " + name)
'''


class ProvenanceTests(unittest.TestCase):
    def test_sources_and_extracted_checks_are_byte_for_byte_upstream(self):
        metadata = json.loads((VENDOR / "UPSTREAM.json").read_text())
        for source, info in metadata["files"].items():
            with self.subTest(source=source):
                self.assertEqual(hashlib.sha256((VENDOR / info["path"]).read_bytes()).hexdigest(), info["sha256"])
        original = (VENDOR / "upstream/core/claude-switch.sh").read_text()
        extracted = "".join(original[original.index(start):original.index(end)]
                            for start, end in metadata["check_ranges"])
        self.assertEqual((VENDOR / "checks.sh").read_text(),
                         "#!/bin/bash\n# Extracted verbatim from claude-switcher; see UPSTREAM.json and LICENSE.\n" + extracted)


class EnvironmentAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aaswitch-account-environment-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.calls = self.home / "calls.jsonl"
        for name in ("ifconfig", "pgrep", "scutil", "curl", "readlink", "defaults", "networksetup", "dig", "launchctl", "python3", "osascript", "open", "killall"):
            script = self.bin / name
            script.write_text("#!" + sys.executable + "\n" + STUB)
            script.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin", ENV_TEST_CALLS=str(self.calls))
        self.state = self.home / "Library/Application Support/AA Switch/claude-account-environment"
        clash = self.home / "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
        clash.mkdir(parents=True)
        (clash / "clash-verge.yaml").write_text("DOMAIN-SUFFIX,claude.ai,IpEqual\n")
        self.account = self.home / "Library/Application Support/Claude/account-sentinel"
        self.account.parent.mkdir(parents=True)
        self.account.write_text("existing-login-state")

    def run_checks(self, **overrides):
        result = subprocess.run(["/bin/bash", str(ADAPTER), str(self.state), "clash-verge", "US", "America/New_York", "en_US", "IpEqual"],
                                env=dict(self.env, **overrides), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        rows = dict(line.split("=", 1) for line in result.stdout.splitlines() if line.split("=", 1)[0] in NAMES)
        self.assertEqual(set(rows), NAMES, result.stdout)
        self.assertIn("# 结束", result.stdout)
        return rows

    def test_all_14_original_checks_and_private_state_without_account_changes(self):
        rows = self.run_checks()
        self.assertTrue(all(value == "ok" or value.startswith("ok:") for value in rows.values()), rows)
        self.assertEqual(self.account.read_text(), "existing-login-state")
        self.assertFalse((self.home / ".claude-switcher").exists())
        self.assertEqual((self.state / "stun-probe.py").read_bytes(), (VENDOR / "stun-probe.py").read_bytes())
        self.assertEqual((self.state / "lastip").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertFalse(any(call[0] in ("osascript", "open", "killall") for call in calls), calls)

    def test_original_ip_history_warns_after_three_distinct_ips(self):
        self.run_checks()
        rows = self.run_checks(ENV_TEST_IP="203.0.113.8")
        self.assertTrue(rows["IP一致"].startswith("warn:"), rows)
        rows = self.run_checks(ENV_TEST_IP="203.0.113.9")
        self.assertIn("48h内出口IP变化3次", rows["IP一致"])

    def test_original_missing_bodyguard_and_stun_mismatch_are_preserved(self):
        rows = self.run_checks(ENV_TEST_NO_BODYGUARD="1", ENV_TEST_STUN_IP="198.51.100.8")
        self.assertEqual(rows["保镖"], "fail:未安装")
        self.assertEqual(rows["WebRTC"], "fail:暴露非代理IP: 198.51.100.8")

    def test_original_failed_reachability_is_preserved(self):
        rows = self.run_checks(ENV_TEST_OFFLINE="1")
        self.assertEqual(rows["生态可达性"], "fail:claude.ai:000 api:000")

    def test_invalid_invocation_never_runs_detection(self):
        result = subprocess.run(["/bin/bash", str(ADAPTER)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.state.exists())

    def test_missing_python_stops_before_writing_state_or_probing(self):
        (self.bin / "python3").unlink()
        (self.bin / "dirname").symlink_to("/usr/bin/dirname")
        env = dict(self.env, PATH=str(self.bin))
        result = subprocess.run(["/bin/bash", str(ADAPTER), str(self.state), "auto", "US", "America/New_York", "en_US", "IpEqual"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("需要 Python 3", result.stdout)
        self.assertFalse(self.calls.exists())
        self.assertFalse(self.state.exists())


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "macOS Swift compiler required")
class ReportProtocolTests(unittest.TestCase):
    def test_full_warning_partial_and_failed_process_reports(self):
        source = r'''
import Foundation
let appVersion = "test"
@main
struct ReportTest {
    static func main() {
        let rows = ClaudeEnvironmentReport.names.map { $0 + "=ok:original:detail" }.joined(separator: "\n")
        let raw = "# start\n" + rows + "\n# 结束\n"
        let full = ClaudeEnvironmentReport(raw: raw, exitCode: 0)
        precondition(full.complete && full.rows.count == 14)
        precondition(full.rows["时区"]?.detail == "original:detail")
        let warning = ClaudeEnvironmentReport(raw: raw.replacingOccurrences(of: "IP一致=ok", with: "IP一致=warn"), exitCode: 0)
        precondition(warning.complete && warning.summary.contains("1 项提醒"))
        precondition(!ClaudeEnvironmentReport(raw: raw, exitCode: 15).complete)
        precondition(!ClaudeEnvironmentReport(raw: rows, exitCode: 0).complete)
        precondition(!ClaudeEnvironmentReport(raw: "代理内核=ok\n# 结束", exitCode: 0).complete)
        precondition(!ClaudeEnvironmentReport(raw: raw.replacingOccurrences(of: "生态可达性=ok", with: "生态可达性=invalid"), exitCode: 0).complete)
        precondition(!ClaudeEnvironmentReport(raw: "ERROR:需要 Python 3", exitCode: 2).complete)
    }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            driver = Path(temp) / "ReportTest.swift"
            binary = Path(temp) / "report-test"
            driver.write_text(source)
            subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(ROOT / "menubar/ClaudeAccountEnvironment.swift"), str(driver), "-o", str(binary)], check=True, capture_output=True, text=True, timeout=60)
            subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
