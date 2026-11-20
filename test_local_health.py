"""Offline tests for local_health.py.

Run: python3 -m unittest test_local_health   (no sockets, no real clock)
"""
import unittest
from unittest import mock

import local_health

DEV = "dev-1"


class LocalHealth(unittest.TestCase):
    def setUp(self):
        self.now = [1000.0]
        patches = [
            mock.patch.object(local_health, "_clock", lambda: self.now[0]),
            mock.patch.dict(local_health.CONFIG, {
                "enabled": True, "codes": frozenset({"914"}),
                "backoff": 100.0, "max_backoff": 350.0}),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        local_health.reset()
        self.addCleanup(local_health.reset)

    def test_non_trigger_code_ignored(self):
        local_health.note_failure(DEV, "901")
        local_health.note_failure(DEV, None)
        self.assertFalse(local_health.should_skip(DEV))

    def test_914_arms_skip(self):
        local_health.note_failure(DEV, "914")
        self.assertTrue(local_health.should_skip(DEV))
        self.assertFalse(local_health.should_skip("other"))

    def test_int_code_accepted(self):
        local_health.note_failure(DEV, 914)
        self.assertTrue(local_health.should_skip(DEV))

    def test_window_expiry_allows_one_retry(self):
        local_health.note_failure(DEV, "914")
        self.now[0] += 99.0
        self.assertTrue(local_health.should_skip(DEV))
        self.now[0] += 2.0
        self.assertFalse(local_health.should_skip(DEV))

    def test_repeat_failure_doubles_and_caps(self):
        local_health.note_failure(DEV, "914")
        self.now[0] += 101.0
        local_health.note_failure(DEV, "914")
        self.now[0] += 199.0
        self.assertTrue(local_health.should_skip(DEV))
        self.now[0] += 2.0
        self.assertFalse(local_health.should_skip(DEV))
        local_health.note_failure(DEV, "914")  # 400 capped to 350
        self.now[0] += 349.0
        self.assertTrue(local_health.should_skip(DEV))
        self.now[0] += 2.0
        self.assertFalse(local_health.should_skip(DEV))

    def test_success_clears(self):
        local_health.note_failure(DEV, "914")
        local_health.note_success(DEV)
        self.assertFalse(local_health.should_skip(DEV))
        local_health.note_failure(DEV, "914")  # back to the base window
        self.now[0] += 101.0
        self.assertFalse(local_health.should_skip(DEV))

    def test_disabled_never_skips(self):
        with mock.patch.dict(local_health.CONFIG, {"enabled": False}):
            local_health.note_failure(DEV, "914")
            self.assertFalse(local_health.should_skip(DEV))
        self.assertFalse(local_health.should_skip(DEV))

    def test_codes_from_env_list(self):
        with mock.patch.dict("os.environ", {"X_CODES": " 914, 905 "}):
            self.assertEqual(local_health._env_codes("X_CODES", "914"),
                             frozenset({"914", "905"}))
        self.assertEqual(local_health._env_codes("X_UNSET_CODES", "914"),
                         frozenset({"914"}))


if __name__ == "__main__":
    unittest.main()
