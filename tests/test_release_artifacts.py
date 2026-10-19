"""Regression checks for stale packages and same-version replacement."""
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_artifacts", ROOT / "scripts/release_artifacts.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_same_version_with_different_package_is_rejected(self):
        for platform in ("mac", "windows"):
            with self.subTest(platform=platform):
                old = {"version": "2.4.2", "sha256": "old"}
                new = {"version": "2.4.2", "sha256": "new"}
                if platform == "windows":
                    old, new = {"windows": old}, {"windows": new}
                with self.assertRaisesRegex(ValueError, "必须增加 VERSION"):
                    release.check_upgrade(old, new)

    def test_tarball_only_replacement_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "必须增加 VERSION"):
            release.check_upgrade({"version": "2.4.2", "sha256": "same", "tgz_sha256": "old"},
                                  {"version": "2.4.2", "sha256": "same", "tgz_sha256": "new"})

    def test_new_version_and_unchanged_other_platform_are_allowed(self):
        previous = {"version": "2.4.2", "sha256": "old",
                    "windows": {"version": "2.4.2", "sha256": "same"}}
        proposed = {**previous, "version": "2.4.4", "sha256": "new"}
        release.check_upgrade(previous, proposed)
        release.check_upgrade(proposed, proposed)

    def test_downgrade_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "不允许降级"):
            release.check_upgrade({"version": "2.4.4"}, {"version": "2.4.2"})

    def test_mac_package_must_contain_current_scripts(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            base = "AA Switch.app/Contents/"
            contents = {base + "Info.plist": plistlib.dumps({"CFBundleShortVersionString": "2.4.4"})}
            contents.update({base + "Resources/" + name: (ROOT / name).read_bytes()
                             for name in ("codex-mode.sh", "claude-mode.sh")})

            def pack():
                with tarfile.open(folder / "AASwitch.app.tar.gz", "w:gz") as bundle:
                    for name, data in contents.items():
                        info = tarfile.TarInfo(name)
                        info.size = len(data)
                        bundle.addfile(info, io.BytesIO(data))

            pack()
            release.inspect_mac(folder, "2.4.4")
            contents[base + "Resources/claude-mode.sh"] = b'CLAUDE_MODE_VERSION="1.4.1"\n'
            pack()
            with self.assertRaisesRegex(ValueError, "claude-mode.sh 不是当前源码"):
                release.inspect_mac(folder, "2.4.4")

    def test_manifest_rejects_changed_sources_and_changed_artifacts(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            with patch.object(release, "git", return_value="commit-a"), \
                    patch.object(release, "source_state", return_value={"source": "a"}) as state, \
                    patch.object(release, "inspect", return_value={"package": "a"}) as package:
                release.record("mac", folder)
                release.verify("mac", folder)
                state.return_value = {"source": "b"}
                with self.assertRaisesRegex(ValueError, "源码已改变"):
                    release.verify("mac", folder)
                state.return_value = {"source": "a"}
                package.return_value = {"package": "b"}
                with self.assertRaisesRegex(ValueError, "内容与构建清单不一致"):
                    release.verify("mac", folder)

    def test_pre_manifest_packages_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "缺少构建清单"):
                release.verify("mac", Path(temp))


if __name__ == "__main__":
    unittest.main()
