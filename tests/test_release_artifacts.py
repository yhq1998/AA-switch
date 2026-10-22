"""Regression checks for stale packages and same-version replacement."""
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tarfile
import tempfile
import unittest
import zlib
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
            contents.update({base + "Resources/" + name: path.read_bytes()
                             for name, path in release.MAC_RESOURCES.items()})

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
            contents[base + "Resources/claude-mode.sh"] = (ROOT / "claude-mode.sh").read_bytes()
            contents[base + "Resources/vendor/claude-switcher/checks.sh"] = b"changed upstream checks"
            pack()
            with self.assertRaisesRegex(ValueError, "checks.sh 不是当前源码"):
                release.inspect_mac(folder, "2.4.4")

    def test_manifest_rejects_changed_sources_and_changed_artifacts(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            with patch.object(release, "git", return_value="commit-a"), \
                    patch.object(release, "source_state", return_value={"source": "a"}) as state, \
                    patch.object(release, "inspect", return_value={"package": "a"}) as package:
                release.begin("mac", folder)
                release.record("mac", folder)
                release.verify("mac", folder)
                state.return_value = {"source": "b"}
                with self.assertRaisesRegex(ValueError, "源码已改变"):
                    release.verify("mac", folder)
                state.return_value = {"source": "a"}
                package.return_value = {"package": "b"}
                with self.assertRaisesRegex(ValueError, "内容与构建清单不一致"):
                    release.verify("mac", folder)

    def test_changes_during_build_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            with patch.object(release, "git", return_value="commit-a"), \
                    patch.object(release, "source_state", return_value={"source": "a"}) as state:
                release.begin("mac", folder)
                state.return_value = {"source": "b"}
                with self.assertRaisesRegex(ValueError, "构建过程中源码或提交已改变"):
                    release.record("mac", folder)

    def test_windows_checks_application_version_inside_compressed_bundle(self):
        signature = bytes.fromhex("8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae")
        resource = struct.pack("<IIII", 0xfeef04bd, 0x10000, (2 << 16) | 4, 4 << 16)
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / "version.txt").write_text("2.4.4\n")
            for name in ("AA Switch.exe", "aaswitch.exe"):
                assembly_name = (Path(name).stem + ".dll").encode()
                app = b"MZ" + resource
                compressor = zlib.compressobj(wbits=-15)
                packed = compressor.compress(app) + compressor.flush()
                prefix = b"MZ" + b"\0" * 6
                offset = len(prefix) + 8 + len(signature)
                header_offset = offset + len(packed)
                data = prefix + struct.pack("<Q", header_offset) + signature + packed
                header = struct.pack("<IIi", 6, 0, 1) + b"\x02id" + b"\0" * 40
                entry = struct.pack("<qqqB", offset, len(app), len(packed), 1)
                data += header + entry + bytes([len(assembly_name)]) + assembly_name
                (folder / name).write_bytes(data)
            release.inspect_windows(folder, "2.4.4")
            (folder / "version.txt").write_text("2.4.3\n")
            with self.assertRaises(ValueError):
                release.inspect_windows(folder, "2.4.3")

    def test_pre_manifest_packages_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "缺少构建清单"):
                release.verify("mac", Path(temp))


if __name__ == "__main__":
    unittest.main()
