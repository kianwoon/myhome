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
    {"cmd":"rescan"}
    {"cmd":"cloudsync"}
    {"cmd":"cloudstatus"}
    {"cmd":"cloudstatus","id":"<device-id>"}
    {"cmd":"specs"}
    {"cmd":"specs","id":"<device-id>"}
    {"cmd":"config"}
    {"cmd":"setconfig","apiKey":"...","apiSecret":"...","apiRegion":"..."}
"""

import json
import os
import sys
import tempfile
import threading

import tinytuya

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEVICES_PATH = os.path.join(BASE_DIR, "devices.json")
CREDENTIALS_PATH = os.path.join(BASE_DIR, "tinytuya.json")

SOCKET_TIMEOUT = 5

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
        return {"ok": False, "error": "cloud request failed: " + type(exc).__name__}

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
            "online": bool(config.get("ip")),
            "spec": config.get("spec"),
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
        return {"ok": False, "error": "cloud request failed: " + type(exc).__name__}

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
    if cmd == "rename":
        return handle_rename(request)
    if cmd == "rescan":
        return handle_rescan(request)
    if cmd == "cloudsync":
        return handle_cloudsync()
    if cmd == "cloudstatus":
        return handle_cloudstatus(request)
    if cmd == "specs":
        return handle_specs(request)
    if cmd == "config":
        return handle_config()
    if cmd == "setconfig":
        return handle_setconfig(request)
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
