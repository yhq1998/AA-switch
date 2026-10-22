#!/usr/bin/env python3
"""Bind release artifacts to committed build inputs and prevent version reuse."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tarfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "release-manifest.json"
INPUTS = ".build-inputs.json"
MAC_RESOURCES = {name: ROOT / name for name in ("codex-mode.sh", "claude-mode.sh")}
MAC_RESOURCES["claude-account-environment.sh"] = ROOT / "menubar/claude-account-environment.sh"
MAC_RESOURCES.update({"vendor/claude-switcher/" + name: ROOT / "menubar/vendor/claude-switcher" / name
                      for name in ("checks.sh", "stun-probe.py", "LICENSE", "UPSTREAM.json")})


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def version_parts(value):
    require(isinstance(value, str) and re.fullmatch(r"\d+\.\d+\.\d+", value),
            f"无效版本号：{value!r}")
    return tuple(map(int, value.split(".")))


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args]).decode().strip()


def source_state(platform):
    files = git("ls-files", "-z").split("\0")
    common = {"VERSION", "scripts/release_artifacts.py"}
    if platform == "mac":
        common.update({"codex-mode.sh", "claude-mode.sh", "smoke-test.sh"})
        prefixes = ("menubar/", "tests/")
    else:
        prefixes = ("windows/",)
    files = sorted(f for f in files if f and (f in common or f.startswith(prefixes)))
    require(files, "没有找到构建输入")
    dirty = git("status", "--porcelain", "--untracked-files=all", "--", *sorted(common), *prefixes)
    require(not dirty, "构建输入尚未提交；请先提交修复，再重新构建发布包")
    return {f: sha256((ROOT / f).read_bytes()) for f in files}


def inspect_mac(folder, version):
    with tarfile.open(folder / "AASwitch.app.tar.gz") as bundle:
        base = "AA Switch.app/Contents/"
        info = plistlib.loads(bundle.extractfile(base + "Info.plist").read())
        require(info["CFBundleShortVersionString"] == version, "macOS 安装包版本与 VERSION 不一致")
        for script, source in MAC_RESOURCES.items():
            packaged = bundle.extractfile(base + "Resources/" + script).read()
            require(packaged == source.read_bytes(), f"安装包内 {script} 不是当前源码")


def bundled_assembly(data, wanted):
    # .NET single-file format v6 (Microsoft.NET.HostModel/Bundle/Manifest.cs).
    signature = bytes.fromhex("8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae")
    marker = data.find(signature)
    require(marker >= 8, "缺少 .NET 单文件清单")
    cursor = struct.unpack_from("<Q", data, marker - 8)[0]
    major, minor, count = struct.unpack_from("<IIi", data, cursor)
    require((major, minor) == (6, 0) and 0 < count < 10000, "不支持的 .NET 单文件清单")
    cursor += 12

    def read_string():
        nonlocal cursor
        length = shift = 0
        while True:
            byte = data[cursor]
            cursor += 1
            length |= (byte & 0x7f) << shift
            if byte < 128:
                break
            shift += 7
            require(shift < 35, "无效的 .NET 清单字符串")
        value = data[cursor:cursor + length].decode("utf-8")
        cursor += length
        return value

    read_string()  # bundle ID
    cursor += 40  # deps.json, runtimeconfig.json offsets/sizes, flags
    for _ in range(count):
        offset, size, compressed = struct.unpack_from("<qqq", data, cursor)
        cursor += 25  # three int64 fields and FileType byte
        name = read_string()
        if name == wanted:
            require(0 <= offset < len(data) and 0 < size < 100_000_000,
                    "无效的程序集偏移或大小")
            payload = data[offset:offset + (compressed or size)]
            if compressed:
                payload = zlib.decompress(payload, -15)
            require(len(payload) == size, "内部程序集大小不匹配")
            return payload
    raise ValueError(f"单文件中缺少 {wanted}")


def inspect_windows(folder, version):
    require((folder / "version.txt").read_text().strip() == version,
            "Windows version.txt 与 VERSION 不一致")
    wanted = version_parts(version)
    for name in ("AA Switch.exe", "aaswitch.exe"):
        data = (folder / name).read_bytes()
        require(data[:2] == b"MZ", f"{name} 不是 Windows 可执行文件")
        # The outer apphost may carry the .NET SDK version on cross-built packages.
        # Read the application's managed assembly, including compressed bundles.
        assembly = bundled_assembly(data, Path(name).stem + ".dll")
        offset = assembly.find(b"\xbd\x04\xef\xfe\x00\x00\x01\x00")
        require(offset >= 0, f"{name} 缺少文件版本资源")
        major_minor, patch_build = struct.unpack_from("<II", assembly, offset + 8)
        actual = (major_minor >> 16, major_minor & 0xffff, patch_build >> 16)
        require(actual == wanted, f"{name} 内部版本 {actual} 与 VERSION 不一致")


def inspect(platform, folder, version):
    version_parts(version)
    if platform == "mac":
        inspect_mac(folder, version)
        names = ["AASwitch.app.tar.gz"]
        if (folder / "AA Switch.dmg").exists():
            names.append("AA Switch.dmg")
    else:
        inspect_windows(folder, version)
        names = ["AA Switch.exe", "aaswitch.exe", "version.txt"]
    return {name: sha256((folder / name).read_bytes()) for name in names}


def begin(platform, folder):
    version = (ROOT / "VERSION").read_text().strip()
    version_parts(version)
    out = {"version": version, "platform": platform, "commit": git("rev-parse", "HEAD"),
           "sources": source_state(platform)}
    folder.mkdir(parents=True, exist_ok=True)
    (folder / INPUTS).write_text(json.dumps(out, indent=2) + "\n")
    return out


def record(platform, folder):
    out = json.loads((folder / INPUTS).read_text())
    require(out["platform"] == platform and out["commit"] == git("rev-parse", "HEAD")
            and out["sources"] == source_state(platform), "构建过程中源码或提交已改变，请重新构建")
    out["artifacts"] = inspect(platform, folder, out["version"])
    (folder / MANIFEST).write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    return out


def verify(platform, folder):
    path = folder / MANIFEST
    require(path.is_file(), f"{path} 缺少构建清单，请重新构建，不能发布旧产物")
    out = json.loads(path.read_text())
    require(out["platform"] == platform, "构建清单的平台不匹配")
    require(out["version"] == (ROOT / "VERSION").read_text().strip(), "安装包不是当前 VERSION，请重新构建")
    require(out["commit"] == git("rev-parse", "HEAD"), "安装包来自旧提交，请重新构建")
    require(out["sources"] == source_state(platform), "安装包构建后源码已改变，请重新构建")
    require(out["artifacts"] == inspect(platform, folder, out["version"]), "安装包内容与构建清单不一致")
    return out


def check_upgrade(previous, proposed):
    for platform in ("mac", "windows"):
        old = previous if platform == "mac" else previous.get("windows", {})
        new = proposed if platform == "mac" else proposed.get("windows", {})
        if not new.get("version") or not old.get("version"):
            continue
        before, after = version_parts(old["version"]), version_parts(new["version"])
        require(after >= before, f"{platform} 不允许降级发布")
        if after == before:
            for key in ("sha256", "tgz_sha256"):
                require(old.get(key) == new.get(key),
                        f"{platform} {new['version']} 已发布过不同内容；必须增加 VERSION，禁止覆盖同版本包")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("begin", "record", "verify", "check-upgrade"))
    parser.add_argument("platform_or_previous")
    parser.add_argument("folder_or_proposed", type=Path)
    args = parser.parse_args()
    try:
        if args.operation == "check-upgrade":
            check_upgrade(json.loads(Path(args.platform_or_previous).read_text()),
                          json.loads(args.folder_or_proposed.read_text()))
        else:
            require(args.platform_or_previous in ("mac", "windows"), "平台必须是 mac 或 windows")
            result = {"begin": begin, "record": record, "verify": verify}[args.operation](
                args.platform_or_previous, args.folder_or_proposed)
            print(f"{result['platform']} {result['version']}：源码和产物校验通过（{result['commit'][:12]}）")
    except (ValueError, OSError, KeyError, IndexError, struct.error, zlib.error, tarfile.TarError) as error:
        parser.exit(1, f"发布检查失败：{error}\n")


if __name__ == "__main__":
    main()
