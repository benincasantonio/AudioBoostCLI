#!/usr/bin/env python3
"""Build a locally signed bundle; optionally install it at a stable per-user path."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.benincasa.audioboost"

def package(destination):
    contents = destination / "Contents"
    executable = contents / "MacOS" / "audioboost"
    executable.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "target/release/audioboost", executable)
    metadata = dict(CFBundleIdentifier=BUNDLE_ID, CFBundleName="AudioBoost",
                    CFBundleDisplayName="AudioBoost", CFBundleExecutable="audioboost",
                    CFBundlePackageType="APPL", CFBundleShortVersionString="0.1.0",
                    CFBundleVersion="1", LSMinimumSystemVersion="14.2", LSUIElement=True,
                    NSAudioCaptureUsageDescription="AudioBoost processes playback in memory to raise its volume. Audio is never saved or sent anywhere.")
    with (contents / "Info.plist").open("wb") as output:
        plistlib.dump(metadata, output)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", BUNDLE_ID, str(destination)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(destination)], check=True)
    return executable

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()
    destination = ROOT / "target/AudioBoost.app"
    if args.install:
        destination = Path.home() / "Applications/AudioBoost.app"
        link = Path.home() / ".local/bin/audioboost"
        if link.exists() or link.is_symlink():
            if not link.is_symlink() or link.resolve() != destination / "Contents/MacOS/audioboost":
                raise SystemExit(f"Refusing to replace an unrelated command: {link}")
        if destination.exists():
            metadata = destination / "Contents/Info.plist"
            if not metadata.is_file() or plistlib.loads(metadata.read_bytes()).get("CFBundleIdentifier") != BUNDLE_ID:
                raise SystemExit(f"Refusing to replace an unrelated app: {destination}")
            old_binary = destination / "Contents/MacOS/audioboost"
            subprocess.run([str(old_binary), "stop"], check=True)
        executable = package(destination)
        link.parent.mkdir(parents=True, exist_ok=True)
        if not link.is_symlink():
            link.symlink_to(executable)
        print(f"Installed {link}\nAdd {link.parent} to PATH if it is not already there.")
    else:
        package(destination)
        print(f"Packaged {destination}")

if __name__ == "__main__":
    main()
