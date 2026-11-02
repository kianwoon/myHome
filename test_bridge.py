"""Offline tests for bridge.py Briturn packet builders and firmware routing.

Run: python3 -m unittest test_bridge   (no sockets are opened)
"""
import importlib.util
import os
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bridge_under_test", os.path.join(_HERE, "bridge.py"))
bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bridge)

NEW_FW = 10
OLD_FW = 9


def with_cs(payload):
    payload = bytes(payload)
    return payload + bytes([sum(payload) & 0xFF])


def hsv(h, s, v):
    return with_cs([0x3B, 0xA1, h, s, v, 0, 0, 0, 0, 0x1E, 0, 0])


def state_frame(fw, warm=0, cool=0, rgb=(0, 0, 0), power=0x23):
    f = [0x81, 0x5F, power, 0x61, 0x10, 0x50, rgb[0], rgb[1], rgb[2], warm, fw, cool, 0x0F, 0x00]
    return bytes(f)


class PacketBuilders(unittest.TestCase):
    def test_power_new_firmware(self):
        self.assertEqual(bridge._briturn_power_packet(True, NEW_FW), with_cs([0x3B, 0x23] + [0] * 10))
        self.assertEqual(bridge._briturn_power_packet(False, NEW_FW), with_cs([0x3B, 0x24] + [0] * 10))
        self.assertEqual(bridge._briturn_power_packet(True, NEW_FW)[-1], 0x5E)
        self.assertEqual(bridge._briturn_power_packet(False, NEW_FW)[-1], 0x5F)

    def test_power_legacy(self):
        for fw in (0, OLD_FW):
            self.assertEqual(bridge._briturn_power_packet(True, fw), bytes([0x71, 0x23]))
            self.assertEqual(bridge._briturn_power_packet(False, fw), bytes([0x71, 0x24]))

    def test_hsv_red(self):
        self.assertEqual(bridge._briturn_hsv_packet(255, 0, 0, None, NEW_FW), hsv(0, 100, 100))

    def test_hsv_pink(self):
        # (255,0,128): hue 330 deg -> 165, sat 100, val 100
        self.assertEqual(bridge._briturn_hsv_packet(255, 0, 128, None, NEW_FW), hsv(165, 100, 100))

    def test_hsv_white_centre(self):
        self.assertEqual(bridge._briturn_hsv_packet(255, 255, 255, None, NEW_FW), hsv(0, 0, 100))

    def test_hsv_hue_halved(self):
        self.assertEqual(bridge._briturn_hsv_packet(0, 255, 0, None, NEW_FW), hsv(60, 100, 100))
        self.assertEqual(bridge._briturn_hsv_packet(0, 0, 255, None, NEW_FW), hsv(120, 100, 100))

    def test_hsv_brightness_scales_value(self):
        self.assertEqual(bridge._briturn_hsv_packet(255, 0, 0, 50, NEW_FW), hsv(0, 100, 50))
        self.assertEqual(bridge._briturn_hsv_packet(255, 0, 0, 100, NEW_FW), hsv(0, 100, 100))

    def test_hsv_clamping(self):
        self.assertEqual(bridge._briturn_hsv_packet(999, -5, 0, 250, NEW_FW), hsv(0, 100, 100))
        self.assertEqual(bridge._briturn_hsv_packet(255, 0, 0, -10, NEW_FW), hsv(0, 100, 0))
        # hue just below 360 rounds to 180 and must not exceed it
        pk = bridge._briturn_hsv_packet(255, 0, 1, None, NEW_FW)
        self.assertLessEqual(pk[2], 180)

    def test_hsv_legacy(self):
        self.assertEqual(bridge._briturn_hsv_packet(255, 0, 0, 50, OLD_FW),
                         bytes([0x31, 255, 0, 0, 0, 0xF0, 0xAA]))

    def test_brightness_packet(self):
        self.assertEqual(bridge._briturn_brightness_packet(50),
                         with_cs([0x3B, 0x01, 0, 0, 50, 0, 50, 0, 0, 0, 0, 0]))
        self.assertEqual(bridge._briturn_brightness_packet(100),
                         with_cs([0x3B, 0x01, 0, 0, 100, 0, 100, 0, 0, 0, 0, 0]))
        self.assertEqual(bridge._briturn_brightness_packet(500)[4], 100)
        self.assertEqual(bridge._briturn_brightness_packet(-5)[4], 0)

    def test_cct_packets(self):
        for cct in (0, 50, 100):
            self.assertEqual(bridge._briturn_cct_packet(cct, 100),
                             with_cs([0x3B, 0xB1, 0, 0, 0, cct, 100, 0, 0, 0x1E, 0, 0]))
        self.assertEqual(bridge._briturn_cct_packet(150, 100)[5], 100)


class FirmwareCache(unittest.TestCase):
    def setUp(self):
        bridge._briturn_fw_cache.clear()
        self.cfg = {"id": "briturn-aa", "ip": "192.0.2.1", "category": "briturn"}

    def test_miss_reads_and_caches(self):
        with mock.patch.object(bridge, "_briturn_exchange", return_value=state_frame(NEW_FW)) as ex:
            self.assertEqual(bridge._briturn_firmware(self.cfg), NEW_FW)
            self.assertEqual(bridge._briturn_firmware(self.cfg), NEW_FW)
        self.assertEqual(ex.call_count, 1)
        self.assertEqual(bridge._briturn_fw_cache["briturn-aa"], NEW_FW)

    def test_hit_does_no_io(self):
        bridge._briturn_fw_cache["briturn-aa"] = OLD_FW
        with mock.patch.object(bridge, "_briturn_exchange") as ex:
            self.assertEqual(bridge._briturn_firmware(self.cfg), OLD_FW)
        ex.assert_not_called()

    def test_read_failure_falls_back_to_legacy(self):
        with mock.patch.object(bridge, "_briturn_exchange", return_value=None):
            fw = bridge._briturn_firmware(self.cfg)
        self.assertEqual(fw, 0)
        self.assertNotIn("briturn-aa", bridge._briturn_fw_cache)
        self.assertEqual(bridge._briturn_power_packet(True, fw), bridge.BRITURN_ON)

    def test_status_read_fills_cache_and_reports_firmware(self):
        with mock.patch.object(bridge, "find_device", return_value=self.cfg), \
                mock.patch.object(bridge, "_briturn_exchange", return_value=state_frame(NEW_FW)):
            reply = bridge.handle_briturnstatus({"id": "briturn-aa"})
        self.assertEqual(reply["firmware"], NEW_FW)
        self.assertEqual(bridge._briturn_fw_cache["briturn-aa"], NEW_FW)


class SetRouting(unittest.TestCase):
    def setUp(self):
        bridge._briturn_fw_cache.clear()
        self.cfg = {"id": "briturn-aa", "ip": "192.0.2.1", "category": "briturn"}
        self.sent = []

        def fake_exchange(ip, send, expect_reply=True, attempts=2, timeout=3.0):
            if send == bridge.BRITURN_QUERY:
                return state_frame(self.fw, warm=0, cool=0, rgb=(255, 0, 0))
            self.sent.append(bytes(send))
            return b""

        patches = [
            mock.patch.object(bridge, "find_device", return_value=self.cfg),
            mock.patch.object(bridge, "_briturn_exchange", side_effect=fake_exchange),
            mock.patch.object(bridge.time, "sleep"),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.fw = NEW_FW

    def test_new_fw_power_colour_brightness(self):
        bridge.handle_briturnset({"id": "briturn-aa", "on": True, "r": 255, "g": 0, "b": 0, "brightness": 50})
        self.assertEqual(self.sent, [bridge._briturn_power_packet(True, NEW_FW), hsv(0, 100, 50)])

    def test_new_fw_brightness_only_no_read_needed(self):
        bridge.handle_briturnset({"id": "briturn-aa", "brightness": 50})
        self.assertEqual(self.sent, [bridge._briturn_brightness_packet(50)])

    def test_explicit_w_uses_legacy_colour(self):
        bridge.handle_briturnset({"id": "briturn-aa", "r": 1, "g": 2, "b": 3, "w": 128})
        self.assertEqual(self.sent, [bytes([0x31, 1, 2, 3, 128, 0xF0, 0xAA])])

    def test_legacy_fw_unchanged(self):
        self.fw = OLD_FW
        bridge.handle_briturnset({"id": "briturn-aa", "on": False, "r": 9, "g": 8, "b": 7})
        self.assertEqual(self.sent, [bridge.BRITURN_OFF, bytes([0x31, 9, 8, 7, 0, 0xF0, 0xAA])])

    def test_cct_path_kept(self):
        bridge.handle_briturnset({"id": "briturn-aa", "cct": 0, "brightness": 80})
        self.assertEqual(self.sent, [bridge._briturn_cct_packet(0, 80)])


if __name__ == "__main__":
    unittest.main()
