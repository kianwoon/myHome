"""Local-exchange health: stop hammering a device whose local server is wedged.

General rule: a failed local handshake is not free. Some Tuya v3.4 firmware
accepts the TCP connection and then closes it at session negotiation, which
tinytuya reports as Err 914 ("Check device key or version") even though key,
address and version are right. Measured on a ceiling fan: every such failed
handshake stalls the device's cloud state reporting for about 47 s, so the
cloud-status fallback reads stale state, while a cloud command sent with no
prior local attempt reports back in 0.7 s. Retrying local on every poll keeps
the device wedged.

So a device that fails with one of the trigger codes is routed cloud-first
for a backoff window. When the window expires the next call is allowed one
local attempt; a repeat failure re-arms the window with a doubled backoff
(capped), and a local success clears the device. A device with no cloud
configured is unaffected because the caller falls back to local when the
cloud path misses.

This module never imports bridge. Logs carry device ids and codes only,
never keys.

Tunables come from the environment (MYHOME_LOCALSKIP_*), see CONFIG.
"""
import logging
import os
import threading
import time

log = logging.getLogger("myhome.local_health")


def _env_number(name, default, cast=float):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return cast(raw)
    except (TypeError, ValueError):
        return default


def _env_codes(name, default):
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        raw = default
    return frozenset(part.strip() for part in raw.split(",") if part.strip())


CONFIG = {
    # Master switch; 0 means local is always tried first (old behaviour).
    "enabled": _env_number("MYHOME_LOCALSKIP_ENABLED", 1, int) == 1,
    # tinytuya Err codes that mean "local server wedged" (914 = session
    # negotiation closed by the device).
    "codes": _env_codes("MYHOME_LOCALSKIP_CODES", "914"),
    # Seconds to skip local after the first trigger failure; doubles per
    # consecutive trigger failure.
    "backoff": _env_number("MYHOME_LOCALSKIP_BACKOFF", 300.0),
    # Upper bound for the doubled backoff, seconds.
    "max_backoff": _env_number("MYHOME_LOCALSKIP_MAX_BACKOFF", 3600.0),
}

_lock = threading.Lock()
# device_id -> {"failures": consecutive trigger failures, "until": monotonic}
_state = {}
# Patchable in tests.
_clock = time.monotonic


def reset():
    """Forget every device's failure history (tests)."""
    with _lock:
        _state.clear()


def _window(failures):
    """Backoff seconds after `failures` consecutive trigger failures."""
    seconds = CONFIG["backoff"] * (2 ** (failures - 1))
    return min(seconds, CONFIG["max_backoff"])


def note_failure(device_id, code):
    """Record a failed local exchange; only trigger codes arm the skip."""
    if not CONFIG["enabled"] or code is None:
        return
    if str(code) not in CONFIG["codes"]:
        return
    with _lock:
        entry = _state.setdefault(device_id, {"failures": 0, "until": 0.0})
        entry["failures"] += 1
        seconds = _window(entry["failures"])
        entry["until"] = _clock() + seconds
        failures = entry["failures"]
    log.info("local exchange %s failed with %s (x%d): cloud-first for %.0fs",
             device_id, code, failures, seconds)


def note_success(device_id):
    """A local exchange worked: forget the device's failures."""
    with _lock:
        cleared = _state.pop(device_id, None)
    if cleared is not None:
        log.info("local exchange %s recovered: skip cleared", device_id)


def should_skip(device_id):
    """True while the device is inside its backoff window.

    Once the window expires this returns False, so the caller makes one local
    attempt; the failure count is kept so a repeat failure doubles the window.
    """
    if not CONFIG["enabled"]:
        return False
    with _lock:
        entry = _state.get(device_id)
        return entry is not None and _clock() < entry["until"]
