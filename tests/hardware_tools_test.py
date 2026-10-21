"""Acceptance policy checks; no devices are opened or changed."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from live_support import latency_limit, positive_latency


class AcceptancePolicyTests(unittest.TestCase):
    def test_default_latency_limit_applies_only_to_builtin_outputs(self):
        self.assertEqual(latency_limit({"built_in": True}, None), 20.0)
        self.assertIsNone(latency_limit({"built_in": False}, None))

    def test_explicit_limit_applies_to_either_transport(self):
        for built_in in (True, False):
            self.assertEqual(latency_limit({"built_in": built_in}, 35.5), 35.5)

    def test_invalid_limits_cannot_silently_disable_acceptance(self):
        for value in ("0", "-1", "nan", "inf", "-inf", "abc"):
            with self.assertRaises(ValueError):
                positive_latency(value)
        self.assertEqual(positive_latency("25.5"), 25.5)


if __name__ == "__main__":
    unittest.main()
