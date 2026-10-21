"""PTY tests use an isolated control server; they never capture or play system audio."""
import copy
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time
import unittest

BINARY = Path(__file__).resolve().parents[1] / "target/debug/audioboost"

class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ab-", dir="/tmp")
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(self.directory.name + "/control.sock")
        self.server.listen()
        self.server.settimeout(0.1)
        self.state = dict(state="idle", gain_db=0.0, device="Test output", sample_rate=48000.0,
                          latency_ms=8.0, callbacks=0, faults=0, error="", pid=os.getpid())
        self.requests = []
        self.done = threading.Event()
        self.corrupt = False
        self.reject_start = False
        self.thread = threading.Thread(target=self.respond, daemon=True)
        self.thread.start()
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.child = None

    def respond(self):
        while not self.done.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            with connection:
                connection.settimeout(1)
                data = b""
                while not data.endswith(b"\n"):
                    part = connection.recv(4096)
                    if not part:
                        break
                    data += part
                if not data:
                    continue
                request = json.loads(data)
                self.requests.append(request)
                if request == "Stop":
                    self.state["state"] = "stopped"
                elif isinstance(request, dict):
                    if "Start" in request and self.state["state"] != "active":
                        self.state.update(state="active", gain_db=request["Start"])
                    elif "Adjust" in request:
                        self.state["gain_db"] = min(12, max(0, self.state["gain_db"] + request["Adjust"]))
                error = "unsupported output" if self.reject_start and isinstance(request, dict) and "Start" in request else None
                response = b"bad json\n" if self.corrupt and request == "Status" else (json.dumps(dict(status=copy.copy(self.state), error=error)) + "\n").encode()
                try:
                    connection.sendall(response)
                except BrokenPipeError:
                    pass

    def launch(self):
        environment = dict(os.environ, AUDIOBOOST_RUNTIME_DIR=self.directory.name, TERM="xterm-256color")
        self.child = subprocess.Popen([str(BINARY)], stdin=self.slave, stdout=self.slave,
                                      stderr=subprocess.PIPE, env=environment)
        self.wait_for(lambda: self.state["state"] == "active", drain=False)
        self.read_until(b"Ctrl-C")

    def wait_for(self, condition, drain=True):
        deadline = time.monotonic() + 4
        while not condition():
            if drain and select.select([self.master], [], [], 0)[0]:
                os.read(self.master, 65536)
            if time.monotonic() > deadline:
                self.fail("timed out waiting for terminal behavior")
            time.sleep(0.01)

    def read_until(self, marker):
        output = b""
        deadline = time.monotonic() + 4
        while marker not in output:
            if time.monotonic() > deadline:
                self.fail(f"did not render {marker!r}: {output!r}")
            if select.select([self.master], [], [], 0.1)[0]:
                output += os.read(self.master, 65536)
        return output

    def assert_clean_exit(self, key):
        os.write(self.master, key)
        self.wait_for(lambda: self.child.poll() is not None)
        self.assertEqual(self.child.wait(timeout=4), 0, self.child.stderr.read().decode())
        self.assertEqual(self.state["state"], "stopped")
        self.assertEqual(termios.tcgetattr(self.slave), self.original)

    def test_auto_start_arrows_bounds_resize_and_q_shutdown(self):
        self.launch()
        self.assertEqual(self.state["gain_db"], 3)
        os.write(self.master, b"\x1b[A")
        self.wait_for(lambda: self.state["gain_db"] == 4)
        os.write(self.master, b"\x1b[C" * 10)
        self.wait_for(lambda: self.state["gain_db"] == 12)
        os.write(self.master, b"\x1b[D" * 13)
        self.wait_for(lambda: self.state["gain_db"] == 0)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 40, 0, 0))
        self.child.send_signal(__import__("signal").SIGWINCH)
        self.assert_clean_exit(b"q")

    def test_attaching_preserves_gain_and_ctrl_c_stops_service(self):
        self.state.update(state="active", gain_db=7.5)
        self.launch()
        self.assertEqual(self.state["gain_db"], 7.5)
        self.assert_clean_exit(b"\x03")

    def test_ipc_failure_restores_terminal_and_requests_stop(self):
        self.launch()
        self.corrupt = True
        self.assertNotEqual(self.child.wait(timeout=4), 0)
        self.assertEqual(self.state["state"], "stopped")
        self.assertEqual(termios.tcgetattr(self.slave), self.original)

    def test_sigterm_restores_terminal_and_stops_service(self):
        self.launch()
        self.child.terminate()
        self.wait_for(lambda: self.child.poll() is not None)
        self.assertEqual(self.child.returncode, 0)
        self.assertEqual(self.state["state"], "stopped")
        self.assertEqual(termios.tcgetattr(self.slave), self.original)

    def test_failed_interactive_start_shuts_down_service(self):
        self.reject_start = True
        environment = dict(os.environ, AUDIOBOOST_RUNTIME_DIR=self.directory.name, TERM="xterm-256color")
        self.child = subprocess.Popen([str(BINARY)], stdin=self.slave, stdout=self.slave,
                                      stderr=subprocess.PIPE, env=environment)
        self.assertNotEqual(self.child.wait(timeout=4), 0)
        self.assertIn("Stop", self.requests)
        self.assertEqual(self.state["state"], "stopped")
        self.assertEqual(termios.tcgetattr(self.slave), self.original)

    def test_idle_polling_is_bounded_and_gain_boundary_does_not_redraw(self):
        self.state.update(state="active", gain_db=12)
        self.launch()
        time.sleep(1.1)
        self.assertLessEqual(self.requests.count("Status"), 5)
        self.assertGreaterEqual(self.requests.count("Status"), 4)
        self.assertFalse(select.select([self.master], [], [], 0)[0], "unchanged status redrew")
        os.write(self.master, b"\x1b[A")
        self.wait_for(lambda: {"Adjust": 1} in self.requests, drain=False)
        time.sleep(0.1)
        self.assertFalse(select.select([self.master], [], [], 0)[0], "gain boundary redrew")
        self.assert_clean_exit(b"q")

    def tearDown(self):
        if self.child:
            if self.child.poll() is None:
                self.child.kill()
                self.child.wait()
            self.child.stderr.close()
        self.done.set()
        self.thread.join(timeout=2)
        self.server.close()
        os.close(self.master)
        os.close(self.slave)
        self.directory.cleanup()

if __name__ == "__main__":
    unittest.main()
