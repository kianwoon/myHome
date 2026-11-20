"""Background Tuya port probe: find a device's new LAN IP without ARP.

General rule: a Tuya device listens on TCP 6668. When a device stops
answering at its stored address (tinytuya 901/905) and the ARP table is not
readable (macOS hides it from some process trees), the bridge asks this
module to look for the device on the local subnet instead: every candidate
host gets a fresh status() call using the device's own id/key, and the host
that answers with a dps dict is the device.

Hard rules:
  * No bare connects. Nothing here opens a TCP connection to the Tuya port
    without immediately doing the tinytuya handshake. A connect-and-close
    wedges a Tuya v3.4 device's local server for 2+ minutes (measured: a
    status() answered in 0.33 s when quiet, then returned 914 for 80+ s right
    after one connect-close), so a connect-only scan made the target
    unidentifiable and knocked every other device off local control.
  * Roster IPs are never touched. Every other roster device's address, the
    device's own stored address and this host's address are excluded from the
    candidates. Hosts with no listener fail fast (refused) or after
    connect_timeout; that is the scan.

Identification runs in parallel with early exit: once a host matches, the
remaining candidates are skipped. It runs in one background thread, at most
once per cooldown, and never blocks a request. A device the probe failed to
find is left alone for a long backoff so flaky firmware is not hammered. A
device qualifies for a probe when the cloud says it is online (so the local
address is the problem) or after several consecutive connect failures.

This module never imports bridge; the bridge passes identify/persist in.
Logs carry counts, device ids and IPs only, never keys.

Tunables come from the environment (MYHOME_TUYAPROBE_*), see CONFIG.
"""
import concurrent.futures
import logging
import os
import threading
import time

import lan_recovery

log = logging.getLogger("myhome.tuya_probe")


def _env_number(name, default, cast=float):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return cast(raw)
    except (TypeError, ValueError):
        return default


CONFIG = {
    # Seconds the tinytuya connect of one identification may take. WiFi
    # devices in power-save answer slowly (a fan measured 0.6 s average, 1.4 s
    # peak ping RTT), so this must cover a sleepy radio, not a wired host.
    "connect_timeout": _env_number("MYHOME_TUYAPROBE_CONNECT_TIMEOUT", 1.5),
    # Parallel identification attempts.
    "concurrency": _env_number("MYHOME_TUYAPROBE_CONCURRENCY", 64, int),
    # Seconds one identification (status call) may take.
    "identify_timeout": _env_number("MYHOME_TUYAPROBE_IDENTIFY_TIMEOUT", 5.0),
    # Minimum seconds between two probes in one bridge process.
    "cooldown": _env_number("MYHOME_TUYAPROBE_COOLDOWN", 300.0),
    # Seconds a device the probe failed to find is not probed again.
    "device_backoff": _env_number("MYHOME_TUYAPROBE_DEVICE_BACKOFF", 1800.0),
    # A subnet with more usable hosts than this is never probed (a /22 fits).
    "max_hosts": _env_number("MYHOME_TUYAPROBE_MAX_HOSTS", 1024, int),
    # Consecutive connect failures before a device qualifies without a cloud
    # signal that it is online.
    "failure_threshold": _env_number("MYHOME_TUYAPROBE_FAILURE_THRESHOLD", 3, int),
}

_lock = threading.Lock()
_state = {"failures": {}, "pending": {}, "backoff": {}, "running": False, "last": None}


def reset():
    """Forget all counters, pending devices, backoffs and cooldown (tests)."""
    with _lock:
        _state.update(failures={}, pending={}, backoff={}, running=False, last=None)


def candidates(network, own_address=None, exclude_ips=()):
    """Hosts of `network` that may be probed, in address order.

    Excludes own_address and every exclude_ips entry (the device's stored
    address and every other roster device). A missing network or one with
    more than max_hosts usable hosts is refused ([]).
    """
    if network is None or network.num_addresses - 2 > CONFIG["max_hosts"]:
        return []
    skip = set(exclude_ips)
    skip.add(own_address)
    return [str(host) for host in network.hosts() if str(host) not in skip]


def _locate_one(config, hosts, identify):
    """First host that identify() accepts for this device, or None.

    Every host is queued, but each attempt checks the stop flag first, so
    after a match the rest return at once without touching the network.
    """
    stop = threading.Event()
    lock = threading.Lock()
    result = []

    def attempt(ip):
        if stop.is_set():
            return
        try:
            matched = identify(ip, config)
        except Exception as exc:  # one bad host must not stop the probe
            log.warning("tuya probe identify failed: %s", type(exc).__name__)
            return
        if matched:
            with lock:
                if not stop.is_set():
                    result.append(ip)
                    stop.set()

    workers = max(1, min(CONFIG["concurrency"], len(hosts)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        for ip in hosts:
            pool.submit(attempt, ip)
    return result[0] if result else None


def locate(pending, hosts, identify):
    """Match pending device configs to hosts; returns {device_id: ip}.

    Hosts are tried in parallel and the search for a device stops at the first
    match. A host matched to one device is never tried for another, and a
    device's own stored address is not retried (it just failed).
    """
    taken = set()
    found = {}
    for config in pending:
        pool = [ip for ip in hosts if ip not in taken and ip != config.get("ip")]
        if not pool:
            continue
        ip = _locate_one(config, pool, identify)
        if ip is not None:
            found[config.get("id")] = ip
            taken.add(ip)
    return found


def note_failure(config):
    """Count one more consecutive connect failure for this device."""
    with _lock:
        device_id = config.get("id")
        _state["failures"][device_id] = _state["failures"].get(device_id, 0) + 1


def note_success(device_id):
    """A local exchange worked: forget failures and any pending probe."""
    with _lock:
        _state["failures"].pop(device_id, None)
        _state["pending"].pop(device_id, None)


def request(config, cloud_online=False, now=None):
    """Queue a device for the next probe when it qualifies; True if queued."""
    now = time.monotonic() if now is None else now
    device_id = config.get("id")
    with _lock:
        if not device_id or _state["backoff"].get(device_id, 0) > now:
            return False
        if not (cloud_online or _state["failures"].get(device_id, 0) >= CONFIG["failure_threshold"]):
            return False
        _state["pending"][device_id] = config
        return True


def drain(target_ip, identify, persist, exclude_ips=(), network=None, now=None):
    """Probe for every pending device; returns {device_id: ip} persisted.

    Runs synchronously (the background thread calls it). Matched devices go
    through persist(id, ip); the rest enter device_backoff. exclude_ips are
    the other roster devices' addresses and are never probed.
    """
    with _lock:
        pending = list(_state["pending"].values())
        _state["pending"].clear()
    if not pending:
        return {}
    own = None
    if network is None:
        own = lan_recovery.source_address(target_ip) if target_ip else None
        network = lan_recovery.local_network(target_ip, source=own)
    hosts = candidates(network, own_address=own,
                       exclude_ips=set(exclude_ips) | {target_ip})
    found = locate(pending, hosts, identify)
    persisted = {}
    for device_id, ip in found.items():
        try:
            persist(device_id, ip)
        except Exception as exc:  # a failed write leaves the device unmoved
            log.warning("tuya probe write failed: %s", type(exc).__name__)
            continue
        persisted[device_id] = ip
        log.info("device %s found at %s by port probe", device_id, ip)
        note_success(device_id)
    until = (time.monotonic() if now is None else now) + CONFIG["device_backoff"]
    with _lock:
        for config in pending:
            if config.get("id") not in persisted:
                _state["backoff"][config.get("id")] = until
    log.info("tuya probe: %d candidate hosts, %d of %d devices found",
             len(hosts), len(persisted), len(pending))
    return persisted


def _worker(target_ip, identify, persist, exclude_ips):
    try:
        drain(target_ip, identify, persist, exclude_ips)
    except Exception as exc:  # a probe must never break the bridge
        log.warning("tuya probe failed: %s", type(exc).__name__)
    finally:
        with _lock:
            _state["running"] = False


def start(target_ip, identify, persist, exclude_ips=(), now=None):
    """Spawn one background probe when devices are pending and none ran lately."""
    now = time.monotonic() if now is None else now
    with _lock:
        last = _state["last"]
        if (not target_ip or not _state["pending"] or _state["running"]
                or (last is not None and now - last < CONFIG["cooldown"])):
            return False
        _state["running"] = True
        _state["last"] = now
    threading.Thread(target=_worker, args=(target_ip, identify, persist, tuple(exclude_ips)),
                     name="tuya-probe", daemon=True).start()
    return True
