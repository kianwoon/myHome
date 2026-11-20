"""Background Tuya port probe: find a device's new LAN IP without ARP.

General rule: a Tuya device listens on TCP 6668. When a device stops
answering at its stored address (tinytuya 901/905) and the ARP table is not
readable (macOS hides it from some process trees), the bridge asks this
module to look for the device on the local subnet instead:

  1. connect-only scan of the Tuya port over the subnet (no bytes are sent);
  2. try each open host with a fresh status() call using the device's own
     id/key; the host that answers with a dps dict is the device.

The scan runs in one background thread, at most once per cooldown, and never
blocks a request. A device the probe failed to find is left alone for a long
backoff so flaky firmware is not hammered. A device qualifies for a probe
when the cloud says it is online (so the local address is the problem) or
after several consecutive connect failures.

This module never imports bridge; the bridge passes identify/persist in.
Logs carry counts, device ids and IPs only, never keys.

Tunables come from the environment (MYHOME_TUYAPROBE_*), see CONFIG.
"""
import concurrent.futures
import logging
import os
import socket
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
    # TCP port Tuya devices listen on for local control.
    "port": _env_number("MYHOME_TUYAPROBE_PORT", 6668, int),
    # Seconds a connect-only attempt may take.
    "connect_timeout": _env_number("MYHOME_TUYAPROBE_CONNECT_TIMEOUT", 0.3),
    # Parallel connect attempts during the scan.
    "concurrency": _env_number("MYHOME_TUYAPROBE_CONCURRENCY", 32, int),
    # Seconds one identification (status call) may take.
    "identify_timeout": _env_number("MYHOME_TUYAPROBE_IDENTIFY_TIMEOUT", 2.0),
    # Minimum seconds between two probes in one bridge process.
    "cooldown": _env_number("MYHOME_TUYAPROBE_COOLDOWN", 300.0),
    # Seconds a device the probe failed to find is not probed again.
    "device_backoff": _env_number("MYHOME_TUYAPROBE_DEVICE_BACKOFF", 1800.0),
    # A subnet with more usable hosts than this is never scanned.
    "max_hosts": _env_number("MYHOME_TUYAPROBE_MAX_HOSTS", 1024, int),
    # Most open hosts tried for identification, per device.
    "max_candidates": _env_number("MYHOME_TUYAPROBE_MAX_CANDIDATES", 64, int),
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


def _tcp_connect(ip, port, timeout):
    """True when a TCP connection opens; closed at once, nothing is sent."""
    try:
        sock = socket.create_connection((ip, port), timeout=timeout)
    except OSError:
        return False
    sock.close()
    return True


def open_hosts(network, own_address=None, connector=None):
    """Sorted IPs on `network` with the Tuya port open.

    `connector(ip, port, timeout)` returns True for an open port. A missing
    network or one with more than max_hosts usable hosts is refused ([]).
    """
    if network is None or network.num_addresses - 2 > CONFIG["max_hosts"]:
        return []
    connector = connector or _tcp_connect
    hosts = [str(host) for host in network.hosts() if str(host) != own_address]
    if not hosts:
        return []
    port, timeout = CONFIG["port"], CONFIG["connect_timeout"]
    workers = max(1, min(CONFIG["concurrency"], len(hosts)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda ip: bool(connector(ip, port, timeout)), hosts))
    return sorted((ip for ip, is_open in zip(hosts, results) if is_open),
                  key=lambda ip: tuple(int(part) for part in ip.split(".")))


def locate(pending, hosts, identify, skip_ips=()):
    """Match pending device configs to hosts; returns {device_id: ip}.

    Hosts outside skip_ips (other roster devices' addresses) are tried first.
    A host matched to one device is never tried for another, and a device's
    own stored address is not retried (it just failed).
    """
    skip = set(skip_ips)
    ordered = [ip for ip in hosts if ip not in skip] + [ip for ip in hosts if ip in skip]
    taken = set()
    found = {}
    for config in pending:
        device_id = config.get("id")
        candidates = [ip for ip in ordered
                      if ip not in taken and ip != config.get("ip")]
        for ip in candidates[:CONFIG["max_candidates"]]:
            try:
                matched = identify(ip, config)
            except Exception as exc:  # one bad host must not stop the probe
                log.warning("tuya probe identify failed: %s", type(exc).__name__)
                matched = False
            if matched:
                found[device_id] = ip
                taken.add(ip)
                break
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


def drain(target_ip, identify, persist, roster_ips=(), network=None,
          connector=None, now=None):
    """Probe for every pending device; returns {device_id: ip} persisted.

    Runs synchronously (the background thread calls it). Matched devices go
    through persist(id, ip); the rest enter device_backoff.
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
    hosts = open_hosts(network, own_address=own, connector=connector)
    found = locate(pending, hosts, identify, skip_ips=roster_ips)
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
    log.info("tuya probe: %d open hosts, %d of %d devices found",
             len(hosts), len(persisted), len(pending))
    return persisted


def _worker(target_ip, identify, persist, roster_ips):
    try:
        drain(target_ip, identify, persist, roster_ips)
    except Exception as exc:  # a probe must never break the bridge
        log.warning("tuya probe failed: %s", type(exc).__name__)
    finally:
        with _lock:
            _state["running"] = False


def start(target_ip, identify, persist, roster_ips=(), now=None):
    """Spawn one background probe when devices are pending and none ran lately."""
    now = time.monotonic() if now is None else now
    with _lock:
        last = _state["last"]
        if (not target_ip or not _state["pending"] or _state["running"]
                or (last is not None and now - last < CONFIG["cooldown"])):
            return False
        _state["running"] = True
        _state["last"] = now
    threading.Thread(target=_worker, args=(target_ip, identify, persist, tuple(roster_ips)),
                     name="tuya-probe", daemon=True).start()
    return True
