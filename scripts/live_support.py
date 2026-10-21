"""Shared control helpers for explicit, serial hardware acceptance runs."""
from contextlib import contextmanager
import fcntl
import json
import math
import os
from pathlib import Path
import socket
import signal
import subprocess
import tempfile

BINARY = Path.home() / ".local/bin/audioboost"
RUNTIME = Path(os.environ.get("AUDIOBOOST_RUNTIME_DIR", Path(tempfile.gettempdir()) / f"audioboost-{os.geteuid()}"))

def device_info(*arguments):
    root = Path(__file__).resolve().parents[1]
    helper = root / "target/native/device-test-tool"
    source = root / "native/device_test_tool.c"
    if not helper.exists() or helper.stat().st_mtime < source.stat().st_mtime:
        helper.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", str(source),
                        "-framework", "CoreAudio", "-framework", "CoreFoundation", "-o", str(helper)], check=True)
    return json.loads(subprocess.check_output([str(helper), *arguments], text=True))

def latency_limit(device, override):
    return override if override is not None else (20.0 if device["built_in"] else None)

def positive_latency(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError("latency limit must be a finite positive number")
    return value

def request(command):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(RUNTIME / "control.sock"))
        connection.sendall((json.dumps(command) + "\n").encode())
        raw = connection.makefile("rb").readline(4097)
    if len(raw) > 4096 or not raw.endswith(b"\n"):
        raise RuntimeError("invalid service response")
    response = json.loads(raw)
    if response["error"]:
        raise RuntimeError(response["error"])
    return response["status"]

def command(*args):
    result = subprocess.run([str(BINARY), *args], capture_output=True, text=True, timeout=75)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout

def interrupted(signum, frame):
    raise KeyboardInterrupt(f"hardware test interrupted by signal {signum}")

@contextmanager
def hardware_session():
    if not BINARY.is_file():
        raise RuntimeError("run make install first")
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    with (RUNTIME / "hardware-test.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            existing = request("Status")
        except (FileNotFoundError, ConnectionRefusedError):
            existing = None
        if existing:
            raise RuntimeError("stop the existing service before a hardware acceptance run")
        signals={signum:signal.signal(signum,interrupted) for signum in [signal.SIGTERM,signal.SIGHUP]}
        try:
            yield
        finally:
            try:
                command("stop")
            finally:
                for signum,handler in signals.items():
                    signal.signal(signum,handler)
