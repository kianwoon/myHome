#!/usr/bin/env python3

import logging

import unittest
try:
    from unittest.mock import MagicMock  # Python 3
except ImportError:
    from mock import MagicMock  # py2 use https://pypi.python.org/pypi/mock
import json
import hashlib
import hmac
import os
import shutil
import struct
import tempfile
import time

# Enable info logging to see version information
log = logging.getLogger('tinytuya')
logging.basicConfig()  # TODO include function name/line numbers in log
log.setLevel(level=logging.INFO)
log.setLevel(level=logging.DEBUG)  # Debug hack!

import base64

import tinytuya
from tinytuya.Contrib.RFRemoteControlDevice import RFRemoteControlDevice
from tinytuya.core import message_helper as mh
from tinytuya.core.exceptions import DecodeError

LOCAL_KEY = '0123456789abcdef'

mock_byte_encoding = 'utf-8'


def get_results_from_mock(d):
    result_message_payload = d._send_receive.call_args[0][0]
    result_cmd = result_message_payload.cmd
    result_payload = json.loads(result_message_payload.payload.decode(mock_byte_encoding))
    result_payload["t"] = "" # clear "t"

    return result_cmd, result_payload

def build_mock_bulb(bulb):
    d = tinytuya.BulbDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
    if bulb == 'A':
        d.status = lambda nowait=False: {"devId":"DEVICE_ID","dps":{"1": False, "2":"none", "3": -1, "4": -1, "5":"00000000000000"}} # tell it which commands to support and which DPs need updating
    elif bulb == 'B':
        d.status = lambda nowait=False: {"devId":"DEVICE_ID","dps":{"20": False, "21":"none", "22": -1, "23": -1, "24":"000000000000"}} # tell it which commands to support and DPs need updating
    elif bulb == 'C':
        d.status = lambda nowait=False: {"devId":"DEVICE_ID","dps":{"1": False, "2": -1}} # tell it which commands to support and which DPs need updating
    else:
        raise ValueError("Unknown bulb type %r" % bulb)

    #d.set_bulb_type(bulb) # tell it which commands to support
    d.detect_bulb(d.status()) # tell it which commands to support

    d.set_version(3.1)
    d._send_receive = MagicMock(return_value={})
    return d

class TestXenonDevice(unittest.TestCase):
    def test_set_timer(self):
        # arrange
        d = tinytuya.OutletDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.set_version(3.1)
        mock_response = {"devId":"DEVICE_ID","dps":{"1":False,"2":0}}
        d._send_receive = MagicMock(return_value=mock_response)

        # act
        d.set_timer(6666)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.CONTROL
        expected_payload = {"uid":"DEVICE_ID_HERE","devId":"DEVICE_ID_HERE","t":"","dps":{"2":6666}}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_timer_picks_numeric_max_dp(self):
        # regression: DP keys must be selected numerically, not lexicographically
        # ("9" > "102" as strings, but 102 > 9 as ints)
        d = tinytuya.OutletDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.set_version(3.1)
        # status() supplies the DPS the timer selection scans
        d.status = lambda nowait=False: {"devId":"DEVICE_ID","dps":{"1":False,"9":0,"102":0}}
        d._send_receive = MagicMock(return_value={"devId":"DEVICE_ID","dps":{"1":False,"9":0,"102":0}})

        # act
        d.set_timer(6666)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # assert the timer targeted DP "102", not "9"
        self.assertEqual(result_cmd, tinytuya.CONTROL)
        self.assertDictEqual(result_payload, {"uid":"DEVICE_ID_HERE","devId":"DEVICE_ID_HERE","t":"","dps":{"102":6666}})

    def test_set_status(self):
        # arrange
        d = tinytuya.OutletDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.set_version(3.1)
        d._send_receive = MagicMock(return_value={"devId":"DEVICE_ID","dps":{"1":False,"2":0}})

        # act
        d.set_status(True, 1)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.CONTROL
        expected_payload = {"dps":{"1":True},"uid":"DEVICE_ID_HERE","t":"","devId":"DEVICE_ID_HERE"}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_status(self):
        # arrange
        d = tinytuya.OutletDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.set_version(3.1)
        d._send_receive = MagicMock(return_value={"devId":"DEVICE_ID","dps":{"1":False,"2":0}})

        # act
        d.status()

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.DP_QUERY
        expected_payload = {"devId": "DEVICE_ID_HERE", "gwId": "DEVICE_ID_HERE", "uid": "DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_colour_A(self):
        # arrange
        d = build_mock_bulb('A')

        # act
        d.set_colour(255,127,63)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        print(result_cmd, result_payload)

        # expectations
        expected_cmd = tinytuya.CONTROL
        # expected_payload = {"dps":{"2":"colour", "5":"ffffff000000ff"}, "devId":"DEVICE_ID_HERE","uid":"DEVICE_ID_HERE", "t": ""}
        expected_payload = {"dps":{"1": True, "2":"colour", "5":"ff7f3f0014c0ff"}, "devId":"DEVICE_ID_HERE","uid":"DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_colour_B(self):
        # arrange
        d = build_mock_bulb('B')

        # act
        d.set_colour(255,127,63)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        print(result_cmd, result_payload)

        # expectations
        expected_cmd = tinytuya.CONTROL
        # expected_payload = {"dps":{"2":"colour", "5":"ffffff000000ff"}, "devId":"DEVICE_ID_HERE","uid":"DEVICE_ID_HERE", "t": ""}
        expected_payload = {"dps":{"20": True, "21":"colour", "24":"001402f003e8"}, "devId":"DEVICE_ID_HERE","uid":"DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_white_A(self):
        # arrange
        d = build_mock_bulb('A')

        # act
        d.set_white_percentage(100,100)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        print(result_cmd, result_payload)

        # expectations
        expected_cmd = tinytuya.CONTROL
        # expected_payload = {"dps":{"2":"colour", "5":"ffffff000000ff"}, "devId":"DEVICE_ID_HERE","uid":"DEVICE_ID_HERE", "t": ""}
        expected_payload = {"dps":{'1': True, '2': 'white', '3': 255, '4': 255}, "devId":"DEVICE_ID_HERE","uid":"DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_white_B(self):
        # arrange
        d = build_mock_bulb('B')

        # act
        d.set_white_percentage(100,100)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.CONTROL
        # expected_payload = {"dps":{"2":"white", "3": 255, "4": 255}, "devId": "DEVICE_ID_HERE","uid": "DEVICE_ID_HERE", "t": ""}
        expected_payload = {"dps":{'20': True, "21":"white", "22": 1000, "23": 1000}, "devId": "DEVICE_ID_HERE","uid": "DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_brightness_C(self):
        # arrange
        d = build_mock_bulb('C')

        # act
        d.set_brightness_percentage(100)

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.CONTROL
        # expected_payload = {"dps":{"2":"white", "3": 255, "4": 255}, "devId": "DEVICE_ID_HERE","uid": "DEVICE_ID_HERE", "t": ""}
        expected_payload = {"dps":{'1': True, "2": 255}, "devId": "DEVICE_ID_HERE","uid": "DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_set_bulb_type(self):
        d = tinytuya.BulbDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.status = lambda nowait=False: {"devId":"DEVICE_ID","dps":{"1": False, "2": 90}} # tell it which commands to support and which DPs need updating
        d.set_bulb_type('C') # tell it which commands to support
        d.set_version(3.1)
        d._send_receive = MagicMock(return_value={})

        # act
        d.turn_on()

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.CONTROL
        expected_payload = {"dps":{'1': True}, "devId": "DEVICE_ID_HERE","uid": "DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_not_a_bulb(self):
        d = tinytuya.BulbDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.status = lambda nowait=False: {"devId":"DEVICE_ID","dps":{"1": False}} # tell it which commands to support and which DPs need updating
        #d.set_bulb_type('C') # tell it which commands to support
        d.set_version(3.1)
        d._send_receive = MagicMock(return_value={})

        # act
        d.turn_on()

        # gather results
        result_cmd, result_payload = get_results_from_mock(d)

        # expectations
        expected_cmd = tinytuya.CONTROL
        expected_payload = {"dps":{'1': True}, "devId": "DEVICE_ID_HERE","uid": "DEVICE_ID_HERE", "t": ""}

        # assert
        self.assertEqual(result_cmd, expected_cmd)
        self.assertDictEqual(result_payload, expected_payload)

    def test_percentage_raises_when_unconfigured(self):
        # Regression test: calling *_percentage() before bulb detection,
        # with nowait=True and no cached status, should raise RuntimeError
        # instead of silently computing with value_max=-1.
        d = tinytuya.BulbDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY)
        d.set_version(3.3)
        # No detect_bulb() called, no cached status available
        d.cached_status = MagicMock(return_value=None)

        with self.assertRaises(RuntimeError):
            d.set_brightness_percentage(50, nowait=True)
        with self.assertRaises(RuntimeError):
            d.set_white_percentage(50, 50, nowait=True)
        with self.assertRaises(RuntimeError):
            d.set_colourtemp_percentage(50, nowait=True)


def build_mock_rf():
    d = RFRemoteControlDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY, control_type=1)
    d.set_version(3.3)
    d.set_value = MagicMock()
    return d


class TestRFRemoteControlDevice(unittest.TestCase):
    def test_rf_decode_button_returns_dict(self):
        # Bug 1: rf_decode_button was missing the () call on base64.b64decode,
        # causing it to always return None instead of the decoded JSON dict.
        sample = {"study_feq": "433", "ver": "2"}
        encoded = base64.b64encode(json.dumps(sample).encode()).decode()

        result = RFRemoteControlDevice.rf_decode_button(encoded)

        self.assertIsNotNone(result, "rf_decode_button returned None — function was not called")
        self.assertDictEqual(result, sample)

    def test_rf_send_button_payload_structure(self):
        # Bug 2: send_command('rfstudy_send', ...) was building the wrong payload:
        #   - used 'study_feq' (string) instead of 'feq' (int)
        #   - omitted 'mode' and 'rate' fields
        #   - omitted 'ver' inside each key dict
        # Bug 3: rf_send_button was forwarding study_feq from the decoded button into
        #   feq, but feq must always be 0 so the device uses the frequency embedded in
        #   the code. Passing the actual frequency value selects a different chip path.
        d = build_mock_rf()

        # Use a button that has study_feq set to a non-zero value to confirm it is
        # NOT forwarded into the payload's feq field.
        button_data = {"study_feq": "433", "ver": "2"}
        base64_code = base64.b64encode(json.dumps(button_data).encode()).decode()

        d.rf_send_button(base64_code)

        call_args = d.set_value.call_args
        dp = call_args[0][0]
        payload = json.loads(call_args[0][1])

        self.assertEqual(dp, RFRemoteControlDevice.DP_SEND_IR)
        self.assertEqual(payload['control'], 'rfstudy_send')

        self.assertIn('feq', payload, "payload missing 'feq' (was 'study_feq')")
        self.assertNotIn('study_feq', payload, "payload must not contain 'study_feq' for rfstudy_send")
        self.assertIsInstance(payload['feq'], int, "'feq' must be int, not string")
        self.assertEqual(payload['feq'], 0, "feq must be 0 so the device uses the frequency embedded in the code")
        self.assertIn('mode', payload, "payload missing 'mode'")
        self.assertIn('rate', payload, "payload missing 'rate'")

        self.assertIn('key1', payload)
        self.assertIn('ver', payload['key1'], "key1 missing 'ver'")


class TestLoadDeviceFile(unittest.TestCase):
    """Tests for the load_devicefile() helper."""

    def setUp(self):
        import tempfile
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def _write_json(self, data, fname='devices.json'):
        import os
        path = os.path.join(self.tmpdir, fname)
        with open(path, 'w') as f:
            json.dump(data, f)
        return path

    def test_flat_list(self):
        """Flat list format should be returned as-is."""
        devices = [{'id': 'dev1', 'key': 'abc'}]
        path = self._write_json(devices)
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result, devices)

    def test_wrapped_dict(self):
        """Wrapped {"devices": [...]} format should return the inner list."""
        devices = [{'id': 'dev2', 'key': 'xyz'}]
        path = self._write_json({'devices': devices})
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result, devices)

    def test_missing_file(self):
        """Missing file should return empty list, not raise."""
        result = tinytuya.load_devicefile('/nonexistent_path/devices.json')
        self.assertEqual(result, [])

    def test_empty_list(self):
        """Empty list should return empty list."""
        path = self._write_json([])
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result, [])

    def test_invalid_json(self):
        """Invalid JSON should return empty list, not raise."""
        import os
        path = os.path.join(self.tmpdir, 'bad.json')
        with open(path, 'w') as f:
            f.write('{not valid json')
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result, [])

    def test_non_list_non_dict(self):
        """A JSON file containing a scalar should return empty list."""
        path = self._write_json("just a string")
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result, [])

    def test_dict_without_devices_key(self):
        """A dict without a 'devices' key should return empty list."""
        path = self._write_json({'other_key': [{'id': 'x'}]})
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result, [])

    def test_special_chars_in_key(self):
        """Keys with special characters should be preserved."""
        devices = [{'id': 'dev3', 'key': ":|S'vf<MT6xhr{1~"}]
        path = self._write_json(devices)
        result = tinytuya.load_devicefile(path)
        self.assertEqual(result[0]['key'], ":|S'vf<MT6xhr{1~")


class TestParseHeader(unittest.TestCase):
    """parse_header must accept large IR/AC learn frames (>1000 bytes) while
    still rejecting absurd sizes from a corrupt or desynced stream."""

    def _header_6699(self, payload_len):
        return struct.pack(
            mh.H.MESSAGE_HEADER_FMT_6699,
            mh.H.PREFIX_6699_VALUE, 0, 1, 8, payload_len,
        )

    def test_large_ir_payload_accepted(self):
        # a 1038-byte frame is a real air-conditioner learn report; it must parse
        header = mh.parse_header(self._header_6699(1038) + b'\x00' * 40)
        self.assertEqual(header.length, 1038)

    def test_oversized_payload_rejected(self):
        oversized = self._header_6699(mh.MAX_PAYLOAD_LENGTH + 1)
        with self.assertRaises(DecodeError):
            mh.parse_header(oversized + b'\x00' * 40)


class TestErrorJson(unittest.TestCase):
    """error_json must return the expected dict shape and never raise, even
    for an unknown error code."""

    def test_known_code_shape(self):
        from tinytuya.core.error_helper import error_json, ERR_TIMEOUT
        result = error_json(ERR_TIMEOUT)
        self.assertEqual(result["Error"], "Timeout Waiting for Device")
        self.assertEqual(result["Err"], "902")
        self.assertIsNone(result["Payload"])
        self.assertEqual(set(result.keys()), {"Error", "Err", "Payload"})

    def test_payload_preserved(self):
        from tinytuya.core.error_helper import error_json, ERR_CLOUD
        result = error_json(ERR_CLOUD, "some detail")
        self.assertEqual(result["Payload"], "some detail")
        self.assertEqual(result["Err"], "913")

    def test_unknown_code_does_not_raise(self):
        from tinytuya.core.error_helper import error_json
        result = error_json(99999)
        self.assertEqual(result["Error"], "Unknown Error")
        self.assertEqual(result["Err"], "99999")

    def test_default_none_code(self):
        from tinytuya.core.error_helper import error_json
        result = error_json()
        self.assertEqual(result["Error"], "Unknown Error")
        self.assertEqual(result["Err"], "None")
        self.assertIsNone(result["Payload"])


class TestHexvalueRoundTrip(unittest.TestCase):
    """hexvalue_to_hsv must decode the hue written by rgb_to_hexvalue at the
    correct offset (regression for the [7:10] vs [6:10] off-by-one)."""

    def test_rgb8_round_trip(self):
        import colorsys
        for rgb in ((255, 128, 0), (0, 255, 64), (30, 60, 200)):
            hexvalue = tinytuya.BulbDevice.rgb_to_hexvalue(*rgb, 'rgb8')
            self.assertEqual(len(hexvalue), 14)
            h, s, v = tinytuya.BulbDevice.hexvalue_to_hsv(hexvalue, 'rgb8')
            eh, es, ev = colorsys.rgb_to_hsv(rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0)
            # allow small quantization error from the 8-bit hex encoding
            self.assertAlmostEqual(h, eh, delta=0.01)
            self.assertAlmostEqual(s, es, delta=0.01)
            self.assertAlmostEqual(v, ev, delta=0.01)


class TestSessionCrypto(unittest.TestCase):
    """Session-key negotiation and GCM nonces must use fresh randomness so the
    same nonce/IV is never reused across messages or sessions."""

    def test_client_nonce_is_random_and_16_bytes(self):
        d = tinytuya.OutletDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY, version=3.5)
        d._negotiate_session_key_generate_step_1()
        first = d.local_nonce
        d._negotiate_session_key_generate_step_1()
        second = d.local_nonce
        self.assertEqual(len(first), 16)
        self.assertEqual(len(second), 16)
        self.assertNotEqual(first, second, "client nonce must differ between negotiations")

    def test_gcm_iv_is_random_and_12_bytes(self):
        cipher = mh.AESCipher(LOCAL_KEY.encode('latin1'))
        if not cipher.CRYPTOLIB_HAS_GCM:
            self.skipTest("crypto backend has no GCM support")
        if log.isEnabledFor(logging.DEBUG):
            self.skipTest("debug mode uses a fixed IV for packet troubleshooting")
        iv1 = cipher.get_encryption_iv(True)
        iv2 = cipher.get_encryption_iv(True)
        self.assertEqual(len(iv1), 12)
        self.assertEqual(len(iv2), 12)
        self.assertNotEqual(iv1, iv2, "GCM IV must be random per message")

    def test_receive_rejects_gcm_auth_failure(self):
        key = LOCAL_KEY.encode('latin1')
        cipher = mh.AESCipher(key)
        if not cipher.CRYPTOLIB_HAS_GCM:
            self.skipTest("crypto backend has no GCM support")

        # Build a valid 6699/GCM frame, then flip 1 bit in the tag.
        payload = b'{"x":1}'
        good = mh.pack_message(
            mh.TuyaMessage(1, 16, None, payload, 0, True, mh.H.PREFIX_6699_VALUE, b'\x00' * 12),
            hmac_key=key,
        )
        bad = good[:-5] + bytes([good[-5] ^ 1]) + good[-4:]

        d = tinytuya.OutletDevice('DEVICE_ID_HERE', 'IP_ADDRESS_HERE', LOCAL_KEY, version=3.5)
        d._recv_all = lambda n: bad
        d.local_key = key
        with self.assertRaises(DecodeError):
            d._receive()


import socket as _socket_mod
from tinytuya.core.Monitor import Monitor, _accepts_nowait


class _FakeDevice:
    """Minimal stand-in for a tinytuya Device that Monitor can drive without a
    real network — _get_socket() hands back one end of a socketpair."""

    def __init__(self, dev_id, retry_limit=5):
        self.id = dev_id
        self.socket = None
        self.socketPersistent = False
        self.socketRetryLimit = retry_limit
        self.children = {}
        self.version = 3.3
        self._peer = None
        self.heartbeat_should_fail = False
        self.heartbeat_calls = 0
        self.method_calls = []

    def _get_socket(self, renew):
        s, peer = _socket_mod.socketpair()
        self.socket = s
        self._peer = peer
        return True

    def __del__(self):
        if self._peer is not None:
            try:
                self._peer.close()
            except Exception:
                pass

    def heartbeat(self, nowait=True):
        self.heartbeat_calls += 1
        if self.heartbeat_should_fail:
            # emulate fail-fast: socket closed + cleared, error dict returned
            try:
                self.socket.close()
            except Exception:
                pass
            self.socket = None
            return {"Error": "fail"}
        return None

    def set_value(self, index, value, nowait=False):
        self.method_calls.append(('set_value', index, value, nowait))

    def set_socketPersistent(self, persist):   # note: no nowait param
        self.method_calls.append(('set_socketPersistent', persist))


class TestMonitorReliability(unittest.TestCase):
    """Monitor must own reconnection: monitored devices fail fast instead of
    blocking the reactor or silently opening an unwatched socket."""

    def _make(self, **kw):
        mon = Monitor(**kw)
        self.addCleanup(mon.stop)
        return mon

    def test_add_forces_fail_fast_and_remove_restores(self):
        mon = self._make()
        dev = _FakeDevice('devA', retry_limit=5)
        proxy = mon.add(dev)
        self.assertFalse(isinstance(proxy, str), 'add() should succeed')
        # While monitored, the device must not run its own retry/reconnect loop.
        self.assertEqual(dev.socketRetryLimit, 0)
        state = mon._id_to_state['devA']
        self.assertEqual(state.saved_retry_limit, 5)
        # Removal hands the device back untouched.
        mon.remove(dev)
        self.assertEqual(dev.socketRetryLimit, 5)
        self.assertIsNone(dev.socket)
        self.assertNotIn('devA', mon._id_to_state)

    def test_heartbeat_failure_disconnects_and_enqueues_reconnect(self):
        disconnects = []
        mon = self._make(auto_reconnect=True,
                         on_disconnect=lambda d, e: disconnects.append(d.id))
        dev = _FakeDevice('devB')
        mon.add(dev)
        state = mon._id_to_state['devB']
        self.assertIsNotNone(state.fileno)

        # Simulate a broken connection on the next heartbeat.
        dev.heartbeat_should_fail = True
        mon._do_heartbeat(state)

        # The vanished socket must be detected as a disconnect...
        self.assertEqual(disconnects, ['devB'])
        self.assertIsNone(state.fileno)
        self.assertNotIn(state, mon._devices.values())
        # ...and the device queued for the connector thread to reconnect.
        self.assertIn('devB', mon._reconnect_queue)
        self.assertIn('devB', mon._devices_in_reconnect)

    def test_command_dropped_when_device_not_active(self):
        mon = self._make()
        dev = _FakeDevice('devC')
        mon.add(dev)
        state = mon._id_to_state['devC']
        # Emulate a device mid-reconnect (registered but not yet active).
        state.fileno = None
        mon.command(dev, 'set_value', 1, True)
        mon._drain_queue()
        self.assertEqual(dev.method_calls, [], 'command must not run on an inactive device')

    def test_proxy_injects_nowait_only_when_accepted(self):
        mon = self._make()
        dev = _FakeDevice('devD')
        mon.add(dev)
        # set_value accepts nowait -> injected
        mon.command(dev, 'set_value', 1, True)
        # set_socketPersistent has no nowait param -> must NOT be injected
        mon.command(dev, 'set_socketPersistent', True)
        queued = {name: kwargs for (_id, name, _a, kwargs) in mon._queue}
        self.assertEqual(queued['set_value'].get('nowait'), True)
        self.assertNotIn('nowait', queued['set_socketPersistent'])

    def test_stop_restores_retry_limit_for_disconnected_devices(self):
        """stop() must restore socketRetryLimit even for devices that
        disconnected before stop() was called (in _id_to_state but not _devices)."""
        mon = self._make(auto_reconnect=True)
        dev = _FakeDevice('devE', retry_limit=7)
        mon.add(dev)
        # Simulate a disconnect: device leaves _devices but stays in _id_to_state.
        state = mon._id_to_state['devE']
        dev.heartbeat_should_fail = True
        mon._do_heartbeat(state)
        # Device is now disconnected — socketRetryLimit is still 0.
        self.assertEqual(dev.socketRetryLimit, 0)
        self.assertIn('devE', mon._id_to_state)
        self.assertNotIn(state, mon._devices.values())
        # stop() must restore the original limit.
        mon.stop()
        self.assertEqual(dev.socketRetryLimit, 7)

    def test_accepts_nowait_helper(self):
        self.assertTrue(_accepts_nowait(lambda x, nowait=False: None))
        self.assertTrue(_accepts_nowait(lambda x, **kw: None))
        self.assertFalse(_accepts_nowait(lambda x: None))


class TestScannerKeylist(unittest.TestCase):
    """Discovery must not crash on roster rows without credentials."""

    def test_build_keylist_skips_missing_credentials(self):
        from tinytuya import scanner
        rows = [
            {'id': 'valid', 'key': LOCAL_KEY},
            {'id': 'briturn', 'name': 'Source owned'},
            {'id': 'emptykey', 'key': ''},
            {'key': LOCAL_KEY},
            {'id': 'nonekey', 'key': None},
        ]

        keylist = scanner._build_keylist(rows)

        self.assertEqual([item.gwId for item in keylist], ['valid'])
        self.assertEqual(keylist[0].key, LOCAL_KEY)


class TestBridgeSetRoom(unittest.TestCase):
    """setroom writes local roster metadata and clears on an empty room."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_path = bridge.DEVICES_PATH
        self.old_devices = bridge._devices
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        self.roster = [
            {'id': 'plug1', 'name': 'Desk Plug', 'ip': '10.0.0.5',
             'version': 3.3, 'category': 'cz', 'key': LOCAL_KEY},
            {'id': 'briturn-1', 'name': 'Study Light', 'ip': '10.0.0.6',
             'version': 3.3, 'category': 'briturn', 'group': 'master back'},
        ]
        with open(bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump(self.roster, handle)
        bridge._devices = list(self.roster)

    def tearDown(self):
        self.bridge.DEVICES_PATH = self.old_path
        self.bridge._devices = self.old_devices
        shutil.rmtree(self.directory)

    def stored_room(self):
        with open(self.bridge.DEVICES_PATH, 'r', encoding='utf-8') as handle:
            return json.load(handle)[0].get('room')

    def stored_group(self, device_id):
        with open(self.bridge.DEVICES_PATH, 'r', encoding='utf-8') as handle:
            for device in json.load(handle):
                if device['id'] == device_id:
                    return device.get('group')
        return None

    def test_setroom_persists_and_clears(self):
        result = self.bridge.handle_setroom(
            {'id': 'plug1', 'room': '  Study Room  '})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['room'], 'Study Room')
        self.assertEqual(self.stored_room(), 'Study Room')

        result = self.bridge.handle_setroom({'id': 'plug1', 'room': ''})
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['room'], '')
        self.assertIsNone(self.stored_room())

    def test_setroom_never_writes_group(self):
        result = self.bridge.handle_setroom(
            {'id': 'plug1', 'room': 'Study Room'})
        self.assertTrue(result['ok'], result)
        self.assertIsNone(self.stored_group('plug1'))

        self.assertEqual(self.stored_group('briturn-1'), 'master back')

        listed = {d['id']: d for d in self.bridge.handle_list()['devices']}
        self.assertEqual(listed['plug1']['room'], 'Study Room')
        self.assertIsNone(listed['plug1']['group'])
        self.assertIsNone(listed['briturn-1']['room'])
        self.assertEqual(listed['briturn-1']['group'], 'master back')

    def test_setroom_rejects_bad_input(self):
        self.assertFalse(self.bridge.handle_setroom(
            {'id': 'missing', 'room': 'Study'})['ok'])
        self.assertFalse(self.bridge.handle_setroom(
            {'id': 'plug1', 'room': 'x' * 41})['ok'])
        self.assertFalse(self.bridge.handle_setroom(
            {'id': 'plug1', 'room': '   '})['ok'])
        self.assertFalse(self.bridge.handle_setroom(
            {'id': 'plug1', 'room': None})['ok'])
        self.assertIsNone(self.stored_room())


class TestScheduleInstruction(unittest.TestCase):
    """Schedule instructions instantiate the device's OWN declared control dp.

    Regression: schedadd used a Boolean-only power-code lookup, so a curtain
    (Enum control dp "control") got a schedule with code "switch"/value true —
    a dp it does not have. The timer fired; the curtain never moved.
    """

    def setUp(self):
        import bridge
        self.bridge = bridge

    def curtain(self):
        # Shape mirrors the live spec of the living-room curtain.
        return {'spec': {'1': {'code': 'control', 'type': 'Enum'},
                         '2': {'code': 'percent_control', 'type': 'Integer'}}}

    def plug(self):
        return {'spec': {'1': {'code': 'switch_1', 'type': 'Boolean'}}}

    def test_enum_control_uses_open_close(self):
        self.assertEqual(
            self.bridge._schedule_instruction(self.curtain(), True),
            ('control', 'open'))
        self.assertEqual(
            self.bridge._schedule_instruction(self.curtain(), False),
            ('control', 'close'))

    def test_boolean_control_keeps_bool(self):
        self.assertEqual(
            self.bridge._schedule_instruction(self.plug(), True),
            ('switch_1', True))
        self.assertEqual(
            self.bridge._schedule_instruction(self.plug(), False),
            ('switch_1', False))

    def test_unknown_spec_falls_back_to_switch(self):
        self.assertEqual(
            self.bridge._schedule_instruction({}, True), ('switch', True))


class TestBridgeCloudsyncRooms(unittest.TestCase):
    """cloudsync fills room from the cloud map, keeping manual fallbacks."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_path = bridge.DEVICES_PATH
        self.old_start_autoheal = bridge.start_autoheal
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        with open(bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump([
                {'id': 'cloudcz', 'name': 'Old Name', 'ip': '', 'version': None,
                 'category': 'cz', 'key': '', 'room': 'Old Room'},
                {'id': 'unmapped', 'name': 'Fan', 'ip': '', 'version': None,
                 'category': 'fs', 'key': '', 'room': 'Manual Room'},
            ], handle)
        bridge.start_autoheal = MagicMock()
        self.cloud = MagicMock()
        self.cloud.getdevices = MagicMock(return_value=[
            {'id': 'cloudcz', 'uid': 'uid1', 'name': 'New Name', 'category': 'cz'},
            {'id': 'unmapped', 'name': 'Fan', 'category': 'fs'},
        ])
        bridge.make_cloud = MagicMock(return_value=self.cloud)

    def tearDown(self):
        self.bridge.DEVICES_PATH = self.old_path
        self.bridge.start_autoheal = self.old_start_autoheal
        shutil.rmtree(self.directory)

    def read_roster(self):
        with open(self.bridge.DEVICES_PATH, 'r', encoding='utf-8') as handle:
            return {device['id']: device for device in json.load(handle)}

    def cloud_responses(self):
        def respond(url, action="GET", **kwargs):
            if url == '/v1.0/users/uid1/homes':
                return {'success': True, 'result': [
                    {'home_id': 100, 'name': 'Home'}]}
            if url == '/v1.0/homes/100/rooms':
                return {'success': True, 'result': {
                    'home_id': 100, 'name': 'Home',
                    'rooms': [{'name': 'Office', 'room_id': 'r1'}]}}
            if url == '/v1.0/homes/100/rooms/r1/devices':
                return {'success': True, 'result': [{'id': 'cloudcz'}]}
            raise AssertionError('unexpected cloud url: ' + url)
        return respond

    def test_cloud_room_overwrites_and_unmapped_keeps_manual(self):
        self.cloud.cloudrequest = MagicMock(side_effect=self.cloud_responses())

        result = self.bridge.handle_cloudsync()

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['rooms'], 1)
        roster = self.read_roster()
        self.assertEqual(roster['cloudcz']['room'], 'Office')
        self.assertEqual(roster['cloudcz']['name'], 'New Name')
        self.assertEqual(roster['unmapped']['room'], 'Manual Room')

    def test_room_fetch_failure_keeps_identity_merge(self):
        self.cloud.cloudrequest = MagicMock(
            side_effect=RuntimeError('secret-token-abc'))

        result = self.bridge.handle_cloudsync()

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['rooms'], 0)
        self.assertNotIn('secret', json.dumps(result))
        roster = self.read_roster()
        self.assertEqual(roster['cloudcz']['room'], 'Old Room')
        self.assertEqual(roster['cloudcz']['name'], 'New Name')


class TestCloudDeviceListErrorPropagation(unittest.TestCase):
    """A cloud error dict must never be masked as an empty device roster."""

    ERROR = {
        'Error': 'Error Response from Tuya Cloud',
        'Err': '913',
        'Payload': "Error from Tuya Cloud: Code 28841004: "
                   "'IoT Core trial quota is exhausted.'",
    }

    def make_cloud(self):
        cloud = tinytuya.Cloud.__new__(tinytuya.Cloud)
        cloud.apiDeviceID = None
        cloud.use_old_device_list = True
        return cloud

    def test_get_all_devices_returns_error_dict(self):
        cloud = self.make_cloud()
        cloud.cloudrequest = MagicMock(return_value=self.ERROR)

        self.assertEqual(cloud._get_all_devices(), self.ERROR)

    def test_getdevices_passes_error_dict_through(self):
        cloud = self.make_cloud()
        cloud._get_all_devices = MagicMock(return_value=self.ERROR)

        self.assertEqual(cloud.getdevices(False), self.ERROR)

    def test_get_all_devices_returns_raw_tuya_error_body(self):
        cloud = self.make_cloud()
        error = {'code': 28841004,
                 'msg': 'IoT Core trial quota is exhausted.', 'success': False}
        cloud.cloudrequest = MagicMock(return_value=error)

        self.assertEqual(cloud._get_all_devices(), error)


class TestBridgeCloudsyncCloudError(unittest.TestCase):
    """cloudsync surfaces the cloud's error message, not a fake empty roster."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        # Hermetic: these tests assert the PRIMARY cloud error is surfaced,
        # so the app API fallback must be off regardless of local config.
        bridge.make_appapi = MagicMock(return_value=None)
        self.cloud = MagicMock()
        self.cloud.getdevices = MagicMock(return_value={
            'Error': 'Error Response from Tuya Cloud',
            'Err': '913',
            'Payload': "Error from Tuya Cloud: Code 28841004: "
                       "'IoT Core trial quota is exhausted.'",
        })
        bridge.make_cloud = MagicMock(return_value=self.cloud)

    def tearDown(self):
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi

    def test_error_dict_reports_cloud_message(self):
        result = self.bridge.handle_cloudsync()

        self.assertFalse(result['ok'], result)
        self.assertIn('IoT Core trial quota is exhausted.', result['error'])
        self.assertNotIn('empty or unexpected response', result['error'])
        self.assertNotIn('secret', json.dumps(result))

    def test_raw_tuya_error_body_reports_code_and_message(self):
        self.cloud.getdevices = MagicMock(return_value={
            'code': 28841004,
            'msg': 'IoT Core trial quota is exhausted.',
            'success': False,
        })

        result = self.bridge.handle_cloudsync()

        self.assertFalse(result['ok'], result)
        self.assertIn('28841004', result['error'])
        self.assertIn('IoT Core trial quota is exhausted.', result['error'])


class TestBridgeRescanCloudMerge(unittest.TestCase):
    """handle_rescan reconciles the cloud roster, not just LAN ip deltas."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_path = bridge.DEVICES_PATH
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        self.write_roster([
            {'id': 'lan1', 'name': 'Old Plug', 'ip': '10.0.0.2',
             'version': 3.1, 'category': 'cz', 'key': LOCAL_KEY},
        ])
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        self.old_device_scan = bridge.tinytuya.deviceScan
        bridge.make_appapi = MagicMock(return_value=None)
        bridge.tinytuya.deviceScan = MagicMock(return_value={
            'lan1': {'ip': '10.0.0.9', 'version': 3.3},
        })

    def tearDown(self):
        self.bridge.DEVICES_PATH = self.old_path
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi
        self.bridge.tinytuya.deviceScan = self.old_device_scan
        shutil.rmtree(self.directory)

    def write_roster(self, roster):
        with open(self.bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump(roster, handle)

    def read_roster(self):
        with open(self.bridge.DEVICES_PATH, 'r', encoding='utf-8') as handle:
            return {device['id']: device for device in json.load(handle)}

    def test_rescan_adds_cloud_only_device(self):
        cloud = MagicMock()
        cloud.getdevices = MagicMock(return_value=[{
            'id': 'cloudcz', 'name': 'New Plug', 'category': 'cz',
            'key': 'abcdefghijklmnop123456',
        }])
        self.bridge.make_cloud = MagicMock(return_value=cloud)

        result = self.bridge.handle_rescan({'window': 15})

        self.assertTrue(result['ok'], result)
        self.assertTrue(result['cloud'], result)
        self.assertEqual(result['added'], 1)
        self.assertEqual(result['merged'], 1)
        roster = self.read_roster()
        self.assertIn('cloudcz', roster)
        self.assertEqual(roster['cloudcz']['name'], 'New Plug')
        self.assertTrue(roster['cloudcz']['cloud'])
        self.assertEqual(roster['lan1']['ip'], '10.0.0.9')

    def test_rescan_degrades_when_cloud_fails(self):
        self.bridge.make_cloud = MagicMock(
            side_effect=RuntimeError('secret-token-abc'))

        result = self.bridge.handle_rescan({'window': 15})

        self.assertTrue(result['ok'], result)
        self.assertFalse(result['cloud'], result)
        self.assertEqual(result['merged'], 1)
        self.assertNotIn('secret', json.dumps(result))
        roster = self.read_roster()
        self.assertNotIn('cloudcz', roster)
        self.assertEqual(roster['lan1']['ip'], '10.0.0.9')


class TestBridgeCloudFallback(unittest.TestCase):
    """A failed local exchange falls back to the Tuya cloud, device-agnostic."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.old_devices = bridge._devices
        self.old_make_device = bridge.make_device
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        # Hermetic: a cloud failure must not reach the real app session.
        bridge.make_appapi = MagicMock(return_value=None)
        bridge._devices = [
            {'id': 'fan1', 'name': 'Fan', 'ip': '10.0.0.9', 'version': 3.4,
             'category': 'fs', 'key': LOCAL_KEY,
             'codes': {'switch': '1', 'mode': '2'}},
            {'id': 'raw1', 'name': 'Raw', 'ip': '10.0.0.10', 'version': 3.5,
             'category': 'fs', 'key': LOCAL_KEY},
        ]
        self.cloud = MagicMock()
        bridge.make_cloud = MagicMock(return_value=self.cloud)
        self.device = MagicMock()
        self.device.status = MagicMock(return_value={
            'Error': 914, 'Err': 'Check device key or version'})
        self.device.set_multiple_values = MagicMock(return_value={
            'Error': 914, 'Err': 'Check device key or version'})
        bridge.make_device = MagicMock(return_value=self.device)

    def tearDown(self):
        self.bridge._devices = self.old_devices
        self.bridge.make_device = self.old_make_device
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi

    def cloud_points(self):
        return {'success': True, 'result': [
            {'code': 'switch', 'value': True},
            {'code': 'mode', 'value': 'auto'},
        ]}

    def test_local_status_failure_falls_back_to_cloud_via_codes(self):
        self.cloud.getstatus = MagicMock(return_value=self.cloud_points())

        result = self.bridge.handle_status('fan1')

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['via'], 'cloud')
        self.assertEqual(result['dps'], {'1': True, '2': 'auto'})

    def test_local_status_failure_without_codes_returns_raw(self):
        self.cloud.getstatus = MagicMock(return_value=self.cloud_points())

        result = self.bridge.handle_status('raw1')

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['via'], 'cloud')
        self.assertEqual(result['dps'], {'switch': True, 'mode': 'auto'})

    def test_local_and_cloud_failure_keeps_local_error(self):
        self.cloud.getstatus = MagicMock(
            side_effect=RuntimeError('secret-token-abc'))

        result = self.bridge.handle_status('fan1')

        self.assertFalse(result['ok'], result)
        self.assertIn('device key', result['error'])
        self.assertNotIn('secret', json.dumps(result))

    def test_local_set_failure_maps_dp_to_cloud_code(self):
        self.cloud.sendcommand = MagicMock(return_value={'success': True})

        result = self.bridge.handle_set('fan1', {'1': True})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['via'], 'cloud')
        self.cloud.sendcommand.assert_called_once_with(
            'fan1', {'commands': [{'code': 'switch', 'value': True}]})

    def test_unmappable_dp_is_reported(self):
        self.cloud.sendcommand = MagicMock(return_value={'success': True})

        result = self.bridge.handle_set('raw1', {'1': True})

        self.assertFalse(result['ok'], result)
        self.assertIn('no cloud code for dp 1', result['error'])
        self.cloud.sendcommand.assert_not_called()

    def test_partial_codes_map_sends_mapped_and_reports_rest(self):
        self.cloud.sendcommand = MagicMock(return_value={'success': True})

        result = self.bridge.handle_set('fan1', {'1': True, '99': 5})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['via'], 'cloud')
        self.assertIn('no cloud code for dp 99', result['error'])
        self.cloud.sendcommand.assert_called_once_with(
            'fan1', {'commands': [{'code': 'switch', 'value': True}]})


class TestAppApiSigning(unittest.TestCase):
    """The app API signing vector is fixed by the reference protocol."""

    VECTOR = {
        'a': 'tuya.m.user.email.token.create',
        'clientId': 'vector-client',
        'v': '1.0',
        'time': '1700000000',
    }
    POST_DATA = '{"countryCode":"49","email":"user@example.com"}'

    def setUp(self):
        import appapi
        self.api = appapi.TuyaAppAPI(
            'vector-client', 'vector-secret', 'eu', '49',
            'user@example.com', 'vector-password')

    def test_reference_hmac_vector(self):
        data = dict(self.VECTOR, postData=self.POST_DATA)

        self.assertEqual(
            self.api._sign(data),
            '1b64c5c1ccc6160cc9176e356dfa74fa8071e91b3d956d4f17125a89c3340a69')

    def test_postdata_swizzle_is_md5_reordered(self):
        self.assertEqual(
            self.api._mobile_hash(self.POST_DATA),
            'f0678349a5373c39f5cbda410d1232a7')
        raw = hashlib.md5(self.POST_DATA.encode('utf-8')).hexdigest()
        self.assertNotEqual(self.api._mobile_hash(self.POST_DATA), raw)

    def test_sign_varies_with_postdata_and_ignores_gid(self):
        first = self.api._sign(dict(self.VECTOR, postData=self.POST_DATA))
        second = self.api._sign(dict(self.VECTOR, postData=self.POST_DATA + ' '))
        self.assertNotEqual(first, second)

        with_gid = dict(self.VECTOR, postData=self.POST_DATA, gid='123')
        self.assertEqual(self.api._sign(with_gid), first)

    def test_sign_matches_manual_hmac(self):
        data = dict(self.VECTOR, postData=self.POST_DATA)
        swizzled = self.api._mobile_hash(self.POST_DATA)
        str_to_sign = '||'.join([
            'a=' + data['a'],
            'clientId=' + data['clientId'],
            'postData=' + swizzled,
            'time=' + data['time'],
            'v=' + data['v'],
        ])
        expected = hmac.new(b'vector-secret', str_to_sign.encode('utf-8'),
                            hashlib.sha256).hexdigest()
        self.assertEqual(self.api._sign(data), expected)


class TestAppApiLogin(unittest.TestCase):
    """Login flow, session caching and secret-safe failures."""

    PASSWORD = 'sup3r-secret-password'
    EMAIL = 'user@example.com'
    TOKEN = {'success': True, 'result': {
        'publicKey': '3233', 'exponent': '17', 'token': 'tok-123'}}
    LOGIN = {'success': True, 'result': {'sid': 'sid-1'}}
    GROUPS = {'success': True, 'result': [{'groupId': 'g1'}]}
    DEVICES = {'success': True, 'result': [{
        'devId': 'dev1', 'name': 'Plug', 'localKey': LOCAL_KEY,
        'mac': 'aabbccddeeff', 'uuid': 'uuid-1', 'category': 'cz',
        'productId': 'prod-1', 'iconUrl': 'icon.png', 'virtual': False,
        'dps': {'1': True},
    }]}

    def setUp(self):
        import appapi
        self.appapi = appapi
        self.api = appapi.TuyaAppAPI(
            'cid', 'csecret', 'eu', '49', self.EMAIL, self.PASSWORD)
        self.session = MagicMock()
        self.api._session = self.session

    @staticmethod
    def reply(body):
        response = MagicMock()
        response.json = MagicMock(return_value=body)
        return response

    def test_login_caches_sid_and_encrypts_password(self):
        self.session.post = MagicMock(side_effect=[
            self.reply(self.TOKEN), self.reply(self.LOGIN)])

        self.assertIsNone(self.api.login())
        self.assertEqual(self.api._sid, 'sid-1')

        login_call = self.session.post.call_args_list[1]
        post_data = json.loads(login_call[1]['data']['postData'])
        self.assertEqual(post_data['email'], self.EMAIL)
        self.assertNotEqual(post_data['passwd'], self.PASSWORD)
        self.assertEqual(len(post_data['passwd']), 512)

    def test_getdevices_maps_roster_and_reuses_session(self):
        self.session.post = MagicMock(side_effect=[
            self.reply(self.TOKEN), self.reply(self.LOGIN),
            self.reply(self.GROUPS), self.reply(self.DEVICES),
            self.reply(self.GROUPS), self.reply(self.DEVICES)])

        first = self.api.getdevices()
        second = self.api.getdevices()

        self.assertIsInstance(first, list)
        self.assertEqual(first[0]['id'], 'dev1')
        self.assertEqual(first[0]['key'], LOCAL_KEY)
        self.assertEqual(first[0]['mac'], 'aa:bb:cc:dd:ee:ff')
        self.assertEqual(first[0]['category'], 'cz')
        self.assertEqual(first[0]['product_id'], 'prod-1')
        # Second call reuses the cached sid: only the two list calls repeat.
        self.assertEqual(first, second)
        self.assertEqual(self.session.post.call_count, 6)

    def test_expired_session_reauthenticates_once(self):
        expired = {'success': False, 'errorCode': 'USER_SESSION_INVALID',
                   'errorMsg': 'session expired'}
        self.session.post = MagicMock(side_effect=[
            self.reply(self.TOKEN), self.reply(self.LOGIN),
            self.reply(expired),
            self.reply(self.TOKEN), self.reply(self.LOGIN),
            self.reply(self.GROUPS), self.reply(self.DEVICES)])

        devices = self.api.getdevices()

        self.assertIsInstance(devices, list)
        self.assertEqual(devices[0]['id'], 'dev1')
        self.assertEqual(self.session.post.call_count, 7)

    def test_login_failure_returns_code_only(self):
        failure = {'success': False, 'errorCode': 'USER_PASSWD_WRONG',
                   'errorMsg': 'bad password %s for %s' % (self.PASSWORD,
                                                           self.EMAIL)}
        self.session.post = MagicMock(side_effect=[
            self.reply(self.TOKEN), self.reply(failure)])

        error = self.api.login()

        text = json.dumps(error)
        self.assertEqual(error['Err'], str(self.appapi.ERR_CLOUDTOKEN))
        self.assertIn('USER_PASSWD_WRONG', text)
        self.assertNotIn(self.PASSWORD, text)
        self.assertNotIn(self.EMAIL, text)
        self.assertNotIn('bad password', text)

    def test_network_failure_returns_code_only(self):
        self.session.post = MagicMock(side_effect=self.appapi.requests.Timeout())

        error = self.api.login()

        self.assertEqual(error['Err'], str(self.appapi.ERR_TIMEOUT))
        self.assertNotIn('csecret', json.dumps(error))


class TestBridgeAppApiFallback(unittest.TestCase):
    """cloudsync/rescan fall back to the App API on a remote cloud failure."""

    QUOTA = {'code': 28841004,
             'msg': 'IoT Core trial quota is exhausted.', 'success': False}

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_path = bridge.DEVICES_PATH
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        with open(bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump([
                {'id': 'lan1', 'name': 'Plug', 'ip': '10.0.0.2', 'version': 3.1,
                 'category': 'cz', 'key': LOCAL_KEY},
            ], handle)
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        self.old_start_autoheal = bridge.start_autoheal
        self.old_scan = bridge.tinytuya.deviceScan
        self.cloud = MagicMock()
        self.cloud.getdevices = MagicMock(return_value=self.QUOTA)
        bridge.make_cloud = MagicMock(return_value=self.cloud)
        bridge.start_autoheal = MagicMock()
        bridge.tinytuya.deviceScan = MagicMock(return_value={})
        self.client = MagicMock()
        self.client.getdevices = MagicMock(return_value=[{
            'id': 'appdev', 'name': 'App Plug', 'category': 'cz',
            'key': LOCAL_KEY, 'mac': 'aa:bb:cc:dd:ee:ff'}])
        bridge.make_appapi = MagicMock(return_value=self.client)

    def tearDown(self):
        self.bridge.DEVICES_PATH = self.old_path
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi
        self.bridge.start_autoheal = self.old_start_autoheal
        self.bridge.tinytuya.deviceScan = self.old_scan
        shutil.rmtree(self.directory)

    def read_roster(self):
        with open(self.bridge.DEVICES_PATH, 'r', encoding='utf-8') as handle:
            return {device['id']: device for device in json.load(handle)}

    def test_cloudsync_quota_uses_appapi(self):
        result = self.bridge.handle_cloudsync()

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')
        self.assertEqual(result['added'], 1)
        self.client.getdevices.assert_called_once_with()
        self.bridge.start_autoheal.assert_not_called()
        roster = self.read_roster()
        self.assertIn('appdev', roster)
        self.assertEqual(roster['appdev']['name'], 'App Plug')

    def test_cloudsync_disabled_keeps_primary_error(self):
        self.bridge.make_appapi = MagicMock(return_value=None)

        result = self.bridge.handle_cloudsync()

        self.assertFalse(result['ok'], result)
        self.assertIn('28841004', result['error'])
        self.assertNotIn('source', result)

    def test_local_config_error_is_not_retried(self):
        self.bridge.make_cloud = MagicMock(
            side_effect=TypeError('Tuya Cloud Key and Secret required'))

        result = self.bridge.handle_cloudsync()

        self.assertFalse(result['ok'], result)
        self.bridge.make_appapi.assert_not_called()

    def test_rescan_quota_uses_appapi(self):
        result = self.bridge.handle_rescan({'window': 15})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')
        self.assertFalse(result['cloud'], result)
        self.assertEqual(result['added'], 1)
        roster = self.read_roster()
        self.assertIn('appdev', roster)
        self.assertIn('lan1', roster)


class TestAppApiEmailCode(unittest.TestCase):
    """Passwordless email-code send/login shares the signed transport."""

    PASSWORD = ''
    EMAIL = 'user@example.com'
    CODE_LOGIN = {'success': True,
                  'result': {'sid': 'sid-code', 'at': 'at-code'}}
    SEND_OK = {'success': True, 'result': True}

    def setUp(self):
        import appapi
        self.appapi = appapi
        self.api = appapi.TuyaAppAPI(
            'cid', 'csecret', 'eu', '49', self.EMAIL, self.PASSWORD)
        self.session = MagicMock()
        self.api._session = self.session

    @staticmethod
    def reply(body):
        response = MagicMock()
        response.json = MagicMock(return_value=body)
        return response

    def test_send_email_code_uses_signed_request_without_sid(self):
        self.session.post = MagicMock(return_value=self.reply(self.SEND_OK))

        self.assertIsNone(self.api.send_email_code())

        params = self.session.post.call_args[1]['params']
        data = json.loads(self.session.post.call_args[1]['data']['postData'])
        self.assertEqual(params['a'], 'tuya.m.user.email.code.send')
        self.assertNotIn('sid', params)
        self.assertIn('sign', params)
        self.assertEqual(data, {'countryCode': '49', 'email': self.EMAIL})

    def test_send_email_code_failure_is_code_only(self):
        self.session.post = MagicMock(return_value=self.reply({
            'success': False, 'errorCode': 'SEND_TOO_FREQUENT',
            'errorMsg': 'resend after 60s for ' + self.EMAIL}))

        error = self.api.send_email_code()

        text = json.dumps(error)
        self.assertEqual(error['Err'], str(self.appapi.ERR_CLOUDTOKEN))
        self.assertIn('SEND_TOO_FREQUENT', text)
        self.assertNotIn(self.EMAIL, text)
        self.assertNotIn('resend after', text)

    def test_login_with_code_stores_sid_and_at(self):
        self.session.post = MagicMock(return_value=self.reply(self.CODE_LOGIN))

        self.assertIsNone(self.api.login_with_code('123456'))

        params = self.session.post.call_args[1]['params']
        data = json.loads(self.session.post.call_args[1]['data']['postData'])
        self.assertEqual(params['a'], 'thing.m.user.email.code.login')
        self.assertNotIn('sid', params)
        self.assertEqual(data, {'countryCode': '49', 'email': self.EMAIL,
                                'code': '123456'})
        self.assertEqual(self.api.session_state()['sid'], 'sid-code')
        self.assertEqual(self.api.session_state()['at'], 'at-code')

    def test_bad_code_returns_code_only_without_input_code(self):
        self.session.post = MagicMock(return_value=self.reply({
            'success': False, 'errorCode': 'USER_CODE_INVALID',
            'errorMsg': 'code 123456 expired'}))

        error = self.api.login_with_code('123456')

        text = json.dumps(error)
        self.assertIn('USER_CODE_INVALID', text)
        self.assertNotIn('123456', text)
        self.assertIsNone(self.api.session_state())

    def test_restored_passwordless_session_skips_login(self):
        self.api.restore_session('sid-restored', 'at-restored', 1)
        self.session.post = MagicMock(side_effect=[
            self.reply({'success': True, 'result': [{'groupId': 'g1'}]}),
            self.reply({'success': True, 'result': [{'devId': 'dev1'}]})])

        devices = self.api.getdevices()

        self.assertEqual(devices[0]['id'], 'dev1')
        self.assertEqual(self.session.post.call_count, 2)
        self.check_action = self.session.post.call_args_list[0][1]['params']['a']
        self.assertEqual(self.check_action, 'tuya.m.location.list')


class TestBridgeAppApiSignin(unittest.TestCase):
    """appapi_signin persists only the opaque session, never the code."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_path = bridge.APAPI_SESSION_PATH
        bridge.APAPI_SESSION_PATH = os.path.join(self.directory,
                                                 'appapi-session.json')
        self.old_make_appapi = bridge.make_appapi
        self.client = MagicMock()
        self.client.send_email_code = MagicMock(return_value=None)
        self.client.login_with_code = MagicMock(return_value=None)
        self.client.getdevices = MagicMock(return_value=[{'id': 'dev1'},
                                                         {'id': 'dev2'}])
        self.client.session_state = MagicMock(return_value={
            'sid': 'sid-1', 'at': 'at-1', 'savedAt': 1700000000})
        bridge.make_appapi = MagicMock(return_value=self.client)

    def tearDown(self):
        self.bridge.APAPI_SESSION_PATH = self.old_path
        self.bridge.make_appapi = self.old_make_appapi
        shutil.rmtree(self.directory)

    def session_file(self):
        with open(self.bridge.APAPI_SESSION_PATH, 'r',
                  encoding='utf-8') as handle:
            return json.load(handle)

    def test_send_step_masks_email_and_saves_identity(self):
        result = self.bridge.handle_appapi_signin({
            'step': 'send', 'email': 'wiserly@gmail.com',
            'countryCode': '49'})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['step'], 'sent')
        self.assertNotIn('wiserly@gmail.com', json.dumps(result))
        self.assertEqual(result['email'], 'w…@gmail.com')
        saved = self.session_file()
        self.assertEqual(saved['email'], 'wiserly@gmail.com')
        self.assertEqual(saved['countryCode'], '49')
        self.assertNotIn('sid', saved)
        mode = os.stat(self.bridge.APAPI_SESSION_PATH).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_verify_step_logs_in_and_persists_session(self):
        with open(self.bridge.APAPI_SESSION_PATH, 'w',
                  encoding='utf-8') as handle:
            json.dump({'email': 'wiserly@gmail.com', 'countryCode': '49'},
                      handle)

        result = self.bridge.handle_appapi_signin({
            'step': 'verify', 'code': '987654'})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['step'], 'verified')
        self.assertEqual(result['devices'], 2)
        self.assertNotIn('987654', json.dumps(result))
        self.client.login_with_code.assert_called_once_with('987654')
        saved = self.session_file()
        self.assertEqual(saved['sid'], 'sid-1')
        self.assertEqual(saved['email'], 'wiserly@gmail.com')
        mode = os.stat(self.bridge.APAPI_SESSION_PATH).st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_bad_code_keeps_session_unauthenticated(self):
        self.client.login_with_code = MagicMock(return_value={
            'Error': 'Unable to Get Cloud Token', 'Err': str(
                self.bridge.appapi.ERR_CLOUDTOKEN),
            'Payload': 'USER_CODE_INVALID'})

        result = self.bridge.handle_appapi_signin({
            'step': 'verify', 'code': '000000'})

        self.assertFalse(result['ok'], result)
        self.assertIn('USER_CODE_INVALID', result['error'])
        self.assertNotIn('000000', json.dumps(result))
        self.assertFalse(os.path.exists(self.bridge.APAPI_SESSION_PATH))

    def test_verify_requires_code(self):
        result = self.bridge.handle_appapi_signin({'step': 'verify'})

        self.assertFalse(result['ok'], result)
        self.client.login_with_code.assert_not_called()

    def test_unknown_step_is_rejected(self):
        result = self.bridge.handle_appapi_signin({'step': 'other'})

        self.assertFalse(result['ok'], result)


class TestAppApiEnablement(unittest.TestCase):
    """Enablement is appApiEmail presence; password is optional."""

    QUOTA = {'code': 28841004,
             'msg': 'IoT Core trial quota is exhausted.', 'success': False}

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_credentials = bridge.CREDENTIALS_PATH
        self.old_session = bridge.APAPI_SESSION_PATH
        self.old_devices = bridge.DEVICES_PATH
        bridge.CREDENTIALS_PATH = os.path.join(self.directory, 'tinytuya.json')
        bridge.APAPI_SESSION_PATH = os.path.join(self.directory,
                                                 'appapi-session.json')
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        with open(bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump([{'id': 'lan1', 'name': 'Plug', 'ip': '10.0.0.2',
                        'version': 3.1, 'category': 'cz', 'key': LOCAL_KEY}],
                      handle)
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        self.old_start_autoheal = bridge.start_autoheal
        self.old_scan = bridge.tinytuya.deviceScan
        self.cloud = MagicMock()
        self.cloud.getdevices = MagicMock(return_value=self.QUOTA)
        bridge.make_cloud = MagicMock(return_value=self.cloud)
        bridge.start_autoheal = MagicMock()
        bridge.tinytuya.deviceScan = MagicMock(return_value={})

    def tearDown(self):
        self.bridge.CREDENTIALS_PATH = self.old_credentials
        self.bridge.APAPI_SESSION_PATH = self.old_session
        self.bridge.DEVICES_PATH = self.old_devices
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi
        self.bridge.start_autoheal = self.old_start_autoheal
        self.bridge.tinytuya.deviceScan = self.old_scan
        shutil.rmtree(self.directory)

    def write_config(self, **values):
        with open(self.bridge.CREDENTIALS_PATH, 'w',
                  encoding='utf-8') as handle:
            json.dump(values, handle)

    def write_session(self, values):
        with open(self.bridge.APAPI_SESSION_PATH, 'w',
                  encoding='utf-8') as handle:
            json.dump(values, handle)

    def unauthenticated_client(self):
        client = MagicMock()
        client.getdevices = MagicMock(return_value={
            'Error': 'Unable to Get Cloud Token', 'Err': '911',
            'Payload': 'NO_SESSION'})
        self.bridge.make_appapi = MagicMock(return_value=client)
        return client

    def test_email_only_enables_fallback(self):
        self.write_config(apiRegion='eu', appApiEmail='user@example.com')

        self.assertTrue(self.bridge.appapi_configured())
        client = self.bridge.make_appapi()
        self.assertIsNotNone(client)
        self.assertEqual(client._password, '')

    def test_email_and_password_prefers_password_login(self):
        self.write_config(apiRegion='eu', appApiEmail='user@example.com',
                          appApiPassword='pw')
        client = self.bridge.make_appapi()

        self.assertEqual(client._password, 'pw')

        def reply(body):
            response = MagicMock()
            response.json = MagicMock(return_value=body)
            return response

        client._session.post = MagicMock(side_effect=[
            reply({'success': True, 'result': {'publicKey': '3233',
                                               'exponent': '17',
                                               'token': 'tok'}}),
            reply({'success': True, 'result': {'sid': 'sid-1'}})])
        self.assertIsNone(client.login())
        actions = [call[1]['params']['a']
                   for call in client._session.post.call_args_list]
        self.assertEqual(actions[1], 'tuya.m.user.email.password.login')

    def test_no_email_disables_fallback(self):
        self.write_config(apiRegion='eu', appApiPassword='pw')

        self.assertFalse(self.bridge.appapi_configured())
        self.assertIsNone(self.bridge.make_appapi())

    def test_whitespace_email_disables_fallback(self):
        self.write_config(apiRegion='eu', appApiEmail='   ')

        self.assertFalse(self.bridge.appapi_configured())
        self.assertIsNone(self.bridge.make_appapi())

    def test_whitespace_password_counts_as_no_password(self):
        self.write_config(apiRegion='eu', appApiEmail='user@example.com',
                          appApiPassword='   ')

        client = self.bridge.make_appapi()
        self.assertIsNotNone(client)
        self.assertEqual(client._password, '')

    def test_missing_session_flags_signin_required(self):
        self.write_config(apiRegion='eu', appApiEmail='user@example.com')
        self.unauthenticated_client()

        result = self.bridge.handle_cloudsync()

        self.assertFalse(result['ok'], result)
        self.assertEqual(result['appapi'], 'signin_required')
        self.assertIn('28841004', result['error'])
        self.assertNotIn('user@example.com', json.dumps(result))

    def test_rescan_missing_session_flags_signin_required(self):
        self.write_config(apiRegion='eu', appApiEmail='user@example.com')
        self.unauthenticated_client()

        result = self.bridge.handle_rescan({'window': 15})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['appapi'], 'signin_required')

    def test_persisted_session_uses_fallback_without_hint(self):
        self.write_config(apiRegion='eu', appApiEmail='user@example.com')
        self.write_session({'email': 'user@example.com', 'sid': 'sid-1'})
        client = MagicMock()
        client.getdevices = MagicMock(return_value=[{
            'id': 'appdev', 'name': 'App Plug', 'category': 'cz',
            'key': LOCAL_KEY}])
        self.bridge.make_appapi = MagicMock(return_value=client)

        result = self.bridge.handle_cloudsync()

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')
        self.assertNotIn('appapi', result)


class TestBridgeConfigAppApi(unittest.TestCase):
    """config/setconfig expose only the non-secret app API identity."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_credentials = bridge.CREDENTIALS_PATH
        self.old_session = bridge.APAPI_SESSION_PATH
        bridge.CREDENTIALS_PATH = os.path.join(self.directory, 'tinytuya.json')
        bridge.APAPI_SESSION_PATH = os.path.join(self.directory,
                                                 'appapi-session.json')
        self.old_cloud = bridge.tinytuya.Cloud
        cloud = MagicMock()
        cloud.token = 'token'
        cloud.error = None
        cloud.getdevices = MagicMock(return_value=[])
        bridge.tinytuya.Cloud = MagicMock(return_value=cloud)
        self.cloud = cloud
        self.write_config({'apiKey': 'key-1', 'apiSecret': 'secret-1',
                           'apiRegion': 'eu'})

    def tearDown(self):
        self.bridge.CREDENTIALS_PATH = self.old_credentials
        self.bridge.APAPI_SESSION_PATH = self.old_session
        self.bridge.tinytuya.Cloud = self.old_cloud
        shutil.rmtree(self.directory)

    def write_config(self, values):
        with open(self.bridge.CREDENTIALS_PATH, 'w',
                  encoding='utf-8') as handle:
            json.dump(values, handle)

    def test_config_reports_unsigned_email_and_no_session(self):
        self.write_config({'apiKey': 'key-1', 'apiSecret': 'secret-1',
                           'apiRegion': 'eu',
                           'appApiEmail': 'user@example.com',
                           'appApiCountryCode': '49'})

        reply = self.bridge.handle_config()

        config = reply['config']
        self.assertEqual(config['appApiEmail'], 'user@example.com')
        self.assertEqual(config['appApiCountryCode'], '49')
        self.assertFalse(config['appApiSignedIn'])
        self.assertEqual(config['appApiEmailMasked'], '')
        text = json.dumps(reply)
        self.assertNotIn('secret-1', text)
        self.assertNotIn('appApiPassword', text)
        self.assertNotIn('"sid"', text)

    def test_config_reports_signed_in_masked_email(self):
        self.write_config({'apiKey': 'key-1', 'apiSecret': 'secret-1',
                           'apiRegion': 'eu',
                           'appApiEmail': 'user@example.com'})
        with open(self.bridge.APAPI_SESSION_PATH, 'w',
                  encoding='utf-8') as handle:
            json.dump({'email': 'user@example.com', 'sid': 'sid-1'},
                      handle)

        config = self.bridge.handle_config()['config']

        self.assertTrue(config['appApiSignedIn'])
        self.assertEqual(config['appApiEmailMasked'], 'u…@example.com')
        self.assertNotIn('sid-1', json.dumps(config))

    def test_setconfig_persists_appapi_fields(self):
        result = self.bridge.handle_setconfig({
            'appApiEmail': ' user@example.com ',
            'appApiCountryCode': '49'})

        self.assertTrue(result['ok'], result)
        with open(self.bridge.CREDENTIALS_PATH, 'r',
                  encoding='utf-8') as handle:
            saved = json.load(handle)
        self.assertEqual(saved['appApiEmail'], 'user@example.com')
        self.assertEqual(saved['appApiCountryCode'], '49')
        self.assertEqual(saved['apiKey'], 'key-1')

    def test_setconfig_rejects_non_digit_country(self):
        result = self.bridge.handle_setconfig({
            'appApiEmail': 'user@example.com',
            'appApiCountryCode': 'DE'})

        self.assertFalse(result['ok'], result)
        with open(self.bridge.CREDENTIALS_PATH, 'r',
                  encoding='utf-8') as handle:
            self.assertNotIn('appApiEmail', json.load(handle))


class TestAppApiTimers(unittest.TestCase):
    """App API timer actions translate to/from the bridge's REST shapes."""

    TIMER_BEAN = [{
        'category': {'category': 'myhomeapp', 'status': 1},
        'groups': [{'id': 'g1', 'timers': [{
            'time': '03:07', 'loops': '1000000', 'status': 1,
            'aliasName': 'Test', 'dps': {'1': True},
        }]}],
    }]

    def setUp(self):
        import appapi
        self.appapi = appapi
        self.api = appapi.TuyaAppAPI('cid', 'csecret', 'eu', '49',
                                     'user@example.com', 'pw')
        self.api.restore_session('sid-1', 'at-1', time.time())
        self.session = MagicMock()
        self.api._session = self.session

    @staticmethod
    def reply(body):
        response = MagicMock()
        response.json = MagicMock(return_value=body)
        return response

    def test_timer_list_normalises_to_iothub_shape(self):
        self.session.post = MagicMock(return_value=self.reply(
            {'success': True, 'result': self.TIMER_BEAN}))

        entries, error = self.api.timer_list('dev1')

        self.assertIsNone(error)
        self.assertEqual(entries[0]['category']['category'], 'myhomeapp')
        timer = entries[0]['groups'][0]['timers'][0]
        self.assertEqual(timer['time'], '03:07')
        self.assertEqual(timer['alias_name'], 'Test')
        self.assertEqual(timer['functions'], [{'code': '1', 'value': True}])
        params = self.session.post.call_args[1]['params']
        self.assertEqual(params['a'], 'thing.m.timer.all.list')
        self.assertEqual(params['v'], '2.0')

    def test_timer_add_translates_rest_body(self):
        self.session.post = MagicMock(return_value=self.reply(
            {'success': True, 'result': {'groupId': 'g9'}}))
        body = {
            'category': 'myhomeapp',
            'loops': '1000000',
            'time_zone': '+02:00',
            'timezone_id': 'Europe/Berlin',
            'instruct': [{'time': '03:07',
                          'functions': [{'code': '1', 'value': True}]}],
            'alias_name': 'Test',
        }

        result, error = self.api.timer_add('dev1', body)

        self.assertIsNone(error)
        self.assertEqual(result, {'group_id': 'g9'})
        params = self.session.post.call_args[1]['params']
        data = json.loads(self.session.post.call_args[1]['data']['postData'])
        self.assertEqual(params['a'], 'thing.m.timer.group.add')
        self.assertEqual(data['bizId'], 'dev1')
        self.assertEqual(data['category'], 'myhomeapp')
        self.assertEqual(data['loops'], '1000000')
        self.assertEqual(data['timeZone'], '+02:00')
        self.assertEqual(data['type'], 'device')
        self.assertEqual(data['aliasName'], 'Test')
        instruct = json.loads(data['instruct'])
        self.assertEqual(instruct, [{'time': '03:07', 'dps': {'1': True}}])

    def test_timer_add_recovers_group_id_when_reply_is_empty(self):
        self.session.post = MagicMock(side_effect=[
            self.reply({'success': True, 'result': {}}),
            self.reply({'success': True, 'result': self.TIMER_BEAN}),
        ])
        body = {'category': 'myhomeapp', 'loops': '1000000',
                'time_zone': '+02:00',
                'instruct': [{'time': '03:07',
                              'functions': [{'code': '1', 'value': True}]}]}

        result, error = self.api.timer_add('dev1', body)

        self.assertIsNone(error)
        self.assertEqual(result, {'group_id': 'g1'})

    def test_timer_update_remove_and_status_payloads(self):
        self.session.post = MagicMock(return_value=self.reply(
            {'success': True, 'result': True}))
        body = {'category': 'myhomeapp', 'loops': '1111111',
                'time_zone': '+00:00',
                'instruct': [{'time': '03:07',
                              'functions': [{'code': '1', 'value': False}]}]}

        self.assertEqual(self.api.timer_update('d', 'g1', 'myhomeapp', body),
                         (True, None))
        update_data = json.loads(
            self.session.post.call_args[1]['data']['postData'])
        self.assertEqual(update_data['groupId'], 'g1')
        self.assertEqual(update_data['category'], 'myhomeapp')

        self.assertEqual(self.api.timer_remove('d', 'myhomeapp', 'g1'),
                         (True, None))
        self.assertEqual(
            self.session.post.call_args[1]['params']['a'],
            'thing.m.timer.group.remove')

        self.assertEqual(
            self.api.timer_status_update('d', 'g1', 'myhomeapp', 0),
            (True, None))
        status_data = json.loads(
            self.session.post.call_args[1]['data']['postData'])
        self.assertEqual(status_data['status'], 0)
        self.assertEqual(status_data['groupId'], 'g1')

    def test_timer_call_retries_once_after_session_expiry(self):
        expired = {'success': False, 'errorCode': 'USER_SESSION_INVALID',
                   'errorMsg': 'session expired'}
        token = {'success': True, 'result': {'publicKey': '3233',
                                             'exponent': '17',
                                             'token': 'tok'}}
        login = {'success': True, 'result': {'sid': 'sid-2'}}
        self.session.post = MagicMock(side_effect=[
            self.reply(expired), self.reply(token), self.reply(login),
            self.reply({'success': True, 'result': self.TIMER_BEAN})])

        entries, error = self.api.timer_list('dev1')

        self.assertIsNone(error)
        self.assertEqual(entries[0]['groups'][0]['id'], 'g1')
        self.assertEqual(self.api._sid, 'sid-2')
        self.assertEqual(self.session.post.call_count, 4)


class TestBridgeScheduleFallback(unittest.TestCase):
    """Schedule handlers ride the App API when the primary cloud fails."""

    QUOTA = {'code': 28841004, 'msg': 'IoT Core trial quota is exhausted.',
             'success': False}
    DEVICE = 'bff338test'
    TIMER_BEAN = [{
        'category': {'category': 'myhomeapp', 'status': 1},
        'groups': [{'id': 'g1', 'timers': [{
            'time': '03:07', 'loops': '1000000', 'status': 1,
            'dps': {'1': True},
        }]}],
    }]

    def setUp(self):
        import bridge
        import appapi
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_devices = bridge._devices
        self.old_devices_path = bridge.DEVICES_PATH
        self.old_credentials = bridge.CREDENTIALS_PATH
        self.old_session = bridge.APAPI_SESSION_PATH
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        bridge._devices = [{
            'id': self.DEVICE, 'name': 'Main computer', 'ip': '',
            'version': 3.4, 'category': 'fs', 'key': LOCAL_KEY,
            'spec': {'1': {'code': 'switch', 'type': 'Boolean'}},
        }]
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        bridge.CREDENTIALS_PATH = os.path.join(self.directory, 'tinytuya.json')
        bridge.APAPI_SESSION_PATH = os.path.join(self.directory,
                                                 'appapi-session.json')
        with open(bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump(bridge._devices, handle)
        self.cloud = MagicMock()
        self.cloud.cloudrequest = MagicMock(return_value=self.QUOTA)
        bridge.make_cloud = MagicMock(return_value=self.cloud)
        self.client = appapi.TuyaAppAPI('cid', 'csecret', 'eu', '49',
                                        'user@example.com', 'pw')
        self.client.restore_session('sid-1', 'at-1', time.time())
        self.session = MagicMock()
        self.client._session = self.session
        bridge.make_appapi = MagicMock(return_value=self.client)

    def tearDown(self):
        self.bridge._devices = self.old_devices
        self.bridge.DEVICES_PATH = self.old_devices_path
        self.bridge.CREDENTIALS_PATH = self.old_credentials
        self.bridge.APAPI_SESSION_PATH = self.old_session
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi
        shutil.rmtree(self.directory)

    @staticmethod
    def reply(body):
        response = MagicMock()
        response.json = MagicMock(return_value=body)
        return response

    def test_schedules_list_falls_back(self):
        self.session.post = MagicMock(return_value=self.reply(
            {'success': True, 'result': self.TIMER_BEAN}))

        result = self.bridge.handle_schedules({'id': self.DEVICE})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')
        self.assertEqual(len(result['schedules']), 1)
        entry = result['schedules'][0]
        self.assertEqual(entry['group_id'], 'g1')
        self.assertEqual(entry['time'], '03:07')
        self.assertEqual(entry['action'], 'ON')

    def test_schedadd_falls_back_and_keeps_group_id(self):
        self.session.post = MagicMock(return_value=self.reply(
            {'success': True, 'result': {'groupId': 'g9'}}))

        result = self.bridge.handle_schedadd({
            'id': self.DEVICE, 'days': [True, False, False, False, False,
                                        False, False],
            'time': '03:07', 'on': True, 'name': 'Test'})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['group_id'], 'g9')
        data = json.loads(self.session.post.call_args[1]['data']['postData'])
        self.assertEqual(data['bizId'], self.DEVICE)
        self.assertEqual(data['category'], 'myhomeapp')
        self.assertEqual(data['loops'], '1000000')
        self.assertEqual(data['instruct'],
                         '[{"time":"03:07","dps":{"switch":true}}]')

    def test_scheddel_falls_back(self):
        self.session.post = MagicMock(return_value=self.reply(
            {'success': True, 'result': True}))

        result = self.bridge.handle_scheddel({
            'id': self.DEVICE, 'category': 'myhomeapp', 'group_id': 'g1'})

        self.assertTrue(result['ok'], result)
        self.assertEqual(self.session.post.call_args[1]['params']['a'],
                         'thing.m.timer.group.remove')

    def test_schedtoggle_falls_back_to_update_and_readback(self):
        disabled = [{
            'category': {'category': 'myhomeapp', 'status': 1},
            'groups': [{'id': 'g1', 'timers': [{
                'time': '03:07', 'loops': '1000000', 'status': 0,
                'dps': {'1': True},
            }]}],
        }]
        self.session.post = MagicMock(side_effect=[
            self.reply({'success': True, 'result': self.TIMER_BEAN}),
            self.reply({'success': True, 'result': True}),
            self.reply({'success': True, 'result': disabled}),
        ])

        result = self.bridge.handle_schedtoggle({
            'id': self.DEVICE, 'category': 'myhomeapp', 'group_id': 'g1',
            'enable': False})

        self.assertTrue(result['ok'], result)
        actions = [call[1]['params']['a']
                   for call in self.session.post.call_args_list]
        self.assertEqual(actions,
                         ['thing.m.timer.all.list',
                          'thing.m.timer.group.update',
                          'thing.m.timer.all.list'])

    def test_missing_session_flags_signin_required(self):
        self.bridge.make_appapi = MagicMock(return_value=None)
        with open(self.bridge.CREDENTIALS_PATH, 'w',
                  encoding='utf-8') as handle:
            json.dump({'appApiEmail': 'user@example.com'}, handle)

        result = self.bridge.handle_schedules({'id': self.DEVICE})

        self.assertFalse(result['ok'], result)
        self.assertEqual(result['appapi'], 'signin_required')
        self.assertIn('schedule request failed', result['error'])
        self.assertNotIn('user@example.com', json.dumps(result))

    def test_local_config_error_does_not_fall_back(self):
        self.bridge.make_cloud = MagicMock(
            side_effect=TypeError('Tuya Cloud Key and Secret required'))

        result = self.bridge.handle_schedules({'id': self.DEVICE})

        self.assertFalse(result['ok'], result)
        self.bridge.make_appapi.assert_not_called()


class TestBridgeDeviceFallback(unittest.TestCase):
    """Every device/room/online/spec path rides the app API on a remote fail."""

    QUOTA = {'code': 28841004, 'msg': 'IoT Core trial quota is exhausted.',
             'success': False}
    DEV1 = 'dev1'
    DEV2 = 'dev2'

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_devices = bridge._devices
        self.old_devices_path = bridge.DEVICES_PATH
        self.old_credentials = bridge.CREDENTIALS_PATH
        self.old_session = bridge.APAPI_SESSION_PATH
        self.old_make_cloud = bridge.make_cloud
        self.old_make_appapi = bridge.make_appapi
        bridge.DEVICES_PATH = os.path.join(self.directory, 'devices.json')
        bridge.CREDENTIALS_PATH = os.path.join(self.directory, 'tinytuya.json')
        bridge.APAPI_SESSION_PATH = os.path.join(self.directory,
                                                 'appapi-session.json')
        self.roster = [
            {'id': self.DEV1, 'name': 'Desk Plug', 'ip': '10.0.0.5',
             'version': 3.3, 'category': 'cz', 'key': LOCAL_KEY,
             'product_id': 'pid1', 'codes': {'switch_1': '1'}},
            {'id': self.DEV2, 'name': 'Study Light', 'ip': '',
             'version': 3.3, 'category': 'cz', 'key': LOCAL_KEY,
             'product_id': 'pid2', 'codes': {'switch_1': '1'}},
        ]
        with open(bridge.DEVICES_PATH, 'w', encoding='utf-8') as handle:
            json.dump(self.roster, handle)
        bridge._devices = list(self.roster)
        self.cloud = MagicMock()
        self.client = MagicMock()
        bridge.make_cloud = MagicMock(return_value=self.cloud)
        bridge.make_appapi = MagicMock(return_value=self.client)
        self.old_device = bridge.make_device
        self.device = MagicMock()
        self.device.status = MagicMock(side_effect=RuntimeError('lan down'))
        self.device.set_multiple_values = MagicMock(
            side_effect=RuntimeError('lan down'))
        bridge.make_device = MagicMock(return_value=self.device)
        self.old_autoheal = bridge.start_autoheal
        bridge.start_autoheal = MagicMock()

    def tearDown(self):
        self.bridge._devices = self.old_devices
        self.bridge.DEVICES_PATH = self.old_devices_path
        self.bridge.CREDENTIALS_PATH = self.old_credentials
        self.bridge.APAPI_SESSION_PATH = self.old_session
        self.bridge.make_cloud = self.old_make_cloud
        self.bridge.make_appapi = self.old_make_appapi
        self.bridge.make_device = self.old_device
        self.bridge.start_autoheal = self.old_autoheal
        shutil.rmtree(self.directory)

    def configure_unsigned(self):
        """App API configured (email) but no persisted session."""
        with open(self.bridge.CREDENTIALS_PATH, 'w', encoding='utf-8') as handle:
            json.dump({'appApiEmail': 'user@example.com'}, handle)

    def read_roster(self):
        with open(self.bridge.DEVICES_PATH, 'r', encoding='utf-8') as handle:
            return {device['id']: device for device in json.load(handle)}

    def test_rename_remote_failure_uses_appapi(self):
        self.cloud.cloudrequest = MagicMock(return_value=self.QUOTA)
        self.client.rename_device = MagicMock(return_value=(True, None))

        result = self.bridge.handle_rename({'id': self.DEV1, 'name': 'New'})

        self.assertTrue(result['ok'], result)
        self.assertEqual(set(result), {'ok', 'name'})
        self.assertEqual(result['name'], 'New')
        self.client.rename_device.assert_called_once_with(self.DEV1, 'New')
        self.assertEqual(self.read_roster()[self.DEV1]['name'], 'New')

    def test_rename_local_config_error_never_retried(self):
        self.bridge.make_cloud = MagicMock(
            side_effect=TypeError('Tuya Cloud Key and Secret required'))

        result = self.bridge.handle_rename({'id': self.DEV1, 'name': 'New'})

        self.assertFalse(result['ok'], result)
        self.bridge.make_appapi.assert_not_called()

    def test_status_remote_failure_uses_appapi(self):
        self.cloud.getstatus = MagicMock(return_value=self.QUOTA)
        self.client.device_status = MagicMock(return_value=({'1': True}, None))

        result = self.bridge.handle_status(self.DEV1)

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['via'], 'appapi')
        self.assertEqual(result['dps'], {'1': True})
        self.assertEqual(set(result), {'ok', 'dps', 'via'})

    def test_set_remote_failure_uses_appapi(self):
        self.cloud.sendcommand = MagicMock(return_value=self.QUOTA)
        self.client.publish_dps = MagicMock(return_value=(True, None))

        result = self.bridge.handle_set(self.DEV1, {'1': True})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['via'], 'appapi')
        self.client.publish_dps.assert_called_once_with(self.DEV1, {'1': True})

    def test_status_missing_session_flags_signin_required(self):
        self.configure_unsigned()
        self.cloud.getstatus = MagicMock(return_value=self.QUOTA)
        self.client.device_status = MagicMock(return_value=(None, 'NO_SESSION'))

        result = self.bridge.handle_status(self.DEV1)

        self.assertFalse(result['ok'], result)
        self.assertEqual(result['appapi'], 'signin_required')
        self.assertIn('lan down', result['error'])
        self.assertNotIn('user@example.com', json.dumps(result))

    def test_cloudsync_quota_uses_appapi_room_map(self):
        self.cloud.getdevices = MagicMock(return_value=self.QUOTA)
        self.client.getdevices = MagicMock(return_value=[
            {'id': self.DEV1, 'name': 'Desk Plug', 'category': 'cz',
             'key': LOCAL_KEY},
            {'id': self.DEV2, 'name': 'Study Light', 'category': 'cz',
             'key': LOCAL_KEY},
        ])
        self.client.room_map = MagicMock(
            return_value=({self.DEV1: 'Office'}, None))

        result = self.bridge.handle_cloudsync()

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')
        self.assertEqual(result['rooms'], 1)
        self.assertEqual(self.read_roster()[self.DEV1]['room'], 'Office')

    def test_cloudstatus_uses_one_appapi_list_call(self):
        self.cloud.getconnectstatus = MagicMock(side_effect=RuntimeError('quota'))
        self.client.device_online = MagicMock(
            return_value=({self.DEV1: True, self.DEV2: False}, None))

        result = self.bridge.handle_cloudstatus({})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['status'], {self.DEV1: True, self.DEV2: False})
        self.client.device_online.assert_called_once_with()

    def test_specs_remote_failure_uses_appapi_product_schema(self):
        self.cloud.cloudrequest = MagicMock(return_value=self.QUOTA)
        spec = {'1': {'code': 'switch_1', 'type': 'Boolean', 'values': {}}}
        codes = {'switch_1': '1'}
        self.client.product_specs = MagicMock(
            return_value=({'pid1': (spec, codes), 'pid2': (spec, codes)}, None))

        result = self.bridge.handle_specs({'id': self.DEV1})

        self.assertTrue(result['ok'], result)
        self.assertEqual(set(result), {'ok', 'updated'})
        self.assertEqual(result['updated'], 1)
        roster = self.read_roster()
        self.assertEqual(roster[self.DEV1]['spec'], spec)
        self.assertEqual(roster[self.DEV1]['codes'], codes)

    def test_specs_missing_session_flags_signin_required(self):
        self.configure_unsigned()
        self.cloud.cloudrequest = MagicMock(return_value=self.QUOTA)
        self.client.product_specs = MagicMock(return_value=(None, 'NO_SESSION'))

        result = self.bridge.handle_specs({'id': self.DEV1})

        self.assertFalse(result['ok'], result)
        self.assertEqual(result['appapi'], 'signin_required')
        self.assertIn('spec fetch failed', result['error'])


class TestBridgeCloudTestEitherPath(unittest.TestCase):
    """The cloud test accepts the IoT Core account OR a ready app session."""

    def setUp(self):
        import bridge
        self.bridge = bridge
        self.directory = tempfile.mkdtemp()
        self.old_credentials = bridge.CREDENTIALS_PATH
        self.old_session = bridge.APAPI_SESSION_PATH
        self.old_cloud = bridge.tinytuya.Cloud
        bridge.CREDENTIALS_PATH = os.path.join(self.directory, 'tinytuya.json')
        bridge.APAPI_SESSION_PATH = os.path.join(self.directory,
                                                 'appapi-session.json')
        self.cloud = MagicMock()
        self.cloud.token = 'token'
        self.cloud.getdevices = MagicMock(return_value=[])
        bridge.tinytuya.Cloud = MagicMock(return_value=self.cloud)

    def tearDown(self):
        self.bridge.CREDENTIALS_PATH = self.old_credentials
        self.bridge.APAPI_SESSION_PATH = self.old_session
        self.bridge.tinytuya.Cloud = self.old_cloud
        shutil.rmtree(self.directory)

    def write(self, name, payload):
        with open(os.path.join(self.directory, name), 'w',
                  encoding='utf-8') as handle:
            json.dump(payload, handle)

    def test_appapi_session_alone_is_cloud_configured(self):
        self.write('tinytuya.json', {'appApiEmail': 'user@example.com'})
        self.write('appapi-session.json', {
            'sid': 'sid', 'email': 'user@example.com'})

        result = self.bridge.handle_setconfig({})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')

    def test_quota_failure_reports_appapi_source(self):
        self.write('tinytuya.json', {
            'apiKey': 'key', 'apiSecret': 'secret', 'apiRegion': 'eu',
            'appApiEmail': 'user@example.com'})
        self.write('appapi-session.json', {
            'sid': 'sid', 'email': 'user@example.com'})
        self.cloud.getdevices = MagicMock(return_value={
            'code': 28841004, 'msg': 'quota exhausted', 'success': False})

        result = self.bridge.handle_setconfig({})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'appapi')
        self.assertNotIn('secret', json.dumps(result))

    def test_working_iot_core_reports_cloud_source(self):
        self.write('tinytuya.json', {
            'apiKey': 'key', 'apiSecret': 'secret', 'apiRegion': 'eu'})

        result = self.bridge.handle_setconfig({})

        self.assertTrue(result['ok'], result)
        self.assertEqual(result['source'], 'cloud')


class TestAppApiDeviceOps(unittest.TestCase):
    """Device-op transport shapes, offline, against a mocked session."""

    def setUp(self):
        import appapi
        self.appapi = appapi
        self.api = appapi.TuyaAppAPI(
            'cid', 'csecret', 'eu', '49', 'user@example.com', 'password')
        self.session = MagicMock()
        self.api._session = self.session
        self.api._sid = 'sid'

    @staticmethod
    def reply(body):
        response = MagicMock()
        response.json = MagicMock(return_value=body)
        return response

    def test_publish_dps_sends_app_shape(self):
        self.session.post = MagicMock(
            return_value=self.reply({'success': True, 'result': True}))

        self.assertEqual(self.api.publish_dps('dev1', {'1': True}), (True, None))
        call = self.session.post.call_args
        self.assertEqual(call[1]['params']['a'], 'thing.m.device.dp.publish')
        data = json.loads(call[1]['data']['postData'])
        self.assertEqual(data, {'devId': 'dev1', 'dps': '{"1":true}'})

    def test_device_status_reads_data_point_info(self):
        self.session.post = MagicMock(return_value=self.reply({
            'success': True, 'result': {'dataPointInfo': {'dps': {'1': True}}}}))

        self.assertEqual(self.api.device_status('dev1'), ({'1': True}, None))
        call = self.session.post.call_args
        self.assertEqual(call[1]['params']['a'], 'thing.m.device.get')
        self.assertEqual(call[1]['params']['v'], '4.1')

    def test_device_online_uses_one_list_call(self):
        self.session.post = MagicMock(side_effect=[
            self.reply({'success': True, 'result': [{'groupId': 'g1'}]}),
            self.reply({'success': True, 'result': [
                {'devId': 'dev1', 'moduleMap': {'wifi': {'isOnline': True}}},
                {'devId': 'dev2', 'moduleMap': {'wifi': {'isOnline': False}}},
            ]}),
        ])

        mapping, error = self.api.device_online()

        self.assertIsNone(error)
        self.assertEqual(mapping, {'dev1': True, 'dev2': False})
        self.assertEqual(self.session.post.call_count, 2)

    def test_product_specs_normalise_schema(self):
        schema = [
            {'id': 1, 'code': 'switch_1', 'property': {'type': 'bool'}},
            {'id': 2, 'code': 'mode',
             'property': {'type': 'enum', 'range': ['a', 'b']}},
        ]
        self.session.post = MagicMock(return_value=self.reply({
            'success': True, 'result': [{'id': 'pid1', 'schemaInfo': {
                'schema': json.dumps(schema)}}]}))

        specs, error = self.api.product_specs(['pid1'])

        self.assertIsNone(error)
        spec, codes = specs['pid1']
        self.assertEqual(spec['1']['type'], 'Boolean')
        self.assertEqual(spec['2']['type'], 'Enum')
        self.assertEqual(spec['2']['values'], {'range': ['a', 'b']})
        self.assertEqual(codes, {'switch_1': '1', 'mode': '2'})

    def test_room_map_reads_room_members(self):
        self.session.post = MagicMock(side_effect=[
            self.reply({'success': True, 'result': [{'groupId': 'g1'}]}),
            self.reply({'success': True, 'result': [
                {'id': 7, 'name': 'Office'}]}),
            self.reply({'success': True, 'result': {'deviceSortList': [
                {'bizId': 'dev1', 'bizType': 6}]}}),
        ])

        mapping, error = self.api.room_map()

        self.assertIsNone(error)
        self.assertEqual(mapping, {'dev1': 'Office'})


if __name__ == '__main__':
    unittest.main()
