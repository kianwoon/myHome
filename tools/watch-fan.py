#!/usr/bin/env python3
"""Watchdog for Tuya devices whose v3.4 session key gets corrupted in firmware.

Some v3.4 devices stop answering local session-key negotiation after long
uptime ("Check device key or version" / error 914) while staying fully
controllable via the Tuya cloud.  This watchdog:

  1. probes the device over the LAN,
  2. on failure, verifies/controls it via the cloud API so control is not lost,
  3. optionally power-cycles it through a smart plug/switch to self-heal
     (a power cycle is the known cure for the corrupted module state).

Requires devices.json (device + key) and tinytuya.json (cloud credentials),
both produced by `python -m tinytuya wizard`.

Usage:
    python tools/watch-fan.py --name "Master fan" --once       # single check
    python tools/watch-fan.py --name "Master fan"              # loop, 120s
    python tools/watch-fan.py --name "Master fan" --plug "Fan plug" --cycle
                                                               # self-heal
"""

# baseline-guard:allow new standalone tool; no prior version ever existed

import argparse
import json
import logging
import sys
import time

import tinytuya

log = logging.getLogger("watch-fan")

# how long we keep trusting the cloud fallback before retrying local control
CLOUD_FALLBACK_RETRY_LOCAL = 3600


def load_device(name):
    """Return the devices.json entry for the given device name."""
    with open("devices.json") as f:
        devs = json.load(f)
    if isinstance(devs, dict):
        devs = devs.get("devices", [])
    for dev in devs:
        if dev.get("name") == name:
            return dev
    log.error("device %r not found in devices.json", name)
    sys.exit(1)


def probe_local(dev):
    """Probe over LAN. Returns the status dict (dicts with 'Error' = failure)."""
    d = tinytuya.Device(
        dev["id"], address=dev.get("ip"), version=dev.get("version", "3.4"),
        persist=False,
    )
    d.set_socketTimeout(5)
    return d.status()


def cloud_client():
    with open("tinytuya.json") as f:
        cfg = json.load(f)
    return tinytuya.Cloud(
        apiRegion=cfg.get("apiRegion"), apiKey=cfg.get("apiKey"),
        apiSecret=cfg.get("apiSecret"),
    )


def cloud_status(cloud, dev_id):
    """Status via cloud. Returns a dict of dps or None on failure."""
    result = cloud.getstatus(dev_id)
    if isinstance(result, dict) and result.get("success"):
        return result.get("result", {})
    log.warning("cloud status failed: %r", result)
    return None


def power_cycle(cloud, plug, off_secs=15):
    """Cut and restore power through a smart plug/switch in devices.json."""
    pdev = load_device(plug)
    log.warning("power-cycling %r via cloud in %ds", plug, off_secs)
    cloud.sendcommand(pdev["id"], {"commands": [{"code": "switch_1", "value": False}]})
    time.sleep(off_secs)
    cloud.sendcommand(pdev["id"], {"commands": [{"code": "switch_1", "value": True}]})
    log.info("power restored to %r", plug)


def check_once(dev, cloud, plug, do_cycle):
    """One probe cycle. Returns True when the device is controllable."""
    name = dev.get("name", dev["id"])
    status = probe_local(dev)
    if "Error" not in status:
        log.info("%s: local OK (%d dps)", name, len(status))
        return True

    # local path failed — confirm the device is alive via cloud
    cstat = cloud_status(cloud, dev["id"])
    if cstat is None:
        log.error("%s: local failed (%s) AND cloud unreachable", name,
                  status.get("Err", "?"))
        return False

    log.warning("%s: local control failed (%s %s); cloud fallback OK (%d dps)",
                name, status.get("Err"), status.get("Error"), len(cstat))

    if do_cycle and plug:
        try:
            power_cycle(cloud, plug)
        except Exception as e:  # noqa: BLE001 - keep the watchdog alive
            log.error("power cycle failed: %s", e)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", required=True, help="device name in devices.json")
    ap.add_argument("--plug", help="smart plug/switch name for power cycling")
    ap.add_argument("--cycle", action="store_true",
                    help="power-cycle via --plug when local control fails")
    ap.add_argument("--interval", type=int, default=120,
                    help="seconds between checks (default 120)")
    ap.add_argument("--once", action="store_true", help="single check and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    dev = load_device(args.name)
    cloud = cloud_client()

    while True:
        ok = check_once(dev, cloud, args.plug, args.cycle)
        if args.once:
            sys.exit(0 if ok else 1)
        time.sleep(CLOUD_FALLBACK_RETRY_LOCAL if not ok else args.interval)


if __name__ == "__main__":
    main()
