"""Offline tests for MAC-based LAN address recovery (lan_recovery + bridge).

Run: python3 -m unittest test_lan_recovery   (no sockets, no subprocesses)
"""
import importlib.util
import ipaddress
import json
import os
import shutil
import stat
import tempfile
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bridge_lan_under_test", os.path.join(_HERE, "bridge.py"))
bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bridge)
lan_recovery = bridge.lan_recovery

DEVICE_ID = "0123456789abcdef0123"
FAKE_KEY = "abcdefghijklmnop"
OLD_IP = "10.0.5.23"
NEW_IP = "10.0.4.22"
MAC = "0c:a9:19:01:69:fa"

# macOS prints octets without leading zeros and lists a host once per
# interface; incomplete rows have no MAC.
ARP_MOVED = """\
? (10.0.4.1) at a4:6b:1f:98:cb:14 on en0 ifscope [ethernet]
? (10.0.4.2) at (incomplete) on en9 ifscope [ethernet]
? (10.0.4.22) at c:a9:19:1:69:fa on en0 ifscope [ethernet]
? (10.0.4.22) at c:a9:19:1:69:fa on en9 ifscope [ethernet]
"""
ARP_EMPTY = "? (10.0.4.1) at a4:6b:1f:98:cb:14 on en0 ifscope [ethernet]\n"
ARP_SAME = "? (10.0.5.23) at 0c:a9:19:01:69:fa on en0 ifscope [ethernet]\n"

CONNECT_FAIL = {"Error": "Network Error: Unable to Connect", "Err": "901", "Payload": None}
KEY_FAIL = {"Error": "Check device key or version", "Err": "914", "Payload": None}


class FakeDevices(object):
    """tinytuya.Device stand-in: answers only at the IPs listed in `alive`."""

    def __init__(self, alive):
        self.alive = set(alive)
        self.calls = []

    def __call__(self, dev_id, address, local_key="", **kwargs):
        device = mock.MagicMock()
        fake = self

        def status():
            fake.calls.append(("status", address))
            return {"dps": {"1": True}} if address in fake.alive else dict(CONNECT_FAIL)

        def set_multiple_values(dps):
            fake.calls.append(("set", address))
            return {"dps": dps} if address in fake.alive else dict(CONNECT_FAIL)

        device.status.side_effect = status
        device.set_multiple_values.side_effect = set_multiple_values
        return device


class Normalisation(unittest.TestCase):
    def test_normalize_mac_forms(self):
        for raw in ("0c:a9:19:01:69:fa", "c:a9:19:1:69:fa", "0C-A9-19-01-69-FA",
                    "0ca9190169fa", "0ca9.1901.69fa"):
            self.assertEqual(lan_recovery.normalize_mac(raw), MAC, raw)
        for raw in (None, "", "zz:a9:19:01:69:fa", "0c:a9:19:01:69", "0c:a9:19:01:69:fa:00"):
            self.assertIsNone(lan_recovery.normalize_mac(raw), raw)

    def test_parse_arp_drops_incomplete_and_dedupes_interfaces(self):
        entries = lan_recovery.parse_arp(ARP_MOVED)
        self.assertNotIn("10.0.4.2", [ip for ip, _ in entries])
        self.assertEqual(lan_recovery.addresses_for(MAC, entries), [NEW_IP])

    def test_resolve(self):
        moved = lan_recovery.parse_arp(ARP_MOVED)
        self.assertEqual(lan_recovery.resolve(MAC, OLD_IP, moved), (NEW_IP, False))
        self.assertEqual(lan_recovery.resolve(MAC, OLD_IP, lan_recovery.parse_arp(ARP_EMPTY)), (None, True))
        # Still at the stored address: the device is just quiet, no sweep.
        self.assertEqual(lan_recovery.resolve(MAC, OLD_IP, lan_recovery.parse_arp(ARP_SAME)), (None, False))
        ambiguous = moved + [("10.0.4.99", MAC)]
        self.assertEqual(lan_recovery.resolve(MAC, OLD_IP, ambiguous), (None, False))

    def test_parse_network(self):
        mac_out = "\tinet 10.0.4.50 netmask 0xfffffc00 broadcast 10.0.7.255\n"
        self.assertEqual(lan_recovery.parse_network(mac_out, "10.0.4.50"),
                         ipaddress.IPv4Network("10.0.4.0/22"))
        linux = "    inet 10.1.2.3/24 brd 10.1.2.255 scope global eth0\n"
        self.assertEqual(lan_recovery.parse_network(linux, "10.1.2.3"),
                         ipaddress.IPv4Network("10.1.2.0/24"))
        self.assertIsNone(lan_recovery.parse_network(mac_out, "10.9.9.9"))


class Sweep(unittest.TestCase):
    def test_sweep_probes_every_host_but_self(self):
        sent = []
        probed = lan_recovery.sweep(ipaddress.IPv4Network("10.0.0.0/29"), own_address="10.0.0.1",
                                    sender=sent.append, sleep=lambda _: None)
        self.assertEqual(probed, 5)
        self.assertNotIn("10.0.0.1", sent)

    def test_sweep_refuses_oversized_network(self):
        sender = mock.Mock()
        with mock.patch.dict(lan_recovery.CONFIG, {"sweep_max_hosts": 254}):
            probed = lan_recovery.sweep(ipaddress.IPv4Network("10.0.0.0/22"),
                                        sender=sender, sleep=lambda _: None)
        self.assertEqual(probed, 0)
        sender.assert_not_called()

    def test_sweep_ignores_send_errors(self):
        def sender(host):
            raise OSError("host is down")
        probed = lan_recovery.sweep(ipaddress.IPv4Network("10.0.0.0/30"),
                                    sender=sender, sleep=lambda _: None)
        self.assertEqual(probed, 2)


class BridgeRecovery(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "devices.json")
        self.write_roster({"id": DEVICE_ID, "name": "Fan", "key": FAKE_KEY,
                           "ip": OLD_IP, "mac": MAC, "version": "3.4"})
        patches = [
            mock.patch.object(bridge, "DEVICES_PATH", self.path),
            mock.patch.object(bridge, "cloud_status_dps", side_effect=RuntimeError("no cloud")),
            mock.patch.object(bridge, "cloud_set_dps", side_effect=RuntimeError("no cloud")),
            mock.patch.object(lan_recovery, "start_sweep"),
            mock.patch.object(bridge.tuya_probe, "start"),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.sweep = lan_recovery.start_sweep
        bridge._device_cache.clear()
        bridge._devices = bridge.load_devices()
        self.addCleanup(bridge._device_cache.clear)
        self.addCleanup(shutil.rmtree, self.dir)

    def write_roster(self, *entries):
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump(list(entries), handle)
        os.chmod(self.path, 0o600)

    def stored_ip(self):
        with open(self.path, encoding="utf-8") as handle:
            return json.load(handle)[0].get("ip")

    def run_with(self, arp_text, alive, call):
        fake = FakeDevices(alive)
        with mock.patch.object(bridge.tinytuya, "Device", side_effect=fake), \
                mock.patch.object(lan_recovery, "read_arp",
                                  return_value=lan_recovery.parse_arp(arp_text)):
            return call(), fake

    def test_status_ip_changed_is_recovered_and_retried(self):
        reply, fake = self.run_with(ARP_MOVED, [NEW_IP], lambda: bridge.handle_status(DEVICE_ID))
        self.assertEqual(reply, {"ok": True, "dps": {"1": True}})
        self.assertEqual(fake.calls, [("status", OLD_IP), ("status", NEW_IP)])
        self.assertEqual(self.stored_ip(), NEW_IP)
        self.assertEqual(bridge.find_device(DEVICE_ID)["ip"], NEW_IP)
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.sweep.assert_not_called()

    def test_set_ip_changed_is_recovered_and_retried(self):
        reply, fake = self.run_with(ARP_MOVED, [NEW_IP], lambda: bridge.handle_set(DEVICE_ID, {"1": False}))
        self.assertEqual(reply, {"ok": True, "dps": {"1": False}, "confirmed": True})
        self.assertEqual(fake.calls, [("set", OLD_IP), ("set", NEW_IP)])
        self.assertEqual(self.stored_ip(), NEW_IP)

    def test_mac_missing_changes_nothing(self):
        self.write_roster({"id": DEVICE_ID, "key": FAKE_KEY, "ip": OLD_IP, "version": "3.4"})
        bridge._devices = bridge.load_devices()
        reply, fake = self.run_with(ARP_MOVED, [NEW_IP], lambda: bridge.handle_status(DEVICE_ID))
        self.assertFalse(reply["ok"])
        self.assertIn("901", reply["error"])
        self.assertEqual(fake.calls, [("status", OLD_IP)])
        self.assertEqual(self.stored_ip(), OLD_IP)
        self.sweep.assert_not_called()

    def test_arp_miss_keeps_original_error_and_schedules_sweep(self):
        reply, fake = self.run_with(ARP_EMPTY, [NEW_IP], lambda: bridge.handle_status(DEVICE_ID))
        self.assertEqual(reply["ok"], False)
        self.assertEqual(reply["error"], bridge.error_text(CONNECT_FAIL))
        self.assertEqual(fake.calls, [("status", OLD_IP)])
        self.assertEqual(self.stored_ip(), OLD_IP)
        self.sweep.assert_called_once_with(OLD_IP)

    def test_unreadable_arp_table_neither_changes_nor_sweeps(self):
        reply, fake = self.run_with("", [NEW_IP], lambda: bridge.handle_status(DEVICE_ID))
        self.assertEqual(reply["error"], bridge.error_text(CONNECT_FAIL))
        self.assertEqual(fake.calls, [("status", OLD_IP)])
        self.assertEqual(self.stored_ip(), OLD_IP)
        self.sweep.assert_not_called()

    def test_scan_entries_does_not_sweep_unreadable_table(self):
        roster = [{"id": "a", "ip": OLD_IP, "mac": MAC}]
        with mock.patch.object(lan_recovery, "sweep_now") as sweep_now:
            entries = lan_recovery.scan_entries(roster, set(), runner=lambda cmd: "")
        self.assertEqual(entries, [])
        sweep_now.assert_not_called()

    def test_mac_still_at_stored_ip_does_not_sweep(self):
        reply, _ = self.run_with(ARP_SAME, [], lambda: bridge.handle_status(DEVICE_ID))
        self.assertFalse(reply["ok"])
        self.assertEqual(self.stored_ip(), OLD_IP)
        self.sweep.assert_not_called()

    def test_non_connect_error_does_not_recover(self):
        device = mock.MagicMock()
        device.set_multiple_values.return_value = dict(KEY_FAIL)
        with mock.patch.object(bridge.tinytuya, "Device", return_value=device), \
                mock.patch.object(lan_recovery, "read_arp") as read_arp:
            reply = bridge.handle_set(DEVICE_ID, {"1": True})
        self.assertFalse(reply["ok"])
        self.assertIn("914", reply["error"])
        read_arp.assert_not_called()
        self.assertEqual(self.stored_ip(), OLD_IP)

    def test_over_budget_persists_move_but_skips_retry(self):
        with mock.patch.dict(lan_recovery.CONFIG, {"retry_budget": -1}):
            reply, fake = self.run_with(ARP_MOVED, [NEW_IP], lambda: bridge.handle_status(DEVICE_ID))
        self.assertFalse(reply["ok"])
        self.assertEqual(fake.calls, [("status", OLD_IP)])
        self.assertEqual(self.stored_ip(), NEW_IP)


class RosterRefresh(unittest.TestCase):
    def test_refresh_moves_unscanned_devices_only(self):
        entries = lan_recovery.parse_arp(ARP_MOVED)
        roster = [
            {"id": "moved", "ip": OLD_IP, "mac": MAC},
            {"id": "scanned", "ip": OLD_IP, "mac": MAC},
            {"id": "nomac", "ip": OLD_IP},
            {"id": "noip", "mac": MAC},
        ]
        moved = lan_recovery.refresh_roster(roster, {"scanned"}, entries)
        self.assertEqual(moved, 2)
        self.assertEqual([c.get("ip") for c in roster], [NEW_IP, OLD_IP, OLD_IP, NEW_IP])


if __name__ == "__main__":
    unittest.main()
