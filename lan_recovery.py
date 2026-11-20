"""MAC-based LAN address recovery for devices whose DHCP lease moved.

General rule: a Tuya device's MAC is stable, its IP is not. When a local
connect fails (tinytuya 901/905) and the roster knows the device's MAC, the
kernel ARP table is asked where that MAC lives now. The lookup itself sends
nothing. Only when the table has no entry for the MAC does a bounded, paced
sweep run in the background to refresh it, and at most once per cooldown.

The sweep sends one empty UDP datagram per host to a closed port (the
"discard" port by default). That is enough for the kernel to ARP the host and
never touches the Tuya TCP/UDP ports, so flaky firmware sees nothing new.

This module never imports bridge; the bridge passes everything in. Every
function takes an optional `runner` / `sender` so tests feed canned output.

Tunables come from the environment (MYHOME_LANRECOVERY_*), see CONFIG.
"""
import ipaddress
import logging
import os
import re
import socket
import subprocess
import threading
import time

log = logging.getLogger("myhome.lan_recovery")


def _env_number(name, default, cast=float):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return cast(raw)
    except (TypeError, ValueError):
        return default


def _env_list(name, default):
    raw = os.environ.get(name)
    if not raw:
        return default
    return tuple(part.strip() for part in raw.split(",") if part.strip())


CONFIG = {
    # tinytuya error codes that mean "could not reach the address at all".
    "connect_errors": _env_list("MYHOME_LANRECOVERY_ERRORS", ("901", "905")),
    # Commands used to read the ARP table and the interface addresses.
    "arp_command": _env_list("MYHOME_LANRECOVERY_ARP_CMD", ("arp", "-an")),
    "ifconfig_command": _env_list("MYHOME_LANRECOVERY_IFCONFIG_CMD", ("ifconfig",)),
    # Seconds a helper command may run before it is abandoned.
    "command_timeout": _env_number("MYHOME_LANRECOVERY_CMD_TIMEOUT", 5.0),
    # A local retry after recovery only runs when the failed attempt took no
    # longer than this, so status/set stay inside the app's request timeouts.
    "retry_budget": _env_number("MYHOME_LANRECOVERY_RETRY_BUDGET", 3.0),
    # Minimum seconds between two sweeps in one bridge process.
    "sweep_cooldown": _env_number("MYHOME_LANRECOVERY_SWEEP_COOLDOWN", 300.0),
    # A subnet with more usable hosts than this is never swept.
    "sweep_max_hosts": _env_number("MYHOME_LANRECOVERY_SWEEP_MAX_HOSTS", 1024, int),
    # Pause between two probe datagrams, and the wait for ARP replies after.
    "sweep_interval": _env_number("MYHOME_LANRECOVERY_SWEEP_INTERVAL", 0.004),
    "sweep_settle": _env_number("MYHOME_LANRECOVERY_SWEEP_SETTLE", 2.0),
    # Closed UDP port the probe datagrams are addressed to.
    "sweep_port": _env_number("MYHOME_LANRECOVERY_SWEEP_PORT", 9, int),
}

_ARP_LINE = re.compile(
    r"\((\d{1,3}(?:\.\d{1,3}){3})\)\s+at\s+([0-9A-Fa-f]{1,2}(?:[:-][0-9A-Fa-f]{1,2}){5})\b")
_INET_HEX = re.compile(r"inet\s+(\d{1,3}(?:\.\d{1,3}){3})\s+netmask\s+0x([0-9A-Fa-f]{8})")
_INET_DOTTED = re.compile(
    r"inet\s+(?:addr:)?(\d{1,3}(?:\.\d{1,3}){3})\s+(?:netmask\s+|Mask:)(\d{1,3}(?:\.\d{1,3}){3})")
_INET_CIDR = re.compile(r"inet\s+(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})")

_sweep_lock = threading.Lock()
_sweep_state = {"running": False, "last": None}


def is_connect_failure(code):
    """True when a tinytuya Err code means the address did not answer."""
    return code is not None and str(code) in CONFIG["connect_errors"]


def normalize_mac(mac):
    """Return a MAC as lowercase aa:bb:cc:dd:ee:ff, or None.

    macOS prints ARP entries without leading zeros ("0:1a:..."), the cloud
    sends them with; both sides go through here before comparing.
    """
    if not isinstance(mac, str):
        return None
    text = mac.strip().lower()
    if re.fullmatch(r"[0-9a-f]{12}", text):
        parts = [text[i:i + 2] for i in range(0, 12, 2)]
    else:
        parts = re.split(r"[:\-.]", text)
        if len(parts) == 3 and all(len(part) == 4 for part in parts):
            parts = [part[i:i + 2] for part in parts for i in (0, 2)]
    if len(parts) != 6:
        return None
    try:
        octets = [int(part, 16) for part in parts]
    except ValueError:
        return None
    if any(octet > 0xFF for octet in octets) or any(not part for part in parts):
        return None
    return ":".join("%02x" % octet for octet in octets)


def _run(command, runner=None):
    if runner is not None:
        return runner(list(command))
    try:
        completed = subprocess.run(
            list(command), capture_output=True, text=True,
            timeout=CONFIG["command_timeout"], check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return completed.stdout or ""


def parse_arp(text):
    """Return [(ip, mac)] from `arp -an` output; incomplete rows are dropped."""
    entries = []
    for line in (text or "").splitlines():
        match = _ARP_LINE.search(line)
        if not match:
            continue
        mac = normalize_mac(match.group(2))
        if mac:
            entries.append((match.group(1), mac))
    return entries


def read_arp(runner=None):
    """The current ARP table as [(ip, mac)]; empty when it cannot be read."""
    return parse_arp(_run(CONFIG["arp_command"], runner))


def arp_available(entries):
    """False when the table read came back empty.

    A LAN host always has at least its gateway in the table, so zero entries
    means the table is unreadable (no command, or the OS hides neighbour
    entries from this process tree), not that the MAC is absent. Sweeping
    cannot fix that, so callers change nothing and do not sweep.
    """
    if entries:
        return True
    log.warning("lan recovery: arp table unreadable (0 entries); skipping")
    return False


def addresses_for(mac, entries):
    """Every IP the ARP entries list for this MAC (deduplicated, ordered)."""
    wanted = normalize_mac(mac)
    if not wanted:
        return []
    seen = []
    for ip, entry_mac in entries:
        if entry_mac == wanted and ip not in seen:
            seen.append(ip)
    return seen


def resolve(mac, current_ip, entries):
    """Decide what the ARP table says about a device.

    Returns (new_ip, needs_sweep):
      - (ip, False)   the MAC lives at exactly one other address: moved.
      - (None, False) the MAC is still at current_ip (the address is right,
                      the device is just not answering), or the table is
                      ambiguous: change nothing.
      - (None, True)  the table does not know the MAC: a sweep may help.
    """
    found = addresses_for(mac, entries)
    if not found:
        return None, True
    if current_ip in found:
        return None, False
    if len(found) == 1:
        return found[0], False
    return None, False


def recover_after(config, code, started, persist, entries=None, now=None):
    """Re-locate a device by MAC after its address stopped answering.

    `config` is the roster entry, `code` the tinytuya Err of the failure and
    `started` the monotonic time the failed attempt began. `persist(id, ip)`
    writes the move and returns the live roster entry. Returns that entry
    when a local retry should run, otherwise None (keep the original error).

    General rule: only an unreachable address (901/905) triggers this. The
    ARP lookup sends nothing; a MAC the table does not know schedules one
    background sweep so the NEXT request can find it. A move is persisted
    even when the inline retry is skipped for exceeding retry_budget.
    """
    mac = config.get("mac")
    device_id = config.get("id")
    if not is_connect_failure(code) or not mac or not device_id:
        return None
    old_ip = config.get("ip")
    if entries is None:
        entries = read_arp()
    if not arp_available(entries):
        return None
    new_ip, needs_sweep = resolve(mac, old_ip, entries)
    if new_ip is None:
        if needs_sweep:
            start_sweep(old_ip)
        return None
    try:
        moved = persist(device_id, new_ip)
    except Exception as exc:  # a failed write keeps the original error
        log.warning("ip recovery write failed: %s", type(exc).__name__)
        return None
    log.info("device %s moved %s -> %s (found by mac)", device_id, old_ip, new_ip)
    now = time.monotonic() if now is None else now
    if not moved or moved.get("ip") != new_ip or now - started > CONFIG["retry_budget"]:
        return None
    return moved


def refresh_roster(roster, skip_ids, entries=None):
    """Point roster entries at their ARP-table address; return how many moved.

    For use inside a devices.json mutator after a broadcast scan: devices the
    scan already placed (skip_ids) and devices without a MAC are left alone.
    A device with no address yet takes its single ARP address.
    """
    if entries is None:
        entries = read_arp()
    moved = 0
    for config in roster:
        mac = config.get("mac")
        if config.get("id") in skip_ids or not mac:
            continue
        current = config.get("ip")
        new_ip, _ = resolve(mac, current, entries)
        found = addresses_for(mac, entries)
        if new_ip is None and not current and len(found) == 1:
            new_ip = found[0]
        if new_ip:
            config["ip"] = new_ip
            moved += 1
    return moved


def scan_entries(roster, skip_ids, runner=None):
    """ARP entries for a post-scan refresh, sweeping first when it would help.

    Call OUTSIDE any devices.json lock (a sweep takes seconds). A sweep runs
    in this thread only when a device the scan missed has a MAC the table
    does not know, and only once per cooldown.
    """
    entries = read_arp(runner)
    if not arp_available(entries):
        return entries
    missing = [config for config in roster
               if config.get("id") not in skip_ids and config.get("mac")
               and not addresses_for(config["mac"], entries)]
    target = next((config.get("ip") for config in roster if config.get("ip")), None)
    if missing and target and sweep_due() and sweep_now(target, runner):
        entries = read_arp(runner)
    return entries


def source_address(target_ip):
    """Local address the kernel would use to reach target_ip (sends nothing)."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((target_ip, CONFIG["sweep_port"]))
        return probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()


def parse_network(ifconfig_text, address):
    """The IPv4 network of the interface holding `address`, or None."""
    for line in (ifconfig_text or "").splitlines():
        match = _INET_HEX.search(line)
        if match and match.group(1) == address:
            mask = str(ipaddress.IPv4Address(int(match.group(2), 16)))
            return ipaddress.IPv4Network(address + "/" + mask, strict=False)
        match = _INET_DOTTED.search(line)
        if match and match.group(1) == address:
            return ipaddress.IPv4Network(address + "/" + match.group(2), strict=False)
        match = _INET_CIDR.search(line)
        if match and match.group(1) == address:
            return ipaddress.IPv4Network(address + "/" + match.group(2), strict=False)
    return None


def local_network(target_ip, runner=None, source=None):
    """The subnet of the interface that routes to target_ip, or None."""
    if not target_ip:
        return None
    address = source if source is not None else source_address(target_ip)
    if not address:
        return None
    return parse_network(_run(CONFIG["ifconfig_command"], runner), address)


def sweep(network, own_address=None, sender=None, sleep=time.sleep):
    """Send one empty UDP datagram to each host of `network`.

    Returns the number of hosts probed, or 0 when the network is missing or
    larger than sweep_max_hosts. Send errors (host down, no buffer) are
    expected for empty addresses and are ignored.
    """
    if network is None or network.num_addresses - 2 > CONFIG["sweep_max_hosts"]:
        return 0
    sock = None
    if sender is None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

        def sender(host):
            sock.sendto(b"", (host, CONFIG["sweep_port"]))
    probed = 0
    try:
        for host in network.hosts():
            host = str(host)
            if host == own_address:
                continue
            try:
                sender(host)
            except OSError:
                pass
            probed += 1
            sleep(CONFIG["sweep_interval"])
    finally:
        if sock is not None:
            sock.close()
    sleep(CONFIG["sweep_settle"])
    return probed


def sweep_due(now=None):
    """True when no sweep is running and the cooldown has passed."""
    now = time.monotonic() if now is None else now
    with _sweep_lock:
        last = _sweep_state["last"]
        return not _sweep_state["running"] and (
            last is None or now - last >= CONFIG["sweep_cooldown"])


def _claim_sweep():
    now = time.monotonic()
    with _sweep_lock:
        last = _sweep_state["last"]
        if _sweep_state["running"] or (
                last is not None and now - last < CONFIG["sweep_cooldown"]):
            return False
        _sweep_state["running"] = True
        _sweep_state["last"] = now
        return True


def _release_sweep():
    with _sweep_lock:
        _sweep_state["running"] = False


def sweep_now(target_ip, runner=None):
    """Run one cooldown-guarded sweep of target_ip's subnet in this thread."""
    if not _claim_sweep():
        return 0
    try:
        address = source_address(target_ip) if target_ip else None
        network = local_network(target_ip, runner=runner, source=address)
        probed = sweep(network, own_address=address)
        log.info("lan recovery sweep probed %d hosts", probed)
        return probed
    except Exception as exc:  # a sweep must never break the bridge
        log.warning("lan recovery sweep failed: %s", type(exc).__name__)
        return 0
    finally:
        _release_sweep()


def start_sweep(target_ip):
    """Spawn sweep_now in the background unless one ran recently."""
    if not target_ip or not sweep_due():
        return False
    threading.Thread(target=sweep_now, args=(target_ip,),
                     name="lan-recovery-sweep", daemon=True).start()
    return True
