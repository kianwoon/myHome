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


class BriturnE0TimerTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(bridge.time, "sleep")
        patcher.start()
        self.addCleanup(patcher.stop)

    # Captured live from a firmware-10 bulb: slot 1 = enabled 19:00 every day, power on.
    LIVE = bytes.fromhex(
        "e00601f0130000fe0ee0010023000000000000000000000200000000000003"
        "000000000000040000000000000500000000000006000000000000")

    def test_parses_live_reply(self):
        slots = bridge._briturn_parse_e0_timers(self.LIVE)
        self.assertEqual(len(slots), 6)
        self.assertEqual(slots[0]["time"], "19:00")
        self.assertTrue(slots[0]["active"])
        self.assertEqual(slots[0]["action"], "on")
        self.assertEqual(slots[0]["days"], list(bridge.BRITURN_DAY_MASKS))
        self.assertTrue(all(not s["active"] and s["time"] is None for s in slots[1:]))

    def test_off_action_and_disabled_flag(self):
        raw = bytearray(self.LIVE)
        raw[2 + 7 + 3] = 0x24
        raw[3] = 0x0F
        slot = bridge._briturn_parse_e0_timers(bytes(raw))[0]
        self.assertEqual(slot["action"], "off")
        self.assertFalse(slot["active"])

    def test_incomplete_or_foreign_reply_is_none(self):
        self.assertIsNone(bridge._briturn_parse_e0_timers(self.LIVE[:30]))
        self.assertIsNone(bridge._briturn_parse_e0_timers(bytes([0x81, 0x5F]) + self.LIVE))
        self.assertIsNone(bridge._briturn_parse_e0_timers(b""))

    def test_slot_frame_matches_live_record(self):
        frame = bridge._briturn_e0_slot_frame(
            1, {"time": "19:00", "days": list(bridge.BRITURN_DAY_MASKS), "action": "on"})
        # Same record the bulb reports (see LIVE), prefixed with the `E0 05` set opcode.
        self.assertEqual(frame, bytes([0xE0, 0x05]) + self.LIVE[2:2 + 21])

    def test_slot_frame_off_empty_and_unsupported(self):
        off = bridge._briturn_e0_slot_frame(
            3, {"time": "03:07", "days": ["mon"], "action": "off"})
        self.assertEqual(off[:9], bytes([0xE0, 0x05, 3, 0xF0, 3, 7, 0, 0x02, 14]))
        self.assertEqual(off[12], 0x24)
        self.assertEqual(len(off), 9 + 14)
        self.assertEqual(bridge._briturn_e0_slot_frame(2, None), bytes([0xE0, 0x05, 2, 0, 0, 0, 0, 0, 0]))
        self.assertEqual(bridge._briturn_e0_slot_frame(
            2, {"time": "25:00", "days": ["mon"], "action": "on"}), bytes([0xE0, 0x05, 2, 0, 0, 0, 0, 0, 0]))
        with self.assertRaises(ValueError):
            bridge._briturn_e0_slot_frame(1, {"time": "08:00", "days": ["mon"], "action": "colour"})

    def test_read_never_reports_empty_when_light_does_not_answer(self):
        cfg = {"id": "briturn-aa", "ip": "1.2.3.4", "category": "briturn"}
        for fw, read, expect in ((NEW_FW, None, "did not answer"), (0, None, "firmware")):
            with mock.patch.object(bridge, "_briturn_resolve", return_value=cfg), \
                 mock.patch.object(bridge, "_briturn_firmware", return_value=fw), \
                 mock.patch.object(bridge, "_briturn_read_e0_timers", return_value=read), \
                 mock.patch.object(bridge.socket, "create_connection") as connect:
                reply = bridge.handle_briturntimers({"id": "briturn-aa"})
            self.assertFalse(reply["ok"])
            self.assertIn(expect, reply["error"])
            connect.assert_not_called()  # no legacy-format read that would look like "empty"

    def test_read_retries_until_light_answers(self):
        cfg = {"id": "briturn-aa", "ip": "1.2.3.4", "category": "briturn"}
        good = bridge._briturn_parse_e0_timers(self.LIVE)
        with mock.patch.object(bridge, "_briturn_resolve", return_value=cfg), \
             mock.patch.object(bridge, "_briturn_firmware", return_value=NEW_FW), \
             mock.patch.object(bridge, "_briturn_read_e0_timers", side_effect=[None, None, good]):
            reply = bridge.handle_briturntimers({"id": "briturn-aa"})
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["timers"][0]["time"], "19:00")

    def test_paused_slot_is_flagged_and_blocks_write(self):
        raw = bytearray(self.LIVE)
        raw[3] = 0x0F
        slots = bridge._briturn_parse_e0_timers(bytes(raw))
        self.assertTrue(slots[0]["paused"])
        self.assertTrue(bridge._briturn_e0_has_unsupported(slots))
        self.assertFalse(bridge._briturn_e0_has_unsupported(bridge._briturn_parse_e0_timers(self.LIVE)))

    def test_set_never_falls_back_to_legacy_on_new_firmware(self):
        cfg = {"id": "briturn-aa", "ip": "1.2.3.4", "category": "briturn"}
        entries = [{"time": "08:00", "days": ["mon"], "action": "on"}]
        for fw, expect_error in ((NEW_FW, "could not read"), (0, "firmware")):
            with mock.patch.object(bridge, "_briturn_resolve", return_value=cfg), \
                 mock.patch.object(bridge, "_briturn_firmware", return_value=fw), \
                 mock.patch.object(bridge, "_briturn_read_e0_timers", return_value=None), \
                 mock.patch.object(bridge, "_briturn_exchange") as exchange:
                reply = bridge.handle_briturntimerset({"id": "briturn-aa", "timers": entries})
            self.assertFalse(reply["ok"])
            self.assertIn(expect_error, reply["error"])
            exchange.assert_not_called()

    def test_set_refuses_scene_slots_and_colour_entries(self):
        cfg = {"id": "briturn-aa", "ip": "1.2.3.4", "category": "briturn"}
        scene = bridge._briturn_parse_e0_timers(self.LIVE)
        scene[0]["action"] = "other"
        with mock.patch.object(bridge, "_briturn_write_e0_timers") as write:
            reply = bridge._briturn_set_e0_timers(cfg, [], scene)
            self.assertFalse(reply["ok"])
            reply = bridge._briturn_set_e0_timers(
                cfg, [{"time": "08:00", "days": ["mon"], "action": "colour"}],
                bridge._briturn_parse_e0_timers(self.LIVE))
            self.assertFalse(reply["ok"])
        write.assert_not_called()

    def test_handler_prefers_e0_on_new_firmware_and_falls_back_on_old(self):
        cfg = {"id": "briturn-aa", "ip": "1.2.3.4", "category": "briturn"}
        with mock.patch.object(bridge, "_briturn_resolve", return_value=cfg), \
             mock.patch.object(bridge, "_briturn_firmware", return_value=NEW_FW), \
             mock.patch.object(bridge, "_briturn_read_e0_timers",
                               return_value=bridge._briturn_parse_e0_timers(self.LIVE)):
            reply = bridge.handle_briturntimers({"id": "briturn-aa"})
        self.assertTrue(reply["ok"])
        self.assertFalse(reply["readonly"])  # plain on/off table is editable
        self.assertEqual(reply["timers"][0]["time"], "19:00")
        with mock.patch.object(bridge, "_briturn_resolve", return_value=cfg), \
             mock.patch.object(bridge, "_briturn_firmware", return_value=OLD_FW), \
             mock.patch.object(bridge, "_briturn_read_e0_timers") as e0, \
             mock.patch.object(bridge.socket, "create_connection", side_effect=OSError):
            reply = bridge.handle_briturntimers({"id": "briturn-aa"})
        e0.assert_not_called()
        self.assertFalse(reply["ok"])


if __name__ == "__main__":
    unittest.main()
