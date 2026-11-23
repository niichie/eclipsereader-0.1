"""Package a real, already-built iPhone .app; never packages source as an IPA."""
from pathlib import Path
import os
import plistlib
import stat
import sys
import zipfile

def package(app: Path, output: Path):
    from verify_ipa import verify_binary
    info = plistlib.loads((app / "Info.plist").read_bytes())
    executable = app / info["CFBundleExecutable"]
    verify_binary(executable.read_bytes())
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("Expected a device iPhoneOS application, not a simulator build")
    for forbidden in (app / "embedded.mobileprovision", app / "_CodeSignature"):
        if forbidden.exists():
            raise ValueError("Expected an unsigned build; refusing to package signing material")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(app.rglob("*")):
            if file.is_symlink():
                raise ValueError("Unexpected symlink in app bundle")
            if file.is_file():
                relative = Path("Payload") / app.name / file.relative_to(app)
                item = zipfile.ZipInfo(relative.as_posix())
                item.create_system = 3
                permissions = 0o755 if file == executable or os.access(file, os.X_OK) else 0o644
                item.external_attr = (stat.S_IFREG | permissions) << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(item, file.read_bytes())
    print(f"Packaged {output} ({output.stat().st_size:,} bytes)")

if __name__ == "__main__":
    package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
