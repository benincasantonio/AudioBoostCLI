#!/usr/bin/env python3
"""Install checksum-pinned official macOS/arm64 tooling into .tools/bin."""
import hashlib
import io
from pathlib import Path
import platform
import tarfile
import urllib.request

TOOLS = {
    "cargo-nextest": ("0.9.148", "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-0.9.148/cargo-nextest-0.9.148-universal-apple-darwin.tar.gz", "6c23b7fb4ca82c571fc8dfedbab45bfa773d45918f933170c85d21cd7f4b852b"),
    "cargo-audit": ("0.22.2", "https://github.com/rustsec/rustsec/releases/download/cargo-audit/v0.22.2/cargo-audit-aarch64-apple-darwin-v0.22.2.tgz", "ec7ca4263769593df4d909be85b94a6b79efa2897be5d2bb8ebd516e823175af"),
    "cargo-deny": ("0.20.2", "https://github.com/EmbarkStudios/cargo-deny/releases/download/0.20.2/cargo-deny-0.20.2-aarch64-apple-darwin.tar.gz", "fe67d82a10d8597a3549364cb733a3f9cc1bfff9031b7ae46384a9f2a72090c3"),
}

def main():
    if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
        raise SystemExit("the pinned tool bundle currently supports Apple Silicon macOS only")
    destination = Path(__file__).resolve().parents[1] / ".tools" / "bin"
    destination.mkdir(parents=True, exist_ok=True)
    for name, (version, url, checksum) in TOOLS.items():
        print(f"Installing {name} {version}", flush=True)
        with urllib.request.urlopen(url, timeout=120) as response:
            archive = response.read()
        if hashlib.sha256(archive).hexdigest() != checksum:
            raise SystemExit(f"checksum mismatch for {name}")
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
            matches = [m for m in package.getmembers() if Path(m.name).name == name and m.isfile()]
            if len(matches) != 1:
                raise SystemExit(f"expected exactly one binary for {name}")
            content = package.extractfile(matches[0]).read()
        temporary = destination / (name + ".new")
        temporary.write_bytes(content)
        temporary.chmod(0o755)
        temporary.replace(destination / name)
    print(f"Installed tools in {destination}")

if __name__ == "__main__":
    main()
