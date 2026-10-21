"""Real service/socket lifecycle tests. No Start request: no audio interception."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

BINARY = Path(__file__).resolve().parents[1] / "target/debug/audioboost"

class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ab-service-", dir="/tmp")
        self.environment = dict(os.environ, AUDIOBOOST_RUNTIME_DIR=self.directory.name)
        self.children = []

    def spawn(self):
        child = subprocess.Popen([str(BINARY), "--serve"], env=self.environment,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.PIPE, start_new_session=True)
        self.children.append(child)
        return child

    def command(self, *args):
        return subprocess.run([str(BINARY), *args], env=self.environment, capture_output=True,
                              text=True, timeout=5)

    def ready(self):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = self.command("status")
            if result.returncode == 0 and "State: idle" in result.stdout:
                return
            time.sleep(0.05)
        self.fail("service did not become ready")

    def exchange(self, data):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3)
            connection.connect(self.directory.name + "/control.sock")
            connection.sendall(data)
            return json.loads(connection.makefile("rb").readline())

    def test_concurrent_services_have_one_owner_and_stop_cleanly(self):
        first, second = self.spawn(), self.spawn()
        self.ready()
        deadline = time.monotonic() + 3
        while first.poll() is None and second.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(sum(child.poll() is None for child in [first, second]), 1)
        self.assertEqual(self.command("stop").returncode, 0)
        for child in [first, second]:
            child.wait(timeout=3)
        self.assertFalse(Path(self.directory.name, "control.sock").exists())

    def test_malformed_and_disconnected_clients_do_not_kill_service(self):
        child = self.spawn()
        self.ready()
        self.assertIsNotNone(self.exchange(b'{"Gain":99}\n')["error"])
        self.assertIsNotNone(self.exchange(b'not json\n')["error"])
        self.assertIsNotNone(self.exchange(b' ' * 4097 + b'\n')["error"])
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(self.directory.name + "/control.sock")
            client.sendall(b'"Status"\n')
        result = self.command("status")
        self.assertEqual(result.returncode, 0, f"{result.stderr}; service exit={child.poll()}")
        self.assertIsNone(child.poll())
        self.assertNotEqual(self.command("gain", "5").returncode, 0)

    def test_repeated_restart_and_recovery_after_forced_termination(self):
        for _ in range(3):
            child = self.spawn()
            self.ready()
            self.assertEqual(self.command("stop").returncode, 0)
            self.assertEqual(child.wait(timeout=3), 0)
        child = self.spawn()
        self.ready()
        child.kill()
        child.wait(timeout=3)
        replacement = self.spawn()
        self.ready()
        replacement.terminate()
        self.assertEqual(replacement.wait(timeout=3), 0)
        self.assertEqual(self.command("stop").returncode, 0)

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            child.stderr.close()
        self.directory.cleanup()

if __name__ == "__main__":
    unittest.main()
