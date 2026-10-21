"""Shared control helpers for explicit, serial hardware acceptance runs."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import socket
import signal
import subprocess
import tempfile

BINARY = Path.home() / ".local/bin/audioboost"
RUNTIME = Path(os.environ.get("AUDIOBOOST_RUNTIME_DIR", Path(tempfile.gettempdir()) / f"audioboost-{os.geteuid()}"))

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
