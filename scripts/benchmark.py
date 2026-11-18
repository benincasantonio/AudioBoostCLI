#!/usr/bin/env python3
"""Measure a live release build. Counts both service and terminal processes; captures no recordings."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import threading
import time
from live_support import BINARY, command, device_info, hardware_session, latency_limit, positive_latency, request

def cpu_seconds(value):
    parts = value.split(":")
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total

def processes():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,time=,rss=,comm="], text=True)
    found = {}
    for row in rows.splitlines():
        pid, cpu, rss, executable = row.strip().split(None, 3)
        if Path(executable) in (BINARY, BINARY.resolve()):
            found[int(pid)] = dict(cpu=cpu_seconds(cpu), rss=int(rss) * 1024)
    return found

def drain_terminal(master, done):
    while not done.is_set():
        if select.select([master], [], [], 0.1)[0]:
            try:
                os.read(master, 65536)
            except OSError:
                return

def measure(seconds, with_ui, gain, max_latency_ms):
    ui = None
    master = slave = None
    done = threading.Event()
    reader = None
    try:
        output = device_info()
        maximum_allowed = latency_limit(output, max_latency_ms)
        command("start", "--gain-db", str(gain))
        if with_ui:
            master, slave = pty.openpty()
            ui = subprocess.Popen([str(BINARY)], stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            reader = threading.Thread(target=drain_terminal, args=(master, done), daemon=True)
            reader.start()
        time.sleep(2)
        initial = request("Status")
        previous = processes()
        started = time.monotonic()
        cpu = 0.0
        peak_rss = 0
        maximum_latency = 0.0
        minimum_frames = 16384
        maximum_frames = 0
        last_callbacks = initial["callbacks"]
        samples = 0
        while time.monotonic() - started < seconds:
            time.sleep(min(1, max(0, seconds - (time.monotonic() - started))))
            status = request("Status")
            current = processes()
            assert status["state"] == "active" and status["pid"] == initial["pid"], status
            assert status["faults"] == initial["faults"] == 0, status
            assert status["callbacks"] > last_callbacks, "callbacks stalled"
            assert status["sample_rate"] == initial["sample_rate"], "sample rate changed during benchmark"
            assert device_info()["uid"] == output["uid"], "output changed during benchmark"
            assert status["pid"] in current, "service missing from resource measurement"
            if ui:
                assert ui.poll() is None and ui.pid in current, "terminal process exited"
            assert status["latency_ms"] > 0, "Core Audio did not report valid timestamps"
            assert 0 < status["buffer_frames"] <= 16384, "invalid playback buffer size"
            cpu += sum(max(0, values["cpu"] - previous.get(pid, {"cpu": 0})["cpu"]) for pid, values in current.items())
            peak_rss = max(peak_rss, sum(values["rss"] for values in current.values()))
            maximum_latency = max(maximum_latency, status["latency_ms"])
            minimum_frames = min(minimum_frames, status["buffer_frames"])
            maximum_frames = max(maximum_frames, status["buffer_frames"])
            previous = current
            last_callbacks = status["callbacks"]
            samples += 1
            if samples % 60 == 0:
                elapsed = time.monotonic() - started
                print(f"{elapsed:.0f} s: CPU {cpu/elapsed*100:.2f}%, peak RSS {peak_rss/1048576:.2f} MiB, latency {maximum_latency:.2f} ms; no callback faults", flush=True)
        elapsed = time.monotonic() - started
        average_cpu = cpu / elapsed * 100
        result = dict(completed_at=datetime.now(timezone.utc).isoformat(), executable_sha256=hashlib.sha256(BINARY.read_bytes()).hexdigest(),
                      seconds=elapsed, with_ui=with_ui, gain_db=gain, device=initial["device"], sample_rate=initial["sample_rate"],
                      average_cpu_percent_one_core=average_cpu, peak_combined_rss_mib=peak_rss / 1048576,
                      maximum_reported_pipeline_latency_ms=maximum_latency, callback_faults=0,
                      device_uid=output["uid"], transport=output["transport"],
                      minimum_playback_buffer_frames=minimum_frames, maximum_playback_buffer_frames=maximum_frames,
                      reported_latency_limit_ms=maximum_allowed,
                      resource_limits_pass=average_cpu < 2 and peak_rss < 50 * 1048576,
                      reported_latency_limit_pass=maximum_latency <= maximum_allowed if maximum_allowed is not None else None,
                      physical_added_latency_verified=False)
        print(json.dumps(result, indent=2), flush=True)
        destination = Path(__file__).resolve().parents[1] / "target/acceptance"
        destination.mkdir(parents=True, exist_ok=True)
        (destination / f"benchmark-{int(time.time())}.json").write_text(json.dumps(result, indent=2) + "\n")
        if not result["resource_limits_pass"] or result["reported_latency_limit_pass"] is False:
            raise SystemExit("acceptance limits exceeded")
    finally:
        if ui:
            if ui.poll() is None:
                os.write(master, b"q")
                try:
                    ui.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    ui.kill()
                    ui.wait()
            diagnostics = ui.stderr.read().decode(errors="replace").strip()
            if diagnostics:
                print(f"Terminal diagnostics: {diagnostics}", flush=True)
            ui.stderr.close()
            done.set()
            reader.join(timeout=1)
            os.close(master)
            os.close(slave)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=1800)
    parser.add_argument("--with-ui", action="store_true")
    parser.add_argument("--gain-db", type=int, choices=range(13), default=0)
    parser.add_argument("--max-latency-ms", type=positive_latency, help="override the reported latency limit (default: 20 ms built-in, no limit external)")
    args = parser.parse_args()
    if args.seconds < 1:
        parser.error("seconds must be positive")
    with hardware_session():
        measure(args.seconds, args.with_ui, args.gain_db, args.max_latency_ms)

if __name__ == "__main__":
    main()
