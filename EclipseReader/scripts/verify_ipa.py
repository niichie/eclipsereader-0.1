"""Checks a thin arm64 Mach-O, iOS LC_BUILD_VERSION, and unsigned IPA structure."""
from pathlib import Path
import plistlib
import stat
import struct
import sys
import zipfile

def verify_binary(data: bytes):
    if len(data) < 32:
        raise ValueError("Missing Mach-O executable")
    magic, cpu, _, filetype, commands, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
        raise ValueError("Expected a thin, 64-bit arm64 Mach-O executable")
    if 32 + command_bytes > len(data):
        raise ValueError("Truncated Mach-O load commands")
    position = 32
    found_ios = False
    for _ in range(commands):
        if position + 8 > 32 + command_bytes:
            raise ValueError("Invalid Mach-O command boundary")
        cmd, length = struct.unpack_from("<II", data, position)
        if length < 8 or position + length > 32 + command_bytes:
            raise ValueError("Malformed Mach-O load command")
        if cmd == 0x32:  # LC_BUILD_VERSION
            if length < 24:
                raise ValueError("Malformed build version")
            platform = struct.unpack_from("<I", data, position + 8)[0]
            if platform != 2:
                raise ValueError("Executable is not built for physical iOS (platform 2)")
            found_ios = True
        position += length
    if not found_ios:
        raise ValueError("No iOS build-version load command")

def verify(path: Path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip():
            raise ValueError("ZIP CRC failure")
        names = archive.namelist()
        infos = [n for n in names if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")]
        if len(infos) != 1:
            raise ValueError("Expected Payload/OneApp.app/Info.plist")
        root = infos[0].removesuffix("Info.plist")
        info = plistlib.loads(archive.read(infos[0]))
        required = ["CFBundleIdentifier", "CFBundleExecutable", "CFBundleDisplayName", "CFBundleVersion", "MinimumOSVersion"]
        for key in required:
            if not info.get(key) or "$(" in str(info[key]):
                raise ValueError(f"Missing or unresolved {key}")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("Simulator or unsupported bundle platform")
        for name in names:
            if name.startswith("/") or ".." in Path(name).parts or not name.startswith(root):
                raise ValueError("Unexpected path in IPA")
            if name.endswith("embedded.mobileprovision") or "/_CodeSignature/" in name:
                raise ValueError("IPA unexpectedly contains signing material")
        binary = root + info["CFBundleExecutable"]
        verify_binary(archive.read(binary))
        if not (archive.getinfo(binary).external_attr >> 16) & stat.S_IXUSR:
            raise ValueError("Executable permission not preserved")
        if root + "Assets.car" not in names or root + "PrivacyInfo.xcprivacy" not in names:
            raise ValueError("Missing compiled assets or privacy manifest")
        print(f"Verified arm64 iOS IPA: {info['CFBundleIdentifier']} / {info['CFBundleDisplayName']}")

if __name__ == "__main__":
    verify(Path(sys.argv[1]))
