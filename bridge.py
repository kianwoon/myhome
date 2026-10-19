"""Persistent stdio JSON-lines bridge over tinytuya for the macOS app.

baseline-guard:allow new file, no prior baseline exists

Reads one JSON request per line from stdin and writes exactly one JSON response
per line to stdout. Device local keys are never logged or emitted.

Requests:
    {"cmd":"ping"}
    {"cmd":"list"}
    {"cmd":"status","id":"<device-id>"}
    {"cmd":"set","id":"<device-id>","dps":{...}}
    {"cmd":"rescan"}
"""

import json
import os
import sys

import tinytuya

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEVICES_PATH = os.path.join(BASE_DIR, "devices.json")

SOCKET_TIMEOUT = 5

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


def handle_list():
    devices = []
    for config in _devices:
        devices.append({
            "id": config.get("id"),
            "name": config.get("name"),
            "ip": config.get("ip", ""),
            "version": config.get("version"),
            "category": config.get("category"),
            "online": bool(config.get("ip")),
        })
    return {"ok": True, "devices": devices}


def handle_rescan():
    """Scan the LAN and merge ip/version into devices.json, preserving keys."""
    scan = tinytuya.deviceScan(poll=False, color=False)
    if not isinstance(scan, dict):
        scan = {}
    by_id = {config.get("id"): config for config in _devices}
    merged = 0
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
    with open(DEVICES_PATH, "w", encoding="utf-8") as handle:
        json.dump(_devices, handle, indent=2)
        handle.write("\n")
    # Addresses may have moved, so drop cached sockets.
    _device_cache.clear()
    return {"ok": True, "merged": merged}


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
    if cmd == "rescan":
        return handle_rescan()
    return {"ok": False, "error": "unknown command"}


def respond(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


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
            try:
                respond(dispatch(request))
            except Exception as exc:
                respond({"ok": False, "error": str(exc) or "request failed"})
        except Exception:
            respond({"ok": False, "error": "bad request"})


if __name__ == "__main__":
    main()
