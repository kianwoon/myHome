"""Persistent stdio JSON-lines bridge over tinytuya for the macOS app.

baseline-guard:allow new file, no prior baseline exists

Reads one JSON request per line from stdin and writes exactly one JSON response
per line to stdout. Device local keys are never logged or emitted.

Requests:
    {"cmd":"ping"}
    {"cmd":"list"}
    {"cmd":"status","id":"<device-id>"}
    {"cmd":"set","id":"<device-id>","dps":{...}}
    {"cmd":"rename","id":"<device-id>","name":"<new-name>"}
    {"cmd":"briturnstatus","id":"<briturn-device-id>"}
    {"cmd":"briturnset","id":"<briturn-device-id>","on":true,"r":255,"g":0,"b":0}
    {"cmd":"briturngroup","id":"<briturn-device-id>","group":"Living Room"}
    {"cmd":"briturnsetgroup","group":"Living Room","on":true,"r":255,"g":0,"b":0}
    {"cmd":"briturntimers","id":"<briturn-device-id>"}
    {"cmd":"briturntimerset","id":"<briturn-device-id>","timers":[{"time":"08:00","days":["mon","tue"],"action":"on"},{"time":"22:00","days":["mon","tue","wed"],"action":"off"}]}
    {"cmd":"briturntimersetgroup","group":"Living Room","timers":[...same entries...]}
    {"cmd":"rescan"}
    {"cmd":"cloudsync"}
    {"cmd":"cloudstatus"}
    {"cmd":"cloudstatus","id":"<device-id>"}
    {"cmd":"schedules","id":"<device-id>"}
    {"cmd":"schedadd","id":"<device-id>","name":"...","days":[1,0,1,0,1,0,0],"time":"HH:MM","on":true}
    {"cmd":"scheddel","id":"<device-id>","category":"...","group_id":"..."}
    {"cmd":"schededit","id":"<device-id>","category":"...","group_id":"...","name"?,"days"?,"time"?,"on"?}
    {"cmd":"schedtoggle","id":"<device-id>","category":"...","group_id":"...","enable":true}
    {"cmd":"codemap"}
    {"cmd":"codemap","id":"<device-id>"}
    {"cmd":"specs"}
    {"cmd":"specs","id":"<device-id>"}
    {"cmd":"config"}
    {"cmd":"setconfig","apiKey":"...","apiSecret":"...","apiRegion":"..."}
    {"cmd":"gh_list"}
    {"cmd":"gh_states","id"?:"<google-home-device-id>"}
    {"cmd":"gh_action","id":"<google-home-device-id>","action":"<action-name>"}
"""

import json
import os
import re
import socket
import sys
import tempfile
import threading
import time

import tinytuya

try:
    import requests as _requests  # noqa: F401 — capability probe only
    CLOUD_CAPABLE = True
except ImportError:
    # tinytuya's Cloud client needs requests; without it every cloud-backed
    # command (cloudsync, schedules, cloudstatus) fails. Surface this as a
    # structured flag so the UI can show a broken-bridge-env state instead of
    # the user seeing unexplained timeouts.
    CLOUD_CAPABLE = False

try:
    import google_home
except Exception:  # pragma: no cover - import must never break the bridge
    google_home = None

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEVICES_PATH = os.path.join(BASE_DIR, "devices.json")
CREDENTIALS_PATH = os.path.join(BASE_DIR, "tinytuya.json")

SOCKET_TIMEOUT = 5

# Zengge/Briturn WiFi lights answer a UDP broadcast on 48899 with
# "<ip>,<mac>,<module>,<id>". Probes go to the global broadcast plus the
# addresses used by the two setup APs.
BRITURN_PORT = 48899
BRITURN_PROBE = b"HF-A11ASSISTHREAD"
BRITURN_BROADCASTS = ("255.255.255.255", "192.168.4.255", "192.168.5.255")
BRITURN_IP = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")

# Consecutive cloudsync cycles a device may be missing from the cloud report
# before it is pruned from the roster (~2 cycles x 5 min = 10 min of confirmed
# absence, which filters transient/partial cloud API responses).
pruneAfterMissedSyncs = 2

# UDP listen window for an auto-heal scan, and the single-flight guard that
# keeps at most one background heal running per bridge process.
autohealScanWindow = 35
_autoheal_lock = threading.Lock()
_autoheal_running = False

# Fields the cloud is authoritative for: device IDENTITY AND CREDENTIALS.
# Local-only fields (ip, version, spec) are never touched by cloudsync.
CLOUD_IDENTITY_FIELDS = (
    "name",
    "key",
    "category",
    "mac",
    "uuid",
    "model",
    "product_id",
    "product_name",
    "icon",
)

# Device objects keyed by device id; reused so persistent sockets are shared.
_device_cache = {}
# In-memory copy of devices.json, refreshed by rescan.
_devices = []


def load_devices():
    """Read devices.json (a wizard-format list) and return its device list."""
    with open(DEVICES_PATH, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("devices", [])
    return data if isinstance(data, list) else []


# Serializes the whole load-modify-write: apply_to_disk is now reachable from
# concurrent worker threads, and an unguarded read/rewrite would drop updates.
_DISK_LOCK = threading.Lock()


def apply_to_disk(mutator):
    """Read-modify-write devices.json and refresh the serving cache.

    General rule: devices.json is SHARED MUTABLE STATE across independent
    bridge processes. No writer may dump its in-memory roster; every write
    re-reads the file, applies only that command's field-level delta to the
    fresh copy (by id), and writes that back. The write is atomic: a temp file
    in the same directory followed by os.replace.
    """
    global _devices
    with _DISK_LOCK:
        fresh = load_devices()
        mutator(fresh)

        directory = os.path.dirname(DEVICES_PATH) or "."
        descriptor, temp_path = tempfile.mkstemp(
            prefix=".devices-", suffix=".json", dir=directory
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(fresh, handle, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, DEVICES_PATH)
        except Exception:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
            raise

        _devices = fresh
        return fresh


def find_device(device_id):
    for device in _devices:
        if device.get("id") == device_id:
            return device
    return None


def make_device(config):
    """Build (or reuse) a tinytuya.Device for a devices.json entry."""
    device_id = config.get("id")
    cached = _device_cache.get(device_id)
    if cached is not None:
        return cached

    version = config.get("version", 3.1)
    try:
        version = float(version)
    except (TypeError, ValueError):
        version = 3.1

    device = tinytuya.Device(
        device_id,
        config.get("ip"),
        config.get("key", ""),
        version=version,
        connection_timeout=SOCKET_TIMEOUT,
        persist=False,
    )
    device.set_socketTimeout(SOCKET_TIMEOUT)
    _device_cache[device_id] = device
    return device


def error_text(result):
    """Human-readable error from a tinytuya error dict."""
    if not isinstance(result, dict):
        return "device did not respond"
    parts = []
    for key in ("Error", "Err", "Payload"):
        if result.get(key):
            parts.append(str(result[key]))
    return ": ".join(parts) if parts else "device did not respond"


def read_status(device):
    """Return dps dict from a status() result, or raise ValueError."""
    result = device.status()
    if isinstance(result, dict) and isinstance(result.get("dps"), dict):
        return result["dps"]
    raise ValueError(error_text(result))


def handle_status(device_id):
    config = find_device(device_id)
    if config is None:
        return {"ok": False, "error": "unknown device id"}
    if not config.get("ip"):
        return {"ok": False, "error": "device has no known ip"}
    try:
        dps = read_status(make_device(config))
        return {"ok": True, "dps": dps}
    except Exception as exc:  # network failures must stay on the wire path
        return {"ok": False, "error": str(exc) or "status failed"}


def handle_set(device_id, dps):
    config = find_device(device_id)
    if config is None:
        return {"ok": False, "error": "unknown device id"}
    if not config.get("ip"):
        return {"ok": False, "error": "device has no known ip"}
    if not isinstance(dps, dict) or not dps:
        return {"ok": False, "error": "dps must be a non-empty object"}
    try:
        device = make_device(config)
        result = device.set_multiple_values(dps)
        if isinstance(result, dict) and (result.get("Error") or result.get("Err")):
            return {"ok": False, "error": error_text(result)}
        # Confirm with a follow-up status().
        return {"ok": True, "dps": read_status(device)}
    except Exception as exc:
        return {"ok": False, "error": str(exc) or "set failed"}


def handle_rename(request):
    """Rename a device upstream, then mirror the confirmed name into the roster.

    General rule: cloud-identity fields (name included) are cloud-authoritative,
    so a rename must be applied UPSTREAM first; writing it locally alone would
    be stomped by the next cloudsync. The local roster is only updated after
    the cloud accepts the change.
    """
    device_id = request.get("id")
    name = request.get("name")
    if not isinstance(device_id, str) or not device_id:
        return {"ok": False, "error": "missing device id"}
    if not isinstance(name, str):
        return {"ok": False, "error": "missing name"}
    name = name.strip()
    if not name or len(name) > 50:
        return {"ok": False, "error": "name must be 1-50 characters"}
    if find_device(device_id) is None:
        return {"ok": False, "error": "unknown device id"}

    try:
        cloud = make_cloud()
        response = cloud.cloudrequest(
            "/v1.0/devices/%s" % device_id, "PUT", post={"name": name}
        )
    except Exception as exc:
        # Never include token/secret material in the reply.
        return _cloud_failure(exc)

    if not isinstance(response, dict) or not response.get("success") or not response.get("result"):
        return {"ok": False, "error": "cloud rename failed"}

    def merge(fresh):
        for config in fresh:
            if config.get("id") == device_id:
                config["name"] = name

    try:
        apply_to_disk(merge)
    except Exception as exc:
        return {"ok": False, "error": "devices write failed: " + type(exc).__name__}
    return {"ok": True, "name": name}


def handle_list():
    # General rule: the list reply is the app's view of the persisted roster.
    # Every field the UI consumes (including capability metadata) must
    # round-trip through it, not just identity/address fields.
    devices = []
    for config in _devices:
        devices.append({
            "id": config.get("id"),
            "name": config.get("name"),
            "ip": config.get("ip", ""),
            "version": config.get("version"),
            "category": config.get("category"),
            "group": config.get("group"),
            "online": bool(config.get("ip")),
            "spec": config.get("spec"),
            "codes": config.get("codes"),
        })
    return {"ok": True, "devices": devices}


def handle_rescan(request=None):
    """Scan the LAN and merge ip/version into devices.json, preserving keys."""
    window = (request or {}).get("window", 35)
    try:
        window = min(max(int(window), 15), 60)
    except (TypeError, ValueError):
        window = 35
    scan = tinytuya.deviceScan(poll=False, color=False, maxretry=window)
    if not isinstance(scan, dict):
        scan = {}

    # General rule: shared mutable state — never dump _devices; merge only the
    # scan delta into a fresh read via apply_to_disk.
    merged = 0

    def merge(fresh):
        nonlocal merged
        by_id = {config.get("id"): config for config in fresh}
        for device_id, found in scan.items():
            config = by_id.get(device_id)
            if config is None or not isinstance(found, dict):
                continue
            changed = False
            if found.get("ip") and config.get("ip") != found["ip"]:
                config["ip"] = found["ip"]
                changed = True
            if found.get("version") and config.get("version") != found["version"]:
                config["version"] = found["version"]
                changed = True
            if changed:
                merged += 1

    try:
        apply_to_disk(merge)
    except Exception as exc:
        return {"ok": False, "error": "devices write failed: " + type(exc).__name__}

    # Addresses may have moved, so drop cached sockets.
    _device_cache.clear()
    return {"ok": True, "merged": merged}


def briturn_normalize_mac(mac):
    """Hex-only lowercase form of a mac, the identity used for dedup/merge."""
    return re.sub(r"[^0-9a-f]", "", mac.lower())


def briturn_parse_reply(payload):
    """Parse one discovery reply into {id, mac, ip, version}, or None."""
    try:
        text = payload.decode("ascii").strip()
    except (UnicodeDecodeError, AttributeError):
        return None
    parts = text.split(",")
    if len(parts) < 3:
        return None
    ip = parts[0].strip()
    mac = briturn_normalize_mac(parts[1])
    module = parts[2].strip()
    if not BRITURN_IP.match(ip) or len(mac) != 12 or not module:
        return None
    return {
        "id": "briturn-" + mac,
        "mac": mac,
        "ip": ip,
        "version": module,
    }


def briturn_scan(timeout=4.0):
    """Broadcast the Zengge discovery probe and collect replies by identity."""
    discovered = {}

    def probe(sock):
        for address in BRITURN_BROADCASTS:
            try:
                sock.sendto(BRITURN_PROBE, (address, BRITURN_PORT))
            except OSError:
                continue

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(0.5)
        probe(sock)
        deadline = time.time() + timeout
        next_probe = time.time() + 1.0
        while time.time() < deadline:
            if time.time() >= next_probe:
                # Re-broadcast: a single datagram is easily lost on busy LANs.
                probe(sock)
                next_probe = time.time() + 1.0
            try:
                payload, _source = sock.recvfrom(1024)
            except socket.timeout:
                continue
            except OSError:
                break
            reply = briturn_parse_reply(payload)
            if reply is not None:
                # Replies may repeat or carry a stale ip; the last one wins.
                discovered[reply["id"]] = reply
    finally:
        sock.close()
    return discovered


def handle_briturnscan(request=None):
    """Discover Zengge/Briturn lights and upsert them into devices.json.

    General rule: discovery is an UPSERT keyed by the normalized mac, not a
    roster snapshot. Absent briturn entries are LEFT IN PLACE (a light that is
    powered off is not deleted), existing names are preserved (user renames
    survive), ip/version are refreshed when they moved, and entries whose
    category is not "briturn" are never touched even if the derived id
    collides. Non-briturn categories are outside this command's remit.
    """
    timeout = (request or {}).get("timeout", 4)
    try:
        timeout = min(max(float(timeout), 1), 15)
    except (TypeError, ValueError):
        timeout = 4.0
    try:
        found = briturn_scan(timeout)
    except Exception as exc:
        return {"ok": False, "error": "scan failed: " + type(exc).__name__}

    added = 0
    updated = 0

    def merge(fresh):
        nonlocal added, updated
        by_id = {config.get("id"): config for config in fresh}
        for found_id, device in found.items():
            config = by_id.get(found_id)
            if config is None:
                config = {
                    "id": found_id,
                    "name": "Briturn Light " + device["mac"][-4:],
                    "ip": device["ip"],
                    "version": device["version"],
                    "category": "briturn",
                }
                fresh.append(config)
                by_id[found_id] = config
                added += 1
                continue
            if config.get("category") != "briturn":
                continue
            changed = False
            if device["ip"] and config.get("ip") != device["ip"]:
                config["ip"] = device["ip"]
                changed = True
            if device["version"] and config.get("version") != device["version"]:
                config["version"] = device["version"]
                changed = True
            if not config.get("name"):
                config["name"] = "Briturn Light " + device["mac"][-4:]
                changed = True
            if changed:
                updated += 1

    try:
        apply_to_disk(merge)
    except Exception as exc:
        return {"ok": False, "error": "devices write failed: " + type(exc).__name__}

    _device_cache.clear()
    return {"ok": True, "found": len(found), "added": added, "updated": updated}


BRITURN_TCP_PORT = 5577
# Roster categories owned by bridge-local discovery, not the Tuya cloud.
SOURCE_OWNED_CATEGORIES = {"briturn"}

# Zengge "2014 protocol" wire format for the AK001-ZJ2xxx module family.
# Query state: 81 8a 8b -> 14-byte frame (may be preceded by an ack stream;
# anchor on the 81 5f preamble): [2]=power (0x23 on / 0x24 off), [3]=mode,
# [9]=warm white level ([5] is a fixed 0x50 on this firmware, NOT the level;
# verified live), [6..8]=r g b. Power: 71 23 (on) / 71 24 (off). Colour:
# 31 r g b w ignoreW aa where ignoreW 0xf0 = apply w, 0x0f = RGB only.
BRITURN_QUERY = bytes([0x81, 0x8A, 0x8B])
BRITURN_ON = bytes([0x71, 0x23])
BRITURN_OFF = bytes([0x71, 0x24])
BRITURN_POWER_ON = 0x23


def _briturn_exchange(ip, send, expect_reply=True, attempts=2, timeout=3.0):
    """One TCP 5577 exchange; returns reply bytes or None. Never raises."""
    for _attempt in range(attempts):
        sock = None
        try:
            sock = socket.create_connection((ip, BRITURN_TCP_PORT), timeout=timeout)
            sock.settimeout(timeout)
            sock.sendall(send)
            if not expect_reply:
                return b""
            return sock.recv(64)
        except OSError:
            continue
        finally:
            if sock is not None:
                try:
                    sock.close()
                except OSError:
                    pass
    return None


def _briturn_resolve(request):
    """Resolve a briturn roster entry, or an error dict tuple pair."""
    device_id = (request or {}).get("id")
    config = find_device(device_id)
    if config is None or config.get("category") != "briturn":
        return {"ok": False, "error": "unknown briturn device id"}
    if not config.get("ip"):
        return {"ok": False, "error": "device has no known ip"}
    return config


def handle_briturnstatus(request=None):
    """Query one Zengge light's state over TCP 5577.

    General rule: status is a query-and-parse of a single briturn device by
    roster id; a device that is offline or slow yields ok:false rather than
    raising, and only briturn-category entries are addressable. The raw power
    byte is reported alongside the parsed boolean so firmware variations stay
    diagnosable instead of silently mis-parsed.
    """
    resolved = _briturn_resolve(request)
    if isinstance(resolved, dict) and resolved.get("ok") is False:
        return resolved
    config = resolved
    reply = _briturn_exchange(config["ip"], BRITURN_QUERY)
    if not reply or len(reply) < 14:
        return {"ok": False, "error": "no or short reply from device"}
    # Frame sync: the bulb may prepend an ack/notification stream to the state
    # frame, so never trust fixed offsets — anchor on the 0x81 0x5f preamble.
    offset = reply.rfind(b"\x81\x5f")
    if offset < 0 or len(reply) - offset < 14:
        return {"ok": False, "error": "unrecognized state frame"}
    frame = reply[offset:]
    return {
        "ok": True,
        "on": frame[2] == BRITURN_POWER_ON,
        "raw_power": frame[2],
        "mode": frame[3],
        "w": frame[9],
        "r": frame[6],
        "g": frame[7],
        "b": frame[8],
    }


def _briturn_frame(reply):
    """Anchor a state frame on the 81 5f preamble; None if not present."""
    offset = reply.rfind(b"\x81\x5f")
    if offset < 0 or len(reply) - offset < 14:
        return None
    return reply[offset:]


def _briturn_read_rgb(config):
    """Read one device's current r/g/b, or None if unreachable/unparsable."""
    reply = _briturn_exchange(config["ip"], BRITURN_QUERY)
    if not reply:
        return None
    frame = _briturn_frame(reply)
    if frame is None:
        return None
    return frame[6], frame[7], frame[8]


def handle_briturnset(request=None):
    """Set power and/or colour on one Zengge light over TCP 5577.

    General rule: set sends the minimal packet set for exactly the requested
    fields (power packet, colour packet, or both); values are clamped so an
    out-of-range or wrongly-typed field cannot raise, and unknown/mismatched
    device ids are rejected with an error dict before any wire traffic. The
    reply carries {"packets": n, "status": <fresh briturnstatus readback>}
    so the caller can update UI state from the device, not the request.
    """
    resolved = _briturn_resolve(request)
    if isinstance(resolved, dict) and resolved.get("ok") is False:
        return resolved
    config = resolved
    request = request or {}

    want_power = "on" in request
    want_color = any(key in request for key in ("r", "g", "b"))
    want_brightness = "brightness" in request
    if not want_power and not want_color and not want_brightness:
        return {"ok": False, "error": "nothing to set: pass 'on', r/g/b and/or brightness"}

    def channel(key, default=0):
        try:
            return min(max(int(request.get(key, default)), 0), 255)
        except (TypeError, ValueError):
            return default

    # Brightness semantics: the 2014 protocol has no brightness command —
    # Magic Home scales the peak colour channel. brightness=50 makes the
    # strongest channel 50% (127), preserving hue. Explicit r/g/b wins as the
    # base; otherwise the device's current colour is the base.
    brightness = request.get("brightness")
    pct = None
    color_packet = None
    if want_color or brightness is not None:
        if brightness is not None:
            try:
                pct = min(max(float(brightness), 0), 100)
            except (TypeError, ValueError):
                return {"ok": False, "error": "brightness must be 0-100"}

        red, green, blue = channel("r"), channel("g"), channel("b")
        if not want_color:
            # brightness-only: base on the device's current colour
            base = _briturn_read_rgb(config)
            if base is None:
                return {"ok": False, "error": "device unreachable for brightness read"}
            red, green, blue = base
            if red == green == blue == 0 and pct is not None:
                # White mode: rgb channels read zero — brightness IS the warm
                # white level, so scale the warm byte (scaling zeros would be
                # a no-op and a stuck slider).
                warm_level = int(pct * 255.0 / 100.0 + 0.5)
                color_packet = bytes([0x31, 0, 0, 0, warm_level, 0xF0, 0xAA])
            elif pct is not None:
                peak = max(red, green, blue, 1)
                factor = (pct * 255.0 / 100.0) / peak
                red = min(int(red * factor + 0.5), 255)
                green = min(int(green * factor + 0.5), 255)
                blue = min(int(blue * factor + 0.5), 255)

        if color_packet is None:
            # A colour set means PURE colour — the bulb's warm-white channel
            # must be driven to 0, or whatever white level a previous set
            # left keeps blending in and the rendered colour looks nothing
            # like the picker. White only stays/applies when explicitly
            # requested via the "w" field. 0xF0 always APPLIES the white byte
            # (with warm=0 that actively zeroes the channel; the 0x0F variant
            # leaves the old white level blending in).
            warm = channel("w") if "w" in request else 0
            color_packet = bytes([0x31, red, green, blue, warm, 0xF0, 0xAA])

    sent = 0
    if want_power:
        packet = BRITURN_ON if bool(request.get("on")) else BRITURN_OFF
        if _briturn_exchange(config["ip"], packet, expect_reply=False) is None:
            return {"ok": False, "error": "power command failed"}
        sent += 1
    if color_packet is not None:
        if _briturn_exchange(config["ip"], color_packet, expect_reply=False) is None:
            return {"ok": False, "error": "color command failed"}
        sent += 1

    # Confirm with a follow-up status read (mirrors handle_set's readback
    # rule). The bulb acks asynchronously; reading too early returns the
    # prior state.
    time.sleep(0.8)
    status = handle_briturnstatus({"id": config.get("id")})
    return {"ok": True, "packets": sent, "status": status}


BRITURN_GROUP_MAX_LEN = 64


def handle_briturngroup(request):
    """Assign one briturn device to a named group; empty string clears it.

    General rule: groups are a ROSTER FIELD owned by the user, not a wire
    concept — the Zengge protocol has no group notion, so a group is just a
    label the bridge fans commands out to. Only briturn entries are
    addressable, names are trimmed and length-capped, and a missing/blank
    group clears membership rather than creating a ghost group.
    """
    resolved = _briturn_resolve(request)
    if isinstance(resolved, dict) and resolved.get("ok") is False:
        return resolved
    device_id = resolved["id"]
    group = (request or {}).get("group")
    if not isinstance(group, str):
        return {"ok": False, "error": "group must be a string (empty clears)"}
    group = group.strip()[:BRITURN_GROUP_MAX_LEN]

    def merge(fresh):
        for config in fresh:
            if config.get("id") == device_id:
                if group:
                    config["group"] = group
                else:
                    config.pop("group", None)
                return

    try:
        apply_to_disk(merge)
    except Exception as exc:
        return {"ok": False, "error": "devices write failed: " + type(exc).__name__}
    return {"ok": True, "id": device_id, "group": group or None}


def handle_briturnsetgroup(request):
    """Send power and/or colour to every briturn device in a group.

    General rule: group control fans the SAME packets out to every member
    concurrently (the bridge is otherwise serial, and a 20-light group must
    not take 20 round-trips); a member that is offline or fails is reported
    in the reply but never aborts the group, and an empty group is a no-op
    with an honest count rather than an error.
    """
    request = request or {}
    group = request.get("group")
    if not isinstance(group, str) or not group.strip():
        return {"ok": False, "error": "group name required"}
    group = group.strip()

    want_power = "on" in request
    want_color = any(key in request for key in ("r", "g", "b"))
    want_brightness = "brightness" in request
    if not want_power and not want_color and not want_brightness:
        return {"ok": False, "error": "nothing to set: pass 'on', r/g/b and/or brightness"}

    def channel(key, default=0):
        try:
            return min(max(int(request.get(key, default)), 0), 255)
        except (TypeError, ValueError):
            return default

    def base_color(config):
        """Explicit r/g/b wins; else the member's current colour (its own
        base — members may legitimately sit on different colours). None when
        the member is unreachable for the read."""
        if want_color:
            return channel("r"), channel("g"), channel("b")
        return _briturn_read_rgb(config)

    def packets_for(config):
        """Per-member packet list, or None when the member failed its read."""
        pk = []
        if want_power:
            pk.append(BRITURN_ON if bool(request.get("on")) else BRITURN_OFF)
        if want_color or want_brightness:
            rgb = base_color(config)
            if rgb is None:
                return None
            red, green, blue = rgb
            warm = channel("w")
            if want_brightness:
                raw_pct = request.get("brightness")
                try:
                    pct = min(max(float(request.get("brightness") or 0), 0), 100)
                except (TypeError, ValueError):
                    return None
                if red == green == blue == 0:
                    # White mode: rgb channels read zero — brightness IS the
                    # warm white level, so scale the warm byte. Scaling zeros
                    # would send level 0 and drive a lit white member dark.
                    warm_level = int(pct * 255.0 / 100.0 + 0.5)
                    pk.append(bytes([0x31, 0, 0, 0, warm_level, 0xF0, 0xAA]))
                    return pk
                peak = max(red, green, blue, 1)
                factor = (pct * 255.0 / 100.0) / peak
                red = min(int(red * factor + 0.5), 255)
                green = min(int(green * factor + 0.5), 255)
                blue = min(int(blue * factor + 0.5), 255)
            # Same pure-colour rule as the single set: a colour set drives the
            # white channel to 0 (0xF0 applies the white byte) unless the
            # request explicitly carries "w".
            warm = channel("w") if "w" in request else 0
            pk.append(bytes([0x31, red, green, blue, warm, 0xF0, 0xAA]))
        return pk

    members = [
        config for config in list(_devices)
        if config.get("category") == "briturn"
        and config.get("group") == group
        and config.get("ip")
    ]
    results = {}

    # Chunked concurrency: these are cheap embedded firmwares — a few dozen
    # simultaneous TCP handshakes can drop radios mid-handshake. Cap
    # parallelism and give every failed member ONE retry pass; a member that
    # fails both passes shows up in the reply instead of aborting the group.
    def attempt(chunk):
        threads = []

        def work(config):
            packets = packets_for(config)
            if packets is None:
                results[config["id"]] = False
                return
            ok = True
            for packet in packets:
                if _briturn_exchange(config["ip"], packet, expect_reply=False) is None:
                    ok = False
                    break
            results[config["id"]] = ok

        for config in chunk:
            thread = threading.Thread(target=work, args=(config,))
            threads.append(thread)
            thread.start()
        for thread in threads:
            thread.join(timeout=8)

    CHUNK = 6
    for i in range(0, len(members), CHUNK):
        attempt(members[i:i + CHUNK])
    failed = [config for config in members if not results.get(config["id"])]
    if failed:
        time.sleep(0.3)
        for i in range(0, len(failed), CHUNK):
            attempt(failed[i:i + CHUNK])

    applied = sum(1 for ok in results.values() if ok)
    return {
        "ok": True,
        "group": group,
        "members": len(members),
        "applied": applied,
        "results": results,
    }



# --- Briturn on-bulb schedules (2014 protocol timers) ---
# Each bulb holds 6 timer slots of 14 bytes. Read: 22 2a 2b 0f -> 88-byte
# reply, slots start at offset 2. Write: 21 + 6 slots + 00 f0 + checksum.
# Slot: [0]f0 active/0f not [1-3]y m d (one-shot only) [4]h [5]m [6]0
#       [7]repeat mask Mo=02..Su=80 [8]0x61 colour/0 default-on
#       [9-11]r g b [12]warm [13]f0 turn-on / 0f turn-off
BRITURN_TIMER_COUNT = 6
BRITURN_TIMER_LEN = 14
BRITURN_GET_TIMERS = bytes([0x22, 0x2A, 0x2B, 0x0F])
BRITURN_DAY_MASKS = {"mon": 0x02, "tue": 0x04, "wed": 0x08, "thu": 0x10,
                     "fri": 0x20, "sat": 0x40, "sun": 0x80}


def _briturn_checksum(cmd):
    return bytes([sum(cmd) & 0xFF])


def _briturn_set_time_packet():
    """Sync the bulb's internal clock (schedules fire on the bulb's own RTC)."""
    now = time.localtime()
    weekday = (now.tm_wday + 1) % 7 + 1  # 1=Mon .. 7=Sun per HF docs
    cmd = bytes([0x10, now.tm_year - 2000, now.tm_mon, now.tm_mday,
                 now.tm_hour, now.tm_min, now.tm_sec, weekday, 0x00, 0x0F])
    return cmd + _briturn_checksum(cmd)


def _briturn_timer_slot(entry):
    """Build one 14-byte slot from a schedule entry dict."""
    slot = bytearray(BRITURN_TIMER_LEN)
    slot[0] = 0x0F
    if not isinstance(entry, dict):
        return bytes(slot)
    clock = entry.get("time")
    if not isinstance(clock, str) or not re.match(r"^\d{2}:\d{2}$", clock):
        return bytes(slot)
    hour, minute = int(clock[:2]), int(clock[3:])
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        return bytes(slot)
    days = entry.get("days")
    mask = 0
    if isinstance(days, list) and days:
        for day in days:
            mask |= BRITURN_DAY_MASKS.get(str(day).lower(), 0)
        if mask == 0:
            return bytes(slot)  # explicit days that matched nothing: skip
    slot[0] = 0xF0
    slot[4], slot[5] = hour, minute
    slot[7] = mask  # 0 would mean one-shot; unsupported in v1 -> treated above
    action = str(entry.get("action", "on")).lower()
    if action == "off":
        slot[13] = 0x0F
        return bytes(slot)
    slot[13] = 0xF0
    r, g, b = entry.get("r"), entry.get("g"), entry.get("b")
    if isinstance(r, int) and isinstance(g, int) and isinstance(b, int):
        slot[8] = 0x61
        slot[9], slot[10], slot[11] = (min(max(r, 0), 255), min(max(g, 0), 255),
                                       min(max(b, 0), 255))
    else:
        slot[8] = 0x00  # default: turn on to the light's previous state
    return bytes(slot)


def handle_briturntimers(request=None):
    """Read the 6 on-bulb schedule slots of one briturn light.

    The timers reply is ~98 bytes and arrives in multiple TCP segments, so it
    is collected with repeated recvs (unlike the single-recv state read) and
    parsed from offset 2 (6 x 14-byte slots).
    """
    resolved = _briturn_resolve(request)
    if isinstance(resolved, dict) and resolved.get("ok") is False:
        return resolved
    config = resolved
    sock = None
    try:
        sock = socket.create_connection((config["ip"], BRITURN_TCP_PORT), timeout=3)
        sock.settimeout(1.2)
        sock.sendall(BRITURN_GET_TIMERS)
        buf = b""
        deadline = time.time() + 2.5
        while len(buf) < 2 + BRITURN_TIMER_COUNT * BRITURN_TIMER_LEN and time.time() < deadline:
            try:
                buf += sock.recv(160)
            except socket.timeout:
                pass
            except OSError:
                break
    except OSError:
        buf = b""
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
    expected = 2 + BRITURN_TIMER_COUNT * BRITURN_TIMER_LEN
    if len(buf) < expected:
        return {"ok": False, "error": "no or short timers reply"}
    slots = []
    start = 2
    for _ in range(BRITURN_TIMER_COUNT):
        s = buf[start:start + BRITURN_TIMER_LEN]
        start += BRITURN_TIMER_LEN
        active = s[0] == 0xF0
        days = [name for name, mask in BRITURN_DAY_MASKS.items() if s[7] & mask]
        if not active and s[4] == 0 and s[5] == 0:
            slots.append({"active": False, "time": None, "days": [], "action": None})
            continue
        entry = {
            "active": active,
            "time": "%02d:%02d" % (s[4], s[5]),
            "days": days,
            "action": "off" if s[13] == 0x0F else ("colour" if s[8] == 0x61 else "on"),
            "r": s[9], "g": s[10], "b": s[11],
        }
        slots.append(entry)
    return {"ok": True, "timers": slots}


def handle_briturntimerset(request):
    """Replace all 6 slots, then sync the bulb clock so they fire on time.

    General rule: schedule writes REPLACE the bulb's whole slot table (the
    protocol has no per-slot update), the caller sends the full desired list
    (max 6, padded inactive), the bulb clock is synced first because timers
    fire on the bulb's own RTC, and a timer whose action would neither turn
    on, off, nor colour is rejected rather than silently stored.
    """
    resolved = _briturn_resolve(request)
    if isinstance(resolved, dict) and resolved.get("ok") is False:
        return resolved
    config = resolved
    entries = (request or {}).get("timers")
    if not isinstance(entries, list) or len(entries) > BRITURN_TIMER_COUNT:
        return {"ok": False, "error": "timers must be a list of at most 6 entries"}
    slots = [_briturn_timer_slot(e) for e in entries]
    while len(slots) < BRITURN_TIMER_COUNT:
        slots.append(bytes(BRITURN_TIMER_LEN))

    if _briturn_exchange(config["ip"], _briturn_set_time_packet(), expect_reply=False) is None:
        return {"ok": False, "error": "time sync failed"}
    cmd = bytes([0x21]) + b"".join(slots) + bytes([0x00, 0xF0])
    if _briturn_exchange(config["ip"], cmd + _briturn_checksum(cmd), expect_reply=False) is None:
        return {"ok": False, "error": "timer write failed"}
    time.sleep(0.5)
    return handle_briturntimers({"id": config.get("id")})


def handle_briturntimersetgroup(request):
    """Write the same schedule to every member of a group (concurrent)."""
    request = request or {}
    group = request.get("group")
    if not isinstance(group, str) or not group.strip():
        return {"ok": False, "error": "group name required"}
    group = group.strip()
    timers = request.get("timers")
    if not isinstance(timers, list):
        return {"ok": False, "error": "timers list required"}
    members = [
        config for config in list(_devices)
        if config.get("category") == "briturn"
        and config.get("group") == group
        and config.get("ip")
    ]
    results = {}

    def send(config):
        results[config["id"]] = handle_briturntimerset(
            {"id": config["id"], "timers": timers})

    CHUNK = 6
    for i in range(0, len(members), CHUNK):
        threads = [threading.Thread(target=send, args=(config,))
                   for config in members[i:i + CHUNK]]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=60)

    applied = sum(1 for r in results.values() if r.get("ok"))
    return {"ok": True, "group": group, "members": len(members),
            "applied": applied, "results": results}


def handle_cloudsync():
    """Re-sync device identity from the Tuya cloud.

    General rule: the cloud roster is the authority for device IDENTITY AND
    CREDENTIALS. cloudsync merges every identity/credential field the cloud
    provides (CLOUD_IDENTITY_FIELDS) onto the local entry, preserving only
    local-only fields (ip, version, spec), and prunes entries the cloud no
    longer reports. Absence is confirmed with a missedSyncs counter so a
    transient/partial cloud response cannot delete a device. Credentials in
    tinytuya.json are never echoed.
    """
    try:
        cloud = make_cloud()
        result = cloud.getdevices(False)
    except Exception as exc:
        # Never include token/secret material in the reply.
        return _cloud_failure(exc)

    if not isinstance(result, list) or not result:
        return {"ok": False, "error": "cloud sync failed: empty or unexpected response"}

    # General rule: shared mutable state — apply only this command's
    # identity/roster delta to a fresh read; never dump the serving cache.
    renamed = 0
    added = 0
    pruned = 0
    seen = set()

    def merge(fresh):
        nonlocal renamed, added, pruned
        by_id = {config.get("id"): config for config in fresh}
        for cloud_device in result:
            if not isinstance(cloud_device, dict):
                continue
            device_id = cloud_device.get("id")
            if not device_id:
                continue
            seen.add(device_id)
            name = cloud_device.get("name")
            config = by_id.get(device_id)
            if config is None:
                config = {
                    "id": device_id,
                    "name": name or device_id,
                    "ip": "",
                    "version": None,
                    "category": cloud_device.get("category", ""),
                    "key": "",
                    "cloud": True,
                }
                fresh.append(config)
                by_id[device_id] = config
                added += 1

            config["cloud"] = True
            config["missedSyncs"] = 0
            for field in CLOUD_IDENTITY_FIELDS:
                value = cloud_device.get(field)
                if value is None or value == "":
                    continue
                if config.get(field) != value:
                    config[field] = value
                    if field == "name":
                        renamed += 1

        drop = set()
        for config in fresh:
            if config.get("id") in seen:
                continue
            # Source-owned categories (discovered by bridge commands, absent
            # from the Tuya cloud roster) are exempt from cloud pruning — the
            # cloud is only the authority for cloud-sourced identities.
            if config.get("category") in SOURCE_OWNED_CATEGORIES:
                continue
            config["cloud"] = False
            missed = config.get("missedSyncs", 0)
            try:
                missed = int(missed)
            except (TypeError, ValueError):
                missed = 0
            missed += 1
            config["missedSyncs"] = missed
            if missed >= pruneAfterMissedSyncs:
                drop.add(config.get("id"))
        if drop:
            fresh[:] = [config for config in fresh if config.get("id") not in drop]
            pruned = len(drop)

    try:
        merged_devices = apply_to_disk(merge)
    except Exception as exc:
        return {"ok": False, "error": "devices write failed: " + type(exc).__name__}

    # Do not block the serial stdio protocol on a 35s LAN scan.
    start_autoheal(cloud)

    return {
        "ok": True,
        "renamed": renamed,
        "added": added,
        "pruned": pruned,
        "total": len(merged_devices),
    }


def autoheal(cloud):
    """Wake and re-acquire cloud-known devices that have no LAN address.

    General rule: the roster self-heals — a device known to the cloud but
    absent from the LAN is not "broken", it is asleep. Send it a safe no-op
    command (same boolean dp, same value) to wake the radio, then run ONE
    broadcast scan and merge the discovered ip/version back into the roster.
    Devices that still do not answer keep missing syncs and prune per
    pruneAfterMissedSyncs; no special casing.
    """
    woke = 0
    found = 0
    try:
        roster = load_devices()
    except Exception:
        return {"woke": 0, "found": 0}

    candidates = [
        config for config in roster
        if not config.get("ip") and config.get("cloud", True) is not False
    ]
    for config in candidates:
        device_id = config.get("id")
        if not device_id:
            continue
        try:
            status = cloud.getstatus(device_id)
        except Exception:
            continue
        if not isinstance(status, dict) or status.get("Error") or status.get("Err"):
            continue
        points = status.get("status")
        if not isinstance(points, list):
            continue
        nudge = None
        for point in points:
            if not isinstance(point, dict):
                continue
            if isinstance(point.get("value"), bool) and point.get("code"):
                nudge = {"code": point["code"], "value": point["value"]}
                break
        if nudge is None:
            continue
        try:
            cloud.sendcommand(device_id, [nudge])
            woke += 1
        except Exception:
            continue

    if not candidates:
        return {"woke": 0, "found": 0}

    try:
        scan = tinytuya.deviceScan(
            poll=False, color=False, maxretry=autohealScanWindow, byID=True
        )
    except Exception:
        scan = {}
    if not isinstance(scan, dict):
        scan = {}

    def merge(fresh):
        nonlocal found
        by_id = {config.get("id"): config for config in fresh}
        for device_id, device in scan.items():
            config = by_id.get(device_id)
            if config is None or not isinstance(device, dict):
                continue
            changed = False
            if device.get("ip") and config.get("ip") != device["ip"]:
                config["ip"] = device["ip"]
                changed = True
            if device.get("version") and config.get("version") != device["version"]:
                config["version"] = device["version"]
                changed = True
            if changed:
                found += 1

    try:
        apply_to_disk(merge)
    except Exception:
        return {"woke": woke, "found": 0}
    if found:
        _device_cache.clear()
    return {"woke": woke, "found": found}


def start_autoheal(cloud):
    """Spawn at most one background autoheal run; never block the caller."""
    global _autoheal_running
    with _autoheal_lock:
        if _autoheal_running:
            return False
        _autoheal_running = True

    def run():
        global _autoheal_running
        try:
            autoheal(cloud)
        except Exception:
            pass
        finally:
            with _autoheal_lock:
                _autoheal_running = False

    threading.Thread(target=run, name="autoheal", daemon=True).start()
    return True


class CloudEnvError(RuntimeError):
    """The bridge interpreter cannot reach the Tuya cloud (missing deps)."""


def make_cloud():
    """Build a Cloud client from tinytuya.json. Secrets never leave this path."""
    if not CLOUD_CAPABLE:
        raise CloudEnvError(
            "bridge python is missing the 'requests' module — cloud "
            "functions unavailable; relaunch the app so it uses .venv"
        )
    with open(CREDENTIALS_PATH, "r", encoding="utf-8") as handle:
        credentials = json.load(handle)
    return tinytuya.Cloud(
        apiRegion=credentials.get("apiRegion"),
        apiKey=credentials.get("apiKey"),
        apiSecret=credentials.get("apiSecret"),
        apiDeviceID=credentials.get("apiDeviceID"),
    )


def load_credentials():
    """Read tinytuya.json, returning an empty dict when it is absent/invalid."""
    try:
        with open(CREDENTIALS_PATH, "r", encoding="utf-8") as handle:
            credentials = json.load(handle)
    except (OSError, ValueError):
        return {}
    return credentials if isinstance(credentials, dict) else {}


def mask_secret(secret):
    """Show enough to recognise a secret without ever returning it whole."""
    if not isinstance(secret, str) or not secret:
        return ""
    if len(secret) <= 8:
        return "…"
    return secret[:4] + "…" + secret[-3:]


def handle_config():
    """Report non-secret cloud settings plus a masked access secret.

    General rule: credentials never leave the bridge in clear text. Only the
    access ID (not a secret by itself) and a masked form of the secret are
    emitted so the Settings screen can show what is configured.
    """
    credentials = load_credentials()
    return {
        "ok": True,
        "config": {
            "apiKey": credentials.get("apiKey", ""),
            "apiSecretMasked": mask_secret(credentials.get("apiSecret")),
            "apiRegion": credentials.get("apiRegion", ""),
            "devicesPath": DEVICES_PATH,
            "pollNotes": (
                "Poll interval and scan window are app-side settings (Control tab). "
                "The bridge auto-heals with a %ds UDP scan window." % autohealScanWindow
            ),
        },
    }


def write_credentials(credentials):
    """Atomically replace tinytuya.json, preserving owner-only permissions."""
    directory = os.path.dirname(CREDENTIALS_PATH)
    descriptor, temp_path = tempfile.mkstemp(prefix=".tinytuya-", dir=directory)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(credentials, handle, indent=4)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, CREDENTIALS_PATH)
        os.chmod(CREDENTIALS_PATH, 0o600)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise


def handle_setconfig(request):
    """Validate NEW credentials against the real cloud, then persist them.

    General rule: never write a credential the cloud has not accepted — a bad
    secret would otherwise break cloudsync, status badges, and specs until a
    human repairs the file. The current file is left completely untouched on
    any failure.
    """
    credentials = load_credentials()

    for field in ("apiKey", "apiSecret", "apiRegion"):
        if field not in request:
            continue
        value = request.get(field)
        if not isinstance(value, str):
            return {"ok": False, "error": field + " must be a string"}
        value = value.strip()
        if field == "apiSecret" and not value:
            # Empty secret means "keep the stored one" so the UI can test an
            # unchanged secret without ever displaying it.
            continue
        if not value:
            return {"ok": False, "error": field + " required"}
        credentials[field] = value

    if not credentials.get("apiKey") or not credentials.get("apiSecret"):
        return {"ok": False, "error": "apiKey and apiSecret required"}
    if not credentials.get("apiRegion"):
        return {"ok": False, "error": "apiRegion required"}

    try:
        cloud = tinytuya.Cloud(
            apiRegion=credentials.get("apiRegion"),
            apiKey=credentials.get("apiKey"),
            apiSecret=credentials.get("apiSecret"),
            apiDeviceID=credentials.get("apiDeviceID"),
        )
    except TypeError:
        return {"ok": False, "error": "auth failed"}
    except Exception as exc:
        return {"ok": False, "error": "cloud test failed: " + type(exc).__name__}

    # A wrong key/secret never yields a token. Check this explicitly: the
    # device-list helper can degrade to an EMPTY list when the token call
    # failed, which would otherwise look like a healthy account.
    if not cloud.token:
        error = cloud.error if isinstance(cloud.error, dict) else {}
        if str(error.get("Err")) in ("909", "911"):
            return {"ok": False, "error": "auth failed"}
        return {"ok": False, "error": "cloud test failed: " + str(error.get("Err"))}

    try:
        result = cloud.getdevices(False)
    except Exception as exc:
        return {"ok": False, "error": "cloud test failed: " + type(exc).__name__}

    if isinstance(result, dict) and result.get("Error"):
        if str(result.get("Err")) in ("909", "911"):
            return {"ok": False, "error": "auth failed"}
        return {"ok": False, "error": "cloud test failed: " + str(result.get("Err"))}
    if not isinstance(result, list):
        return {"ok": False, "error": "cloud test failed"}

    try:
        write_credentials(credentials)
    except Exception as exc:
        return {"ok": False, "error": "credentials write failed: " + type(exc).__name__}
    return {"ok": True, "tested": True}


def fetch_spec(cloud, device_id):
    """Fetch one device's declared functions and status codes.

    General rule: code -> dp mappings come from the AUTHORITATIVE specification
    status section, never from runtime value correlation. The specifications
    endpoint declares both "functions" and "status"; every status entry carries
    a code and its dp_id, including status-only dps such as battery_percentage.

    Returns (spec, codes), where spec is normalised by dp id and codes maps
    each declared code to its dp id (as a string), or (None, None) on failure.
    """
    url = "/v1.1/devices/%s/specifications" % device_id
    response = cloud.cloudrequest(url, "GET")
    body = response.get("result", response) if isinstance(response, dict) else None
    functions = body.get("functions") if isinstance(body, dict) else None
    if not isinstance(functions, list):
        return None, None

    spec = {}
    for function in functions:
        if not isinstance(function, dict):
            continue
        dp_id = function.get("dp_id")
        if dp_id is None:
            continue
        values = function.get("values", "{}")
        if isinstance(values, str):
            try:
                values = json.loads(values)
            except ValueError:
                pass
        spec[str(dp_id)] = {
            "code": function.get("code", ""),
            "type": function.get("type", ""),
            "values": values,
        }

    codes = {}
    status = body.get("status") if isinstance(body, dict) else None
    if isinstance(status, list):
        for item in status:
            if not isinstance(item, dict):
                continue
            dp_id = item.get("dp_id")
            code = item.get("code")
            if dp_id is None or not isinstance(code, str) or not code:
                continue
            codes[code] = str(dp_id)
    return spec, codes


def handle_specs(request):
    """Fetch upstream capability metadata for one device or all (cached bulk).

    General rule: controls are derived from upstream capability metadata.
    Bulk calls skip devices that already carry a "spec"; a single-id call
    refreshes on demand.
    """
    device_id = request.get("id")
    if device_id is not None and not isinstance(device_id, str):
        return {"ok": False, "error": "bad device id"}

    if device_id is not None:
        targets = [config for config in _devices if config.get("id") == device_id]
        if not targets:
            return {"ok": False, "error": "unknown device id"}
    else:
        targets = list(_devices)

    try:
        cloud = make_cloud()
    except Exception as exc:
        return _cloud_failure(exc)

    updated = 0
    failures = 0
    fetched = {}
    for config in targets:
        if device_id is None and config.get("spec") and not request.get("refresh"):
            continue
        try:
            spec, codes = fetch_spec(cloud, config.get("id"))
        except Exception:
            failures += 1
            continue
        if spec:
            fetched[config.get("id")] = (spec, codes or {})
            updated += 1
        else:
            failures += 1

    if fetched:
        # General rule: shared mutable state — merge only the spec/codes delta by id
        # into a fresh read; never dump the serving cache.
        def merge(fresh):
            by_id = {config.get("id"): config for config in fresh}
            for target_id, (spec, codes) in fetched.items():
                target = by_id.get(target_id)
                if target is not None:
                    target["spec"] = spec
                    target["codes"] = codes

        try:
            apply_to_disk(merge)
        except Exception as exc:
            return {"ok": False, "error": "devices write failed: " + type(exc).__name__}

    if updated == 0 and failures > 0:
        return {"ok": False, "error": "spec fetch failed"}
    return {"ok": True, "updated": updated}


def handle_codemap(request):
    """Force-refresh the authoritative code -> dp map from the spec endpoint.

    General rule: code -> dp mappings come from the AUTHORITATIVE specification
    status section, never from runtime value correlation. This command is a
    thin force-refresh wrapper over the spec fetch, so repeated runs are
    idempotent.
    """
    refreshed = dict(request)
    refreshed["cmd"] = "specs"
    refreshed["refresh"] = True
    return handle_specs(refreshed)


def handle_cloudstatus(request):
    """Report each device's Tuya cloud connect status (bulk, or one id).

    General rule: LOCAL reachability (known ip, LAN status) and CLOUD
    connectivity are independent facts; the UI must show both so "asleep on
    LAN", "radio dead", and "other property" are distinguishable. Cloud status
    changes slowly, so this is only requested on the slow cloud-sync cycle.
    """
    device_id = request.get("id")
    if device_id is not None and not isinstance(device_id, str):
        return {"ok": False, "error": "bad device id"}

    if device_id is not None:
        targets = [config for config in _devices if config.get("id") == device_id]
        if not targets:
            return {"ok": False, "error": "unknown device id"}
    else:
        targets = list(_devices)

    try:
        cloud = make_cloud()
    except Exception as exc:
        error = "cloud request failed: " + type(exc).__name__
        if not CLOUD_CAPABLE:
            error = (
                "bridge python is missing the 'requests' module — cloud "
                "functions unavailable; relaunch the app so it uses .venv"
            )
        return {"ok": False, "error": error, "cloud_capable": CLOUD_CAPABLE}

    status = {}
    failures = 0
    for config in targets:
        try:
            online = cloud.getconnectstatus(config.get("id"))
        except Exception:
            failures += 1
            continue
        if isinstance(online, bool):
            status[config.get("id")] = online
        else:
            failures += 1

    if not status and failures > 0:
        return {"ok": False, "error": "cloud status failed"}
    return {"ok": True, "status": status}


OUR_SCHEDULE_CATEGORY = "myhomeapp"


def _power_code(config):
    """Power code from the device's Boolean dp-1 spec (fallback "switch")."""
    spec = config.get("spec")
    if isinstance(spec, dict):
        first = spec.get("1")
        if isinstance(first, dict) and str(first.get("type", "")).lower() == "boolean":
            if first.get("code"):
                return first["code"]
        for declaration in spec.values():
            if not isinstance(declaration, dict):
                continue
            if str(declaration.get("type", "")).lower() == "boolean" and declaration.get("code"):
                return declaration["code"]
    return "switch"


def _system_timezone():
    """Return (offset as +HH:MM, IANA id) for the host Mac."""
    seconds = int(time.localtime().tm_gmtoff)
    sign = "+" if seconds >= 0 else "-"
    hours, remainder = divmod(abs(seconds), 3600)
    offset = "%s%02d:%02d" % (sign, hours, remainder // 60)
    timezone_id = "UTC"
    try:
        path = os.path.realpath("/etc/localtime")
        marker = "zoneinfo/"
        if marker in path:
            timezone_id = path.split(marker, 1)[1]
    except Exception:
        pass
    return offset, timezone_id


# General rule: a schedule's action semantic follows the INSTRUCTION CODE's
# type in the device spec — Boolean codes render ON/OFF from the bool value;
# Enum control codes render the enum value as the action ("Open"/"Close"/
# "Continue"), where open/continue mean "runs/open" and close means "closed".
# Never coerce a string value to boolean. The raw value is carried through.
_BOOLEAN_TRUE = ("1", "true", "on")
_BOOLEAN_FALSE = ("0", "false", "off")
_ACTION_LABELS = {"open": "Open", "close": "Close", "continue": "Continue"}


def _schedule_action(raw, spec_entry=None):
    """Derive a display action from the raw instruction value.

    Value type is authoritative when the spec does not declare one: booleans
    (and 0/1) are ON/OFF, strings are enum labels. A spec Boolean code forces
    boolean semantics; a spec Enum code forces enum semantics.
    """
    declared = ""
    if isinstance(spec_entry, dict):
        declared = str(spec_entry.get("type") or "").lower()
    if isinstance(raw, bool):
        return "ON" if raw else "OFF"
    if declared == "boolean":
        return "ON" if str(raw).lower() in _BOOLEAN_TRUE else "OFF"
    if isinstance(raw, (int, float)):
        return "ON" if raw else "OFF"
    text = str(raw).strip()
    lowered = text.lower()
    if declared != "enum" and lowered in _BOOLEAN_TRUE:
        return "ON"
    if declared != "enum" and lowered in _BOOLEAN_FALSE:
        return "OFF"
    if not text:
        return ""
    return _ACTION_LABELS.get(lowered, text[:1].upper() + text[1:])


def _schedule_entry(category, group, timer=None, spec_by_code=None):
    """Flatten one category/group/timer defensively; never raises.

    Tuya returns both a nested shape (group.timers[]) and, historically, a
    group-level instruct[] shape; accept both rather than keying on one.
    """
    group = group if isinstance(group, dict) else {}
    timer = timer if isinstance(timer, dict) else {}
    instruct = group.get("instruct")
    first = instruct[0] if isinstance(instruct, list) and instruct else {}
    if not isinstance(first, dict):
        first = {}
    functions = timer.get("functions")
    if not isinstance(functions, list):
        functions = first.get("functions")
    function = functions[0] if isinstance(functions, list) and functions else {}
    if not isinstance(function, dict):
        function = {}
    status = timer.get("status", group.get("status", 0))
    try:
        status = int(status)
    except (TypeError, ValueError):
        status = 1 if status else 0
    category = category if isinstance(category, str) else ""
    code = str(function.get("code") or "")
    raw_value = function.get("value")
    spec_entry = spec_by_code.get(code) if isinstance(spec_by_code, dict) else None
    return {
        "group_id": str(group.get("group_id") or group.get("id") or ""),
        "category": category,
        "alias_name": str(timer.get("alias_name") or group.get("alias_name") or ""),
        "loops": str(timer.get("loops") or group.get("loops") or ""),
        "time": str(timer.get("time") or first.get("time") or group.get("time") or ""),
        "code": code,
        "value": raw_value,
        "action": _schedule_action(raw_value, spec_entry),
        "status": status,
        "ours": category == OUR_SCHEDULE_CATEGORY,
    }


def _flatten_schedules(result, spec_by_code=None):
    items = []
    if not isinstance(result, list):
        return items
    for entry in result:
        if not isinstance(entry, dict):
            continue
        raw_category = entry.get("category")
        if isinstance(raw_category, dict):
            category = raw_category.get("category") if isinstance(raw_category.get("category"), str) else ""
        elif isinstance(raw_category, str):
            category = raw_category
        else:
            category = ""
        groups = entry.get("groups")
        if isinstance(groups, list):
            for group in groups:
                if not isinstance(group, dict):
                    continue
                timers = group.get("timers")
                if isinstance(timers, list) and timers:
                    for timer in timers:
                        if isinstance(timer, dict):
                            items.append(_schedule_entry(category, group, timer, spec_by_code))
                else:
                    items.append(_schedule_entry(category, group, None, spec_by_code))
        elif entry.get("group_id") or entry.get("instruct") or entry.get("time"):
            items.append(_schedule_entry(category, entry, None, spec_by_code))
    return items


def _cloud_reply(cloud, url, action=None, post=None):
    """Call the cloud API and return (result, error string), never raising."""
    try:
        response = cloud.cloudrequest(url, action, post=post)
    except Exception as exc:
        return None, "cloud request failed: " + (
            str(exc) if isinstance(exc, CloudEnvError) else type(exc).__name__
        )
    if not isinstance(response, dict) or not response.get("success"):
        return None, "schedule request failed"
    return response.get("result"), None


def _cloud_failure(exc):
    """Uniform error dict for cloud-path failures the UI can show directly."""
    detail = str(exc) if isinstance(exc, CloudEnvError) else type(exc).__name__
    return {"ok": False, "error": "cloud request failed: " + detail,
            "cloud_capable": CLOUD_CAPABLE}


def handle_schedules(request):
    """List all timer groups for a device, flattened across categories."""
    device_id = request.get("id")
    if not isinstance(device_id, str) or find_device(device_id) is None:
        return {"ok": False, "error": "unknown device id"}
    try:
        cloud = make_cloud()
    except Exception as exc:
        return _cloud_failure(exc)
    result, error = _cloud_reply(cloud, "/v1.0/devices/%s/timers" % device_id)
    if error is not None:
        return {"ok": False, "error": error}
    device = find_device(device_id) or {}
    spec = device.get("spec")
    spec_by_code = {}
    if isinstance(spec, dict):
        for entry in spec.values():
            if isinstance(entry, dict) and isinstance(entry.get("code"), str):
                spec_by_code[entry["code"]] = entry
    return {"ok": True, "schedules": _flatten_schedules(result, spec_by_code)}


def handle_schedadd(request):
    """Create one timer group under the app-owned category."""
    device_id = request.get("id")
    config = find_device(device_id) if isinstance(device_id, str) else None
    if config is None:
        return {"ok": False, "error": "unknown device id"}
    days = request.get("days")
    if not isinstance(days, list) or len(days) != 7:
        return {"ok": False, "error": "days must be 7 entries (Mon..Sun)"}
    loops = "".join("1" if day else "0" for day in days)
    clock = request.get("time")
    if not isinstance(clock, str) or not re.match(r"^\d{2}:\d{2}$", clock):
        return {"ok": False, "error": "time must be HH:MM"}
    hour, minute = int(clock[:2]), int(clock[3:])
    if hour > 23 or minute > 59:
        return {"ok": False, "error": "time must be HH:MM"}
    name = request.get("name") or ""
    if not isinstance(name, str):
        return {"ok": False, "error": "bad name"}
    name = name.strip()[:50]
    state = bool(request.get("on"))
    offset, timezone_id = _system_timezone()
    body = {
        "category": OUR_SCHEDULE_CATEGORY,
        "loops": loops,
        "time_zone": offset,
        "timezone_id": timezone_id,
        "instruct": [{
            "time": clock,
            "functions": [{"code": _power_code(config), "value": state}],
        }],
        "alias_name": name,
    }
    try:
        cloud = make_cloud()
    except Exception as exc:
        return _cloud_failure(exc)
    result, error = _cloud_reply(cloud, "/v1.0/devices/%s/timers" % device_id, "POST", body)
    if error is not None:
        return {"ok": False, "error": error}
    group_id = result.get("group_id") if isinstance(result, dict) else result
    return {"ok": True, "group_id": str(group_id or "")}


def _schedule_target(request):
    device_id = request.get("id")
    category = request.get("category")
    group_id = request.get("group_id")
    if not isinstance(device_id, str) or find_device(device_id) is None:
        return None, {"ok": False, "error": "unknown device id"}
    if not isinstance(category, str) or not category:
        return None, {"ok": False, "error": "missing category"}
    if group_id is None or isinstance(group_id, (dict, list)):
        return None, {"ok": False, "error": "missing group id"}
    return (device_id, category, str(group_id)), None


def handle_scheddel(request):
    target, error_reply = _schedule_target(request)
    if target is None or error_reply is not None:
        return error_reply or {"ok": False, "error": "bad schedule target"}
    device_id, category, group_id = target
    try:
        cloud = make_cloud()
    except Exception as exc:
        return _cloud_failure(exc)
    url = "/v1.0/devices/%s/timers/categories/%s/groups/%s" % (device_id, category, group_id)
    _, error = _cloud_reply(cloud, url, "DELETE")
    if error is not None:
        return {"ok": False, "error": error}
    return {"ok": True}


def _find_timer_group(result, group_id):
    """Find a timer group by id across the categories in a timers reply.

    The full timers list is a list of category entries; a category-scoped
    read returns a single dict with the same entry shape.
    """
    if isinstance(result, dict):
        entries = [result]
    elif isinstance(result, list):
        entries = result
    else:
        return None, None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        raw_category = entry.get("category")
        if isinstance(raw_category, dict):
            category = raw_category.get("category")
        else:
            category = raw_category
        groups = entry.get("groups")
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            if str(group.get("id") or group.get("group_id") or "") == group_id:
                return group, category if isinstance(category, str) else None
    return None, None


def _timer_group_instincts(group, status):
    """Rebuild group-update instruct[] from current timers, applying status."""
    timers = group.get("timers")
    instruct = []
    if isinstance(timers, list) and timers:
        for timer in timers:
            if not isinstance(timer, dict):
                continue
            instruct.append({
                "time": str(timer.get("time") or ""),
                "functions": [
                    {"code": fn.get("code"), "value": fn.get("value")}
                    for fn in timer.get("functions") or []
                    if isinstance(fn, dict)
                ],
                "status": status,
            })
    if not instruct:
        raw = group.get("instruct")
        if isinstance(raw, list):
            for item in raw:
                if not isinstance(item, dict):
                    continue
                instruct.append({
                    "time": str(item.get("time") or ""),
                    "functions": [
                        {"code": fn.get("code"), "value": fn.get("value")}
                        for fn in item.get("functions") or []
                        if isinstance(fn, dict)
                    ],
                    "status": status,
                })
    return instruct


def _timer_group_status(group):
    """Return the observed status values for every timer in a group."""
    observed = []
    timers = group.get("timers") if isinstance(group, dict) else None
    if isinstance(timers, list):
        for timer in timers:
            if isinstance(timer, dict):
                try:
                    observed.append(int(timer.get("status", -1)))
                except (TypeError, ValueError):
                    observed.append(-1)
    if not observed:
        try:
            observed = [int(group.get("status", -1))]
        except (TypeError, ValueError):
            observed = [-1]
    return observed


def _timer_group_timer(group, index=0):
    """Return a timer dict (nested or instruct-shaped) from a group."""
    timers = group.get("timers") if isinstance(group, dict) else None
    if isinstance(timers, list) and len(timers) > index and isinstance(timers[index], dict):
        return timers[index]
    instruct = group.get("instruct") if isinstance(group, dict) else None
    if isinstance(instruct, list) and len(instruct) > index and isinstance(instruct[index], dict):
        return instruct[index]
    return {}


def _schema_by_code(config):
    spec = config.get("spec") if isinstance(config, dict) else None
    by_code = {}
    if isinstance(spec, dict):
        for entry in spec.values():
            if isinstance(entry, dict) and isinstance(entry.get("code"), str):
                by_code[entry["code"]] = entry
    return by_code


def _schedule_value_for(spec_entry, on):
    """Map an ON/OFF edit to the instruction value for a code's type."""
    declared = ""
    if isinstance(spec_entry, dict):
        declared = str(spec_entry.get("type") or "").lower()
    if declared == "boolean":
        return bool(on)
    if declared == "enum":
        return "open" if on else "close"
    return bool(on)


def _schedule_value_matches(raw, expected):
    if isinstance(expected, bool):
        if isinstance(raw, bool):
            return raw == expected
        if isinstance(raw, (int, float)):
            return bool(raw) == expected
        if isinstance(raw, str):
            return (raw.strip().lower() in _BOOLEAN_TRUE) == expected
        return False
    if isinstance(raw, str) and isinstance(expected, str):
        return raw.strip().lower() == expected.strip().lower()
    return raw == expected


def handle_schededit(request):
    """Edit one timer group's content without changing its enabled state."""
    target, error_reply = _schedule_target(request)
    if target is None or error_reply is not None:
        return error_reply or {"ok": False, "error": "bad schedule target"}
    device_id, category, group_id = target
    config = find_device(device_id) or {}
    name = request.get("name")
    if name is not None and not isinstance(name, str):
        return {"ok": False, "error": "bad name"}
    days = request.get("days")
    if days is not None:
        if not isinstance(days, list) or len(days) != 7:
            return {"ok": False, "error": "days must be 7 entries (Mon..Sun)"}
        loops = "".join("1" if day else "0" for day in days)
    else:
        loops = None
    clock = request.get("time")
    if clock is not None:
        if not isinstance(clock, str) or not re.match(r"^\d{2}:\d{2}$", clock):
            return {"ok": False, "error": "time must be HH:MM"}
        hour, minute = int(clock[:2]), int(clock[3:])
        if hour > 23 or minute > 59:
            return {"ok": False, "error": "time must be HH:MM"}
    on = request.get("on")
    if on is not None and not isinstance(on, bool):
        return {"ok": False, "error": "on must be true or false"}
    if name is None and loops is None and clock is None and on is None:
        return {"ok": False, "error": "nothing to edit"}
    try:
        cloud = make_cloud()
    except Exception as exc:
        return _cloud_failure(exc)
    read_url = "/v1.0/devices/%s/timers/categories/%s" % (device_id, category)
    result, error = _cloud_reply(cloud, read_url)
    if error is not None:
        return {"ok": False, "error": error}
    group, _ = _find_timer_group(result, group_id)
    if group is None:
        result, error = _cloud_reply(cloud, "/v1.0/devices/%s/timers" % device_id)
        if error is not None:
            return {"ok": False, "error": error}
        group, _ = _find_timer_group(result, group_id)
    if group is None:
        return {"ok": False, "error": "schedule not found"}

    spec_by_code = _schema_by_code(config)
    timers = group.get("timers")
    source = timers if isinstance(timers, list) and timers else None
    if source is None:
        source = [group]
    instruct = []
    expected = {"time": clock, "loops": loops, "name": name, "value": None}
    first_function = None
    for index, timer in enumerate(source):
        if not isinstance(timer, dict):
            continue
        functions = timer.get("functions")
        if not isinstance(functions, list):
            functions = []
        rebuilt = []
        for fn_index, fn in enumerate(functions):
            if not isinstance(fn, dict):
                continue
            code = fn.get("code")
            value = fn.get("value")
            if index == 0 and fn_index == 0 and on is not None:
                value = _schedule_value_for(spec_by_code.get(str(code or "")), on)
            rebuilt.append({"code": code, "value": value})
        if index == 0 and rebuilt:
            first_function = rebuilt[0]
        instruct.append({
            "time": clock if clock is not None else str(timer.get("time") or group.get("time") or ""),
            "functions": rebuilt,
            "status": timer.get("status", group.get("status", 0)),
        })
    if not instruct:
        return {"ok": False, "error": "schedule has no instructions"}
    if on is not None and first_function is not None:
        expected["value"] = first_function.get("value")
    current_alias = name
    if current_alias is None:
        current_alias = _timer_group_timer(group).get("alias_name", group.get("alias_name", ""))
    offset, timezone_id = _system_timezone()
    body = {
        "category": category,
        "loops": loops if loops is not None else str(group.get("loops") or "1111111"),
        "time_zone": offset,
        "timezone_id": timezone_id,
        "instruct": instruct,
    }
    if isinstance(current_alias, str):
        body["alias_name"] = current_alias
    update_url = "/v1.0/devices/%s/timers/groups/%s" % (device_id, group_id)
    _, error = _cloud_reply(cloud, update_url, "PUT", body)
    if error is not None:
        return {"ok": False, "error": error}

    readback, error = _cloud_reply(cloud, read_url)
    if error is not None:
        return {"ok": False, "error": error}
    current, _ = _find_timer_group(readback, group_id)
    if current is None:
        return {"ok": False, "error": "edit did not take effect"}
    timer = _timer_group_timer(current)
    if not timer:
        return {"ok": False, "error": "edit did not take effect"}
    # The group-update PUT can reset a disabled timer to enabled; editing must
    # not change the enabled state, so restore it explicitly when that happens.
    first_timer = source[0] if isinstance(source[0], dict) else {}
    try:
        original_status = int(first_timer.get("status", group.get("status", 0)))
    except (TypeError, ValueError):
        original_status = 1 if first_timer.get("status", group.get("status", 0)) else 0
    if _timer_group_status(current) != [original_status]:
        legacy_url = "/v1.0/devices/%s/timers/categories/%s/groups/%s/status" % (
            device_id, category, group_id
        )
        _, error = _cloud_reply(cloud, legacy_url, "PUT", {"status": original_status})
        if error is not None:
            return {"ok": False, "error": error}
        readback, error = _cloud_reply(cloud, read_url)
        if error is not None:
            return {"ok": False, "error": error}
        current, _ = _find_timer_group(readback, group_id)
        if current is None:
            return {"ok": False, "error": "edit did not take effect"}
        timer = _timer_group_timer(current)
        if not timer or _timer_group_status(current) != [original_status]:
            return {"ok": False, "error": "edit did not take effect"}
    if clock is not None and str(timer.get("time") or current.get("time") or "") != clock:
        return {"ok": False, "error": "edit did not take effect"}
    if loops is not None and str(timer.get("loops") or current.get("loops") or "") != loops:
        return {"ok": False, "error": "edit did not take effect"}
    if name is not None and str(timer.get("alias_name", current.get("alias_name", ""))) != name:
        return {"ok": False, "error": "edit did not take effect"}
    if on is not None:
        observed_functions = timer.get("functions")
        if not isinstance(observed_functions, list) or not observed_functions:
            return {"ok": False, "error": "edit did not take effect"}
        observed = observed_functions[0].get("value") if isinstance(observed_functions[0], dict) else None
        if not _schedule_value_matches(observed, expected["value"]):
            return {"ok": False, "error": "edit did not take effect"}
    return {"ok": True}


def handle_schedtoggle(request):
    target, error_reply = _schedule_target(request)
    if target is None or error_reply is not None:
        return error_reply or {"ok": False, "error": "bad schedule target"}
    device_id, category, group_id = target
    enable = request.get("enable")
    if not isinstance(enable, bool):
        return {"ok": False, "error": "enable must be true or false"}
    try:
        cloud = make_cloud()
    except Exception as exc:
        return _cloud_failure(exc)
    read_url = "/v1.0/devices/%s/timers/categories/%s" % (device_id, category)
    result, error = _cloud_reply(cloud, read_url)
    if error is not None:
        return {"ok": False, "error": error}
    group, _ = _find_timer_group(result, group_id)
    if group is None:
        # Category-scoped read may omit entries; fall back to the full list.
        result, error = _cloud_reply(cloud, "/v1.0/devices/%s/timers" % device_id)
        if error is not None:
            return {"ok": False, "error": error}
        group, _ = _find_timer_group(result, group_id)
    if group is None:
        return {"ok": False, "error": "schedule not found"}
    status = 1 if enable else 0
    offset, timezone_id = _system_timezone()
    body = {
        "category": category,
        "loops": str(group.get("loops") or "1111111"),
        "time_zone": offset,
        "timezone_id": timezone_id,
        "instruct": _timer_group_instincts(group, status),
    }
    alias_name = group.get("alias_name")
    if isinstance(alias_name, str):
        body["alias_name"] = alias_name
    update_url = "/v1.0/devices/%s/timers/groups/%s" % (device_id, group_id)
    _, error = _cloud_reply(cloud, update_url, "PUT", body)
    if error is not None:
        return {"ok": False, "error": error}
    readback, error = _cloud_reply(cloud, read_url)
    if error is not None:
        return {"ok": False, "error": error}
    current, _ = _find_timer_group(readback, group_id)
    if current is not None and _timer_group_status(current) == [status]:
        return {"ok": True}
    # Some firmware silently ignores status:0 on the group-update path; the
    # category status endpoint does disable. Try it, then verify again.
    legacy_url = "/v1.0/devices/%s/timers/categories/%s/groups/%s/status" % (
        device_id, category, group_id
    )
    _, error = _cloud_reply(cloud, legacy_url, "PUT", {"status": status})
    if error is not None:
        return {"ok": False, "error": error}
    readback, error = _cloud_reply(cloud, read_url)
    if error is not None:
        return {"ok": False, "error": error}
    current, _ = _find_timer_group(readback, group_id)
    if current is None or _timer_group_status(current) != [status]:
        return {"ok": False, "error": "toggle did not take effect"}
    return {"ok": True}


def gh_respond(operation, *args):
    """Run a google_home operation and map failures to the bridge error dict.

    General rule: bridge handlers never raise and never emit secret values.
    Any Google Home failure (missing consent, HTTP/MCP error, malformed input)
    becomes {"ok": False, "error": <redacted text>}; an auth failure also
    carries the consent instructions.
    """
    if google_home is None:
        return {"ok": False, "error": "google_home module unavailable"}
    try:
        return operation(*args)
    except google_home.AuthRequired as exc:
        return {
            "ok": False,
            "error": google_home.safe_error(exc),
            "consentRequired": True,
            "hint": "run: python3 google_home.py auth",
        }
    except google_home.GoogleHomeError as exc:
        return {"ok": False, "error": google_home.safe_error(exc)}
    except Exception as exc:
        return {"ok": False, "error": google_home.safe_error(exc)}


def handle_gh_list():
    return gh_respond(google_home.list_overview)


def handle_gh_states(request):
    device_id = request.get("id")
    if device_id is not None and (not isinstance(device_id, str) or not device_id.strip()):
        return {"ok": False, "error": "invalid device id"}
    return gh_respond(google_home.states, device_id)


def handle_gh_action(request):
    device_id = request.get("id")
    if not isinstance(device_id, str) or not device_id.strip():
        return {"ok": False, "error": "missing device id"}
    action = request.get("action")
    if not isinstance(action, (str, dict)) or not action:
        return {"ok": False, "error": "missing action"}
    home_id = request.get("home_id")
    if home_id is not None and not isinstance(home_id, str):
        return {"ok": False, "error": "invalid home id"}
    return gh_respond(google_home.action, device_id, action, home_id)


def dispatch(request):
    cmd = request.get("cmd")
    if cmd == "ping":
        return {"ok": True}
    if cmd == "list":
        return handle_list()
    if cmd == "status":
        device_id = request.get("id")
        if not isinstance(device_id, str):
            return {"ok": False, "error": "missing device id"}
        return handle_status(device_id)
    if cmd == "set":
        device_id = request.get("id")
        if not isinstance(device_id, str):
            return {"ok": False, "error": "missing device id"}
        return handle_set(device_id, request.get("dps"))
    if cmd == "rename":
        return handle_rename(request)
    if cmd == "rescan":
        return handle_rescan(request)
    if cmd == "briturnscan":
        return handle_briturnscan(request)
    if cmd == "briturnstatus":
        return handle_briturnstatus(request)
    if cmd == "briturnset":
        return handle_briturnset(request)
    if cmd == "briturngroup":
        return handle_briturngroup(request)
    if cmd == "briturnsetgroup":
        return handle_briturnsetgroup(request)
    if cmd == "briturntimers":
        return handle_briturntimers(request)
    if cmd == "briturntimerset":
        return handle_briturntimerset(request)
    if cmd == "briturntimersetgroup":
        return handle_briturntimersetgroup(request)
    if cmd == "cloudsync":
        return handle_cloudsync()
    if cmd == "cloudstatus":
        return handle_cloudstatus(request)
    if cmd == "schedules":
        return handle_schedules(request)
    if cmd == "schedadd":
        return handle_schedadd(request)
    if cmd == "scheddel":
        return handle_scheddel(request)
    if cmd == "schededit":
        return handle_schededit(request)
    if cmd == "schedtoggle":
        return handle_schedtoggle(request)
    if cmd == "codemap":
        return handle_codemap(request)
    if cmd == "specs":
        return handle_specs(request)
    if cmd == "config":
        return handle_config()
    if cmd == "setconfig":
        return handle_setconfig(request)
    if cmd == "gh_list":
        return handle_gh_list()
    if cmd == "gh_states":
        return handle_gh_states(request)
    if cmd == "gh_action":
        return handle_gh_action(request)
    return {"ok": False, "error": "unknown command"}


_RESPOND_LOCK = threading.Lock()
# Cap concurrent workers: these are cheap embedded firmwares and serial-port
# style readers, but a batch of requests must not fork unbounded threads.
_WORKER_SEM = threading.Semaphore(8)


def respond(payload):
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    with _RESPOND_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def _run_request(request, request_id):
    """Dispatch one id-stamped request on a worker thread.

    Concurrent requests interleave safely: stdout writes are locked and every
    reply carries its reqId so the client can match out-of-order answers.
    """
    try:
        with _WORKER_SEM:
            reply = dispatch(request)
    except Exception as exc:
        reply = {"ok": False, "error": str(exc) or "request failed"}
    if not isinstance(reply, dict):
        reply = {"ok": False, "error": "request failed"}
    reply["reqId"] = request_id
    respond(reply)


def main():
    global _devices
    try:
        _devices = load_devices()
    except Exception:
        _devices = []

    for line in sys.stdin:
        try:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except ValueError:
                respond({"ok": False, "error": "bad request"})
                continue
            if not isinstance(request, dict):
                respond({"ok": False, "error": "bad request"})
                continue
            request_id = request.get("reqId")
            if isinstance(request_id, int) and not isinstance(request_id, bool):
                # Id-stamped requests run concurrently; un-stamped ones keep
                # the legacy synchronous path.
                threading.Thread(
                    target=_run_request,
                    args=(request, request_id),
                    daemon=True,
                ).start()
                continue
            try:
                respond(dispatch(request))
            except Exception as exc:
                respond({"ok": False, "error": str(exc) or "request failed"})
        except Exception:
            respond({"ok": False, "error": "bad request"})


if __name__ == "__main__":
    main()
