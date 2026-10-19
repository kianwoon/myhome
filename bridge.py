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
    {"cmd":"cloudsync"}
    {"cmd":"cloudstatus"}
    {"cmd":"cloudstatus","id":"<device-id>"}
    {"cmd":"specs"}
    {"cmd":"specs","id":"<device-id>"}
"""

import json
import os
import sys
import tempfile

import tinytuya

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEVICES_PATH = os.path.join(BASE_DIR, "devices.json")
CREDENTIALS_PATH = os.path.join(BASE_DIR, "tinytuya.json")

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


def apply_to_disk(mutator):
    """Read-modify-write devices.json and refresh the serving cache.

    General rule: devices.json is SHARED MUTABLE STATE across independent
    bridge processes. No writer may dump its in-memory roster; every write
    re-reads the file, applies only that command's field-level delta to the
    fresh copy (by id), and writes that back. The write is atomic: a temp file
    in the same directory followed by os.replace.
    """
    global _devices
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
            "online": bool(config.get("ip")),
            "spec": config.get("spec"),
        })
    return {"ok": True, "devices": devices}


def handle_rescan():
    """Scan the LAN and merge ip/version into devices.json, preserving keys."""
    scan = tinytuya.deviceScan(poll=False, color=False)
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


def handle_cloudsync():
    """Re-sync device identity from the Tuya cloud.

    General rule: device IDENTITY (names, roster membership) is
    cloud-authoritative data and must re-sync on a schedule, just as STATUS
    is device-authoritative and re-syncs via polling. Local ip/version/key
    fields always win and are preserved; cloud-absent ids are marked, never
    deleted. Credentials are read from tinytuya.json and never echoed.
    """
    try:
        cloud = make_cloud()
        result = cloud.getdevices(False)
    except Exception as exc:
        # Never include token/secret material in the reply.
        return {"ok": False, "error": "cloud request failed: " + type(exc).__name__}

    if not isinstance(result, list) or not result:
        return {"ok": False, "error": "cloud sync failed: empty or unexpected response"}

    # General rule: shared mutable state — apply only this command's
    # name/roster delta to a fresh read; never dump the serving cache.
    renamed = 0
    added = 0
    seen = set()

    def merge(fresh):
        nonlocal renamed, added
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
                continue

            config["cloud"] = True
            if name and config.get("name") != name:
                config["name"] = name
                renamed += 1

        for config in fresh:
            if config.get("id") not in seen:
                config["cloud"] = False

    try:
        merged_devices = apply_to_disk(merge)
    except Exception as exc:
        return {"ok": False, "error": "devices write failed: " + type(exc).__name__}

    return {
        "ok": True,
        "renamed": renamed,
        "added": added,
        "total": len(merged_devices),
    }


def make_cloud():
    """Build a Cloud client from tinytuya.json. Secrets never leave this path."""
    with open(CREDENTIALS_PATH, "r", encoding="utf-8") as handle:
        credentials = json.load(handle)
    return tinytuya.Cloud(
        apiRegion=credentials.get("apiRegion"),
        apiKey=credentials.get("apiKey"),
        apiSecret=credentials.get("apiSecret"),
        apiDeviceID=credentials.get("apiDeviceID"),
    )


def fetch_spec(cloud, device_id):
    """Fetch one device's declared functions and normalise them by dp id."""
    url = "/v1.1/devices/%s/specifications" % device_id
    response = cloud.cloudrequest(url, "GET")
    body = response.get("result", response) if isinstance(response, dict) else None
    functions = body.get("functions") if isinstance(body, dict) else None
    if not isinstance(functions, list):
        return None

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
    return spec


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
        return {"ok": False, "error": "cloud request failed: " + type(exc).__name__}

    updated = 0
    failures = 0
    fetched_specs = {}
    for config in targets:
        if device_id is None and config.get("spec") and not request.get("refresh"):
            continue
        try:
            spec = fetch_spec(cloud, config.get("id"))
        except Exception:
            failures += 1
            continue
        if spec:
            fetched_specs[config.get("id")] = spec
            updated += 1
        else:
            failures += 1

    if fetched_specs:
        # General rule: shared mutable state — merge only the spec delta by id
        # into a fresh read; never dump the serving cache.
        def merge(fresh):
            by_id = {config.get("id"): config for config in fresh}
            for target_id, spec in fetched_specs.items():
                target = by_id.get(target_id)
                if target is not None:
                    target["spec"] = spec

        try:
            apply_to_disk(merge)
        except Exception as exc:
            return {"ok": False, "error": "devices write failed: " + type(exc).__name__}

    if updated == 0 and failures > 0:
        return {"ok": False, "error": "spec fetch failed"}
    return {"ok": True, "updated": updated}


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
        return {"ok": False, "error": "cloud request failed: " + type(exc).__name__}

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
    if cmd == "cloudsync":
        return handle_cloudsync()
    if cmd == "cloudstatus":
        return handle_cloudstatus(request)
    if cmd == "specs":
        return handle_specs(request)
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
