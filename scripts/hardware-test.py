#!/usr/bin/env python3
"""Explicit native smoke test. Intercepts current playback at 0 dB, then restores it."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
from live_support import command, hardware_session, request

def progressing():
    previous = request("Status")
    time.sleep(1)
    current = request("Status")
    assert current["state"] == "active", current
    assert current["callbacks"] > previous["callbacks"], current
    assert current["faults"] == 0, current
    assert current["sample_rate"] in (44100, 48000), current
    assert 0 < current["latency_ms"] <= 20, current
    return current

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force-termination", action="store_true", help="also SIGKILL this test's service and restart it")
    parser.add_argument("--expect-permission-denial", action="store_true", help="manually deny the macOS prompt; require start to fail")
    parser.add_argument("--sample-rates", action="store_true", help="explicitly test 44.1/48 kHz format changes and restore the original rate")
    args = parser.parse_args()
    with hardware_session():
        if args.expect_permission_denial:
            try:
                command("start", "--gain-db", "0")
            except RuntimeError as error:
                status = request("Status")
                assert status["state"] != "active" and status["error"], status
                print(f"Denied capture did not become active: {error}")
                return
            raise AssertionError("capture unexpectedly started; permission-denial case did not pass")
        print(command("start", "--gain-db", "0"), flush=True)
        first = progressing()
        # Another start attaches to this service and must preserve its zero-dB gain.
        command("start", "--gain-db", "3")
        assert request("Status")["gain_db"] == 0
        if args.sample_rates:
            test_sample_rates()
        if args.force_termination:
            os.kill(first["pid"], signal.SIGKILL)
            time.sleep(0.5)
            command("start", "--gain-db", "0")
            assert progressing()["pid"] != first["pid"]
        for _ in range(3):
            command("stop")
            command("start", "--gain-db", "0")
            progressing()
        print("Live callback/lifecycle smoke checks passed. Verify ordinary playback by listening after exit.")

def test_sample_rates():
    root=Path(__file__).resolve().parents[1]
    helper=root / "target/native/device-test-tool"
    helper.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(["xcrun","clang","-Wall","-Wextra","-Werror",str(root / "native/device_test_tool.c"),
                    "-framework","CoreAudio","-o",str(helper)],check=True)
    def device(*arguments):
        return json.loads(subprocess.check_output([str(helper),*arguments],text=True))
    original=device()
    if original["sample_rate"] not in (44100,48000):
        raise RuntimeError("sample-rate test requires a 44.1/48 kHz starting format to restore")
    try:
        for rate in [44100,48000]:
            device("--set-rate",str(rate))
            deadline=time.monotonic()+8
            while True:
                current=request("Status")
                if current["state"]=="active" and current["sample_rate"]==rate and current["latency_ms"]>0:
                    break
                if time.monotonic()>deadline:
                    raise AssertionError(f"format rebuild failed: {current}")
                time.sleep(.1)
            assert progressing()["sample_rate"]==rate
            assert request("Status")["gain_db"]==0
            print(f"Live {rate} Hz format rebuild passed",flush=True)
    finally:
        if device()["device"]!=original["device"]:
            raise RuntimeError("default output changed; original rate must be restored manually")
        device("--set-rate",str(original["sample_rate"]))

if __name__ == "__main__":
    main()
