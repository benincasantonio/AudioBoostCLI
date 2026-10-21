#!/usr/bin/env python3
"""Explicit native smoke test. Intercepts current playback at 0 dB, then restores it."""
import argparse
import os
import signal
import time
from live_support import command, device_info, hardware_session, latency_limit, positive_latency, request

def progressing(max_latency_ms):
    previous = request("Status")
    time.sleep(1)
    current = request("Status")
    assert current["state"] == "active", current
    assert current["callbacks"] > previous["callbacks"], current
    assert current["faults"] == 0, current
    assert 8000 <= current["sample_rate"] <= 192000, current
    assert 0 < current["buffer_frames"] <= 16384, current
    assert current["latency_ms"] > 0, current
    if max_latency_ms is not None:
        assert current["latency_ms"] <= max_latency_ms, current
    return current

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force-termination", action="store_true", help="also SIGKILL this test's service and restart it")
    parser.add_argument("--expect-permission-denial", action="store_true", help="manually deny the macOS prompt; require start to fail")
    parser.add_argument("--sample-rates", action="store_true", help="explicitly test 44.1/48 kHz format changes and restore the original rate")
    parser.add_argument("--max-latency-ms", type=positive_latency, help="override the reported latency limit (default: 20 ms built-in, no limit external)")
    args = parser.parse_args()
    with hardware_session():
        original = device_info()
        maximum = latency_limit(original, args.max_latency_ms)
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
        first = progressing(maximum)
        # Another start attaches to this service and must preserve its zero-dB gain.
        command("start", "--gain-db", "3")
        assert request("Status")["gain_db"] == 0
        if args.sample_rates:
            test_sample_rates(maximum)
        if args.force_termination:
            os.kill(first["pid"], signal.SIGKILL)
            time.sleep(0.5)
            command("start", "--gain-db", "0")
            assert progressing(maximum)["pid"] != first["pid"]
        for _ in range(3):
            command("stop")
            command("start", "--gain-db", "0")
            progressing(maximum)
        assert device_info()["uid"] == original["uid"], "output changed during smoke test"
        print("Live callback/lifecycle smoke checks passed. Verify ordinary playback by listening after exit.")

def test_sample_rates(max_latency_ms):
    original=device_info()
    rates = [rate for rate in (44100, 48000)
             if any(low <= rate <= high for low, high in original["sample_rate_ranges"])]
    if not rates:
        raise RuntimeError("output does not advertise 44.1 or 48 kHz for the format test")
    try:
        for rate in rates:
            if device_info()["uid"] != original["uid"]:
                raise RuntimeError("default output changed during format test")
            device_info("--set-rate",str(rate))
            deadline=time.monotonic()+8
            while True:
                current=request("Status")
                if current["state"]=="active" and current["sample_rate"]==rate and current["latency_ms"]>0:
                    break
                if time.monotonic()>deadline:
                    raise AssertionError(f"format rebuild failed: {current}")
                time.sleep(.1)
            assert progressing(max_latency_ms)["sample_rate"]==rate
            assert request("Status")["gain_db"]==0
            print(f"Live {rate} Hz format rebuild passed",flush=True)
    finally:
        if device_info()["uid"]!=original["uid"]:
            raise RuntimeError("default output changed; original rate must be restored manually")
        device_info("--set-rate",str(original["sample_rate"]))

if __name__ == "__main__":
    main()
