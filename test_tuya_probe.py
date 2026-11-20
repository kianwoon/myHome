"""Offline tests for the Tuya port probe (tuya_probe + bridge wiring).

Run: python3 -m unittest test_tuya_probe   (no sockets, no subprocesses)
"""
import importlib.util
import ipaddress
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bridge_probe_under_test", os.path.join(_HERE, "bridge.py"))
bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bridge)
tuya_probe = bridge.tuya_probe

DEVICE_ID = "0123456789abcdef0123"
OTHER_ID = "fedcba9876543210fedc"
FAKE_KEY = "abcdefghijklmnop"
OLD_IP = "10.0.5.23"
NEW_IP = "10.0.4.22"
CONNECT_FAIL = {"Error": "Network Error: Unable to Connect", "Err": "901", "Payload": None}


def cfg(device_id=DEVICE_ID, ip=OLD_IP):
    return {"id": device_id, "key": FAKE_KEY, "ip": ip, "version": "3.4"}


class OpenHosts(unittest.TestCase):
    def test_returns_sorted_open_hosts_and_skips_own_address(self):
        network = ipaddress.IPv4Network("10.0.0.0/28")
        seen = []

        def connector(ip, port, timeout):
            seen.append((ip, port, timeout))
            return ip in ("10.0.0.10", "10.0.0.9", "10.0.0.2")

        found = tuya_probe.open_hosts(network, own_address="10.0.0.2", connector=connector)
        self.assertEqual(found, ["10.0.0.9", "10.0.0.10"])
        self.assertNotIn("10.0.0.2", [ip for ip, _, _ in seen])
        self.assertEqual({(port, timeout) for _, port, timeout in seen},
                         {(tuya_probe.CONFIG["port"], tuya_probe.CONFIG["connect_timeout"])})

    def test_refuses_oversized_subnet(self):
        connector = mock.Mock(return_value=True)
        with mock.patch.dict(tuya_probe.CONFIG, {"max_hosts": 254}):
            found = tuya_probe.open_hosts(ipaddress.IPv4Network("10.0.0.0/22"), connector=connector)
        self.assertEqual(found, [])
        connector.assert_not_called()

    def test_missing_network_is_empty(self):
        self.assertEqual(tuya_probe.open_hosts(None, connector=mock.Mock()), [])


class Locate(unittest.TestCase):
    def test_finds_moved_device_preferring_non_roster_hosts(self):
        tried = []

        def identify(ip, config):
            tried.append(ip)
            return ip == NEW_IP

        hosts = ["10.0.4.5", "10.0.4.9", NEW_IP]
        found = tuya_probe.locate([cfg()], hosts, identify, skip_ips=["10.0.4.5", "10.0.4.9"])
        self.assertEqual(found, {DEVICE_ID: NEW_IP})
        self.assertEqual(tried, [NEW_IP])

    def test_roster_hosts_are_tried_last_not_never(self):
        tried = []
        found = tuya_probe.locate(
            [cfg()], ["10.0.4.5", "10.0.4.30"],
            lambda ip, config: tried.append(ip) or ip == "10.0.4.5", skip_ips=["10.0.4.5"])
        self.assertEqual(tried, ["10.0.4.30", "10.0.4.5"])
        self.assertEqual(found, {DEVICE_ID: "10.0.4.5"})

    def test_never_assigns_one_host_to_two_devices(self):
        found = tuya_probe.locate(
            [cfg(DEVICE_ID), cfg(OTHER_ID)], ["10.0.4.7"], lambda ip, config: True)
        self.assertEqual(found, {DEVICE_ID: "10.0.4.7"})

    def test_respects_max_candidates(self):
        tried = []
        hosts = ["10.0.4.%d" % n for n in range(1, 11)]
        with mock.patch.dict(tuya_probe.CONFIG, {"max_candidates": 3}):
            found = tuya_probe.locate([cfg()], hosts, lambda ip, config: tried.append(ip) and False)
        self.assertEqual(found, {})
        self.assertEqual(tried, hosts[:3])

    def test_identify_exception_is_skipped(self):
        def identify(ip, config):
            if ip == "10.0.4.1":
                raise RuntimeError("boom")
            return True
        found = tuya_probe.locate([cfg()], ["10.0.4.1", "10.0.4.2"], identify)
        self.assertEqual(found, {DEVICE_ID: "10.0.4.2"})

    def test_own_stored_address_is_not_retried(self):
        identify = mock.Mock(return_value=True)
        self.assertEqual(tuya_probe.locate([cfg()], [OLD_IP], identify), {})
        identify.assert_not_called()


class Gating(unittest.TestCase):
    def setUp(self):
        tuya_probe.reset()
        self.addCleanup(tuya_probe.reset)

    def test_cloud_online_queues_immediately(self):
        self.assertTrue(tuya_probe.request(cfg(), cloud_online=True))

    def test_offline_needs_failure_threshold(self):
        config = cfg()
        for _ in range(tuya_probe.CONFIG["failure_threshold"] - 1):
            tuya_probe.note_failure(config)
            self.assertFalse(tuya_probe.request(config))
        tuya_probe.note_failure(config)
        self.assertTrue(tuya_probe.request(config))

    def test_success_resets_counter_and_pending(self):
        config = cfg()
        for _ in range(tuya_probe.CONFIG["failure_threshold"]):
            tuya_probe.note_failure(config)
        self.assertTrue(tuya_probe.request(config))
        tuya_probe.note_success(DEVICE_ID)
        self.assertFalse(tuya_probe.request(config))
        self.assertFalse(tuya_probe.start(OLD_IP, mock.Mock(), mock.Mock()))

    def test_backoff_blocks_request_until_it_expires(self):
        tuya_probe.request(cfg(), cloud_online=True, now=100.0)
        tuya_probe.drain(OLD_IP, lambda ip, config: False, mock.Mock(),
                         network=ipaddress.IPv4Network("10.0.4.0/30"),
                         connector=lambda *a: False, now=100.0)
        backoff = tuya_probe.CONFIG["device_backoff"]
        self.assertFalse(tuya_probe.request(cfg(), cloud_online=True, now=100.0 + backoff - 1))
        self.assertTrue(tuya_probe.request(cfg(), cloud_online=True, now=100.0 + backoff + 1))

    def test_start_requires_pending_and_honours_cooldown(self):
        with mock.patch.object(tuya_probe.threading, "Thread") as thread:
            self.assertFalse(tuya_probe.start(OLD_IP, mock.Mock(), mock.Mock(), now=0.0))
            tuya_probe.request(cfg(), cloud_online=True)
            self.assertTrue(tuya_probe.start(OLD_IP, mock.Mock(), mock.Mock(), now=0.0))
            self.assertFalse(tuya_probe.start(OLD_IP, mock.Mock(), mock.Mock(), now=1.0))
            thread.return_value.start.assert_called_once_with()
            tuya_probe._state["running"] = False
            self.assertFalse(tuya_probe.start(OLD_IP, mock.Mock(), mock.Mock(), now=1.0))
            tuya_probe.request(cfg(), cloud_online=True)
            cooldown = tuya_probe.CONFIG["cooldown"]
            self.assertTrue(tuya_probe.start(OLD_IP, mock.Mock(), mock.Mock(), now=cooldown + 1))


class Drain(unittest.TestCase):
    def setUp(self):
        tuya_probe.reset()
        self.addCleanup(tuya_probe.reset)

    def test_persists_match_and_backs_off_unmatched(self):
        tuya_probe.request(cfg(DEVICE_ID), cloud_online=True)
        tuya_probe.request(cfg(OTHER_ID, "10.0.5.99"), cloud_online=True)
        persist = mock.Mock()

        def identify(ip, config):
            return config["id"] == DEVICE_ID and ip == NEW_IP

        persisted = tuya_probe.drain(
            OLD_IP, identify, persist, roster_ips=["10.0.4.5"],
            network=ipaddress.IPv4Network("10.0.4.0/27"),
            connector=lambda ip, port, timeout: ip in (NEW_IP, "10.0.4.5"), now=50.0)
        self.assertEqual(persisted, {DEVICE_ID: NEW_IP})
        persist.assert_called_once_with(DEVICE_ID, NEW_IP)
        self.assertFalse(tuya_probe.request(cfg(OTHER_ID), cloud_online=True, now=51.0))
        self.assertTrue(tuya_probe.request(cfg(DEVICE_ID), cloud_online=True, now=51.0))

    def test_persist_failure_backs_device_off(self):
        tuya_probe.request(cfg(), cloud_online=True)
        persisted = tuya_probe.drain(
            OLD_IP, lambda ip, config: True, mock.Mock(side_effect=OSError("disk")),
            network=ipaddress.IPv4Network("10.0.4.0/30"), connector=lambda *a: True, now=0.0)
        self.assertEqual(persisted, {})
        self.assertFalse(tuya_probe.request(cfg(), cloud_online=True, now=1.0))

    def test_empty_pending_does_nothing(self):
        connector = mock.Mock()
        self.assertEqual(tuya_probe.drain(
            OLD_IP, mock.Mock(), mock.Mock(),
            network=ipaddress.IPv4Network("10.0.4.0/30"), connector=connector), {})
        connector.assert_not_called()


class BridgeWiring(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "devices.json")
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump([cfg(), cfg(OTHER_ID, "10.0.5.40")], handle)
        os.chmod(self.path, 0o600)
        patches = [
            mock.patch.object(bridge, "DEVICES_PATH", self.path),
            mock.patch.object(bridge, "_recover_after", return_value=None),
            mock.patch.object(tuya_probe, "request"),
            mock.patch.object(tuya_probe, "start"),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        tuya_probe.reset()
        self.addCleanup(tuya_probe.reset)
        bridge._device_cache.clear()
        bridge._devices = bridge.load_devices()
        self.addCleanup(bridge._device_cache.clear)
        self.addCleanup(shutil.rmtree, self.dir)

    def failing_device(self):
        device = mock.MagicMock()
        device.status.return_value = dict(CONNECT_FAIL)
        device.set_multiple_values.return_value = dict(CONNECT_FAIL)
        return device

    def test_status_cloud_success_requests_with_cloud_online_and_starts(self):
        with mock.patch.object(bridge.tinytuya, "Device", return_value=self.failing_device()), \
                mock.patch.object(bridge, "cloud_status_dps", return_value=({"1": True}, "cloud")):
            reply = bridge.handle_status(DEVICE_ID)
        self.assertEqual(reply, {"ok": True, "dps": {"1": True}, "via": "cloud"})
        request = tuya_probe.request
        self.assertEqual(request.call_count, 1)
        self.assertEqual(request.call_args[0][0]["id"], DEVICE_ID)
        self.assertIs(request.call_args[1]["cloud_online"], True)
        tuya_probe.start.assert_called_once_with(
            OLD_IP, bridge._identify, bridge._persist_ip, ["10.0.5.40"])

    def test_status_cloud_failure_requests_offline_and_keeps_error(self):
        with mock.patch.object(bridge.tinytuya, "Device", return_value=self.failing_device()), \
                mock.patch.object(bridge, "cloud_status_dps", side_effect=RuntimeError("no cloud")):
            reply = bridge.handle_status(DEVICE_ID)
        self.assertEqual(reply, {"ok": False, "error": bridge.error_text(CONNECT_FAIL)})
        self.assertIs(tuya_probe.request.call_args[1]["cloud_online"], False)
        tuya_probe.start.assert_called_once()

    def test_set_cloud_success_requests_with_cloud_online(self):
        with mock.patch.object(bridge.tinytuya, "Device", return_value=self.failing_device()), \
                mock.patch.object(bridge, "cloud_set_dps", return_value={"ok": True}):
            reply = bridge.handle_set(DEVICE_ID, {"1": True})
        self.assertEqual(reply, {"ok": True})
        self.assertIs(tuya_probe.request.call_args[1]["cloud_online"], True)
        tuya_probe.start.assert_called_once()

    def test_non_connect_error_does_not_probe(self):
        device = mock.MagicMock()
        device.status.return_value = {"Error": "Check device key or version", "Err": "914", "Payload": None}
        with mock.patch.object(bridge.tinytuya, "Device", return_value=device), \
                mock.patch.object(bridge, "cloud_status_dps", side_effect=RuntimeError("no cloud")):
            bridge.handle_status(DEVICE_ID)
        tuya_probe.request.assert_not_called()
        tuya_probe.start.assert_not_called()

    def test_local_success_clears_failure_count(self):
        tuya_probe.note_failure(cfg())
        device = mock.MagicMock()
        device.status.return_value = {"dps": {"1": True}}
        with mock.patch.object(bridge.tinytuya, "Device", return_value=device):
            self.assertEqual(bridge.handle_status(DEVICE_ID), {"ok": True, "dps": {"1": True}})
        self.assertNotIn(DEVICE_ID, tuya_probe._state["failures"])

    def test_identify_uses_fresh_uncached_device_and_closes_it(self):
        device = mock.MagicMock()
        device.status.return_value = {"dps": {"1": True}}
        with mock.patch.object(bridge.tinytuya, "Device", return_value=device) as factory:
            self.assertTrue(bridge._identify(NEW_IP, cfg()))
        args, kwargs = factory.call_args
        self.assertEqual(args, (DEVICE_ID, NEW_IP, FAKE_KEY))
        self.assertEqual(kwargs["connection_timeout"], tuya_probe.CONFIG["identify_timeout"])
        self.assertIs(kwargs["persist"], False)
        device.set_socketTimeout.assert_called_once_with(tuya_probe.CONFIG["identify_timeout"])
        device.close.assert_called_once_with()
        self.assertNotIn(DEVICE_ID, bridge._device_cache)

    def test_identify_false_on_error_dict_and_on_exception(self):
        device = mock.MagicMock()
        device.status.return_value = dict(CONNECT_FAIL)
        with mock.patch.object(bridge.tinytuya, "Device", return_value=device):
            self.assertFalse(bridge._identify(NEW_IP, cfg()))
        device.close.assert_called_once_with()
        with mock.patch.object(bridge.tinytuya, "Device", side_effect=RuntimeError("x")):
            self.assertFalse(bridge._identify(NEW_IP, cfg()))


if __name__ == "__main__":
    unittest.main()
