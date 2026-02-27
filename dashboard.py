#!/usr/bin/env python3
"""MasterStat Energy Dashboard — Local web dashboard for SmartThings thermostat monitoring."""

import argparse
import datetime
import getpass
import http.server
import json
import os
import shutil
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

# ── Constants ────────────────────────────────────────────────────
MASTERSTAT_ID = "e9cbfaea-3060-4835-95d6-8fb0649ca1e4"
OUTLET_ID = "375723e9-e893-425b-b9e8-04f56027ff6c"
API_BASE = "https://api.smartthings.com/v1"
DEFAULT_PORT = 8080
HISTORY_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard_history.json")
CSV_LOG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboard_log.csv")
HISTORY_MAX_AGE = 7 * 24 * 3600  # 7 days in seconds
POLL_INTERVAL = 60  # seconds
CLI_CREDS_FILE = os.path.expanduser(
    "~/Library/Application Support/@smartthings/cli/credentials.json"
)


# ── SmartThings API Client ───────────────────────────────────────

def read_cli_token():
    """Read the access token from the SmartThings CLI credentials file."""
    with open(CLI_CREDS_FILE, "r") as f:
        creds = json.load(f)
    return creds["default"]["accessToken"]


def refresh_cli_token():
    """Run a lightweight CLI command to trigger OAuth token refresh."""
    cli_path = shutil.which("smartthings")
    if not cli_path:
        print("ERROR: smartthings CLI not found on PATH. Use --pat or SMARTTHINGS_PAT env var instead.")
        raise RuntimeError("smartthings CLI not found on PATH")
    print(f"Refreshing token via CLI ({cli_path})...")
    result = subprocess.run(
        [cli_path, "devices", "-j"],
        capture_output=True, timeout=30, text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: CLI token refresh failed (exit code {result.returncode})")
        if result.stderr:
            print(f"  stderr: {result.stderr.strip()}")
        print("TIP: Run 'smartthings devices' manually to re-authenticate,")
        print("     or set SMARTTHINGS_PAT env var with a Personal Access Token.")
        detail = result.stderr.strip() or result.stdout.strip() or f"exit code {result.returncode}"
        raise RuntimeError(f"CLI token refresh failed: {detail}")
    print("Token refreshed successfully via CLI.")


def api_get(path, pat):
    """Make a GET request to the SmartThings API. On 401 with CLI auth, refresh and retry."""
    url = path if path.startswith("http") else f"{API_BASE}{path}"
    use_cli = (pat == "CLI")
    token = read_cli_token() if use_cli else pat

    for attempt in range(2):
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        })
        ctx = ssl.create_default_context()
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 401 and attempt == 0 and use_cli:
                print("Token expired, refreshing via CLI...")
                refresh_cli_token()
                token = read_cli_token()
                continue
            raise


def fetch_status(pat):
    """Fetch current status from both MasterStat and outlet devices."""
    result = {}

    try:
        data = api_get(f"/devices/{MASTERSTAT_ID}/status", pat)
        main = data.get("components", {}).get("main", {})

        def get_val(cap, attr, default=None):
            try:
                return main[cap][attr]["value"]
            except (KeyError, TypeError):
                return default

        def get_unit(cap, attr, default=""):
            try:
                return main[cap][attr].get("unit", default)
            except (KeyError, TypeError):
                return default

        result["temperature"] = get_val("temperatureMeasurement", "temperature")
        result["tempUnit"] = get_unit("temperatureMeasurement", "temperature", "F")
        result["mode"] = get_val("thermostatMode", "thermostatMode", "off")
        result["heatingSetpoint"] = get_val("thermostatHeatingSetpoint", "heatingSetpoint")
        result["coolingSetpoint"] = get_val("thermostatCoolingSetpoint", "coolingSetpoint")
        result["operatingState"] = get_val("thermostatOperatingState", "thermostatOperatingState", "idle")
        result["statusText"] = get_val("benchventure06596.statustext", "statusText", "")

        result["primaryTemp"] = get_val("benchventure06596.settemperature", "temperature")
        result["primaryTempUnit"] = get_unit("benchventure06596.settemperature", "temperature", "F")
        result["secondaryTemp"] = get_val("benchventure06596.settemperature2", "temperature")
        result["outdoorTemp"] = get_val("benchventure06596.outdoortemperature", "outdoorTemperature")

        result["dailyRuntime"] = get_val("benchventure06596.energytracking", "dailyRuntime", 0)
        result["heatingRuntime"] = get_val("benchventure06596.energydetails", "heatingRuntime", 0)
        result["coolingRuntime"] = get_val("benchventure06596.energydetails", "coolingRuntime", 0)
        result["dailyCycles"] = get_val("benchventure06596.energydetails", "dailyCycles", 0)
        result["efficiency"] = get_val("benchventure06596.energydetails", "efficiency", 0)

        result["runtimeSummary"] = get_val("benchventure06596.energysummary", "runtimeSummary", "")
        result["costSummary"] = get_val("benchventure06596.energysummary", "costSummary", "")
        result["efficiencySummary"] = get_val("benchventure06596.energysummary", "efficiencySummary", "")

    except Exception as e:
        result["error"] = f"MasterStat API error: {e}"

    try:
        data = api_get(f"/devices/{OUTLET_ID}/status", pat)
        main = data.get("components", {}).get("main", {})
        result["outletSwitch"] = main.get("switch", {}).get("switch", {}).get("value", "unknown")
    except Exception:
        result["outletSwitch"] = "unknown"

    return result


# ── Local History Store ──────────────────────────────────────────

_history_lock = threading.Lock()
_history = []


def load_history():
    """Load history from disk on startup."""
    global _history
    if os.path.exists(HISTORY_FILE):
        try:
            with open(HISTORY_FILE, "r") as f:
                _history = json.load(f)
            prune_history()
            print(f"Loaded {len(_history)} history points from {HISTORY_FILE}")
        except Exception as e:
            print(f"Warning: Could not load history: {e}")
            _history = []


def save_history():
    """Save history to disk."""
    try:
        with open(HISTORY_FILE, "w") as f:
            json.dump(_history, f)
    except Exception:
        pass


def prune_history():
    """Remove entries older than 24 hours."""
    global _history
    cutoff = time.time() - HISTORY_MAX_AGE
    _history = [h for h in _history if h.get("ts", 0) > cutoff]


def record_data_point(status):
    """Record a data point from the current status."""
    now = time.time()
    point = {
        "ts": now,
        "temp": status.get("temperature") or status.get("primaryTemp"),
        "outdoorTemp": status.get("outdoorTemp"),
        "heatingSetpoint": status.get("heatingSetpoint"),
        "coolingSetpoint": status.get("coolingSetpoint"),
        "operatingState": status.get("operatingState", "idle"),
        "mode": status.get("mode", "off"),
        "outletSwitch": status.get("outletSwitch", "unknown"),
    }
    with _history_lock:
        _history.append(point)
        prune_history()
        save_history()
    append_csv(point)


def get_history():
    """Return a copy of the history."""
    with _history_lock:
        return list(_history)


# ── CSV Log ──────────────────────────────────────────────────────

CSV_HEADER = "timestamp,temperature,outdoor_temp,heating_setpoint,cooling_setpoint,operating_state,mode,outlet_switch\n"


def init_csv():
    """Create CSV log file with header if it doesn't exist."""
    if not os.path.exists(CSV_LOG_FILE):
        with open(CSV_LOG_FILE, "w") as f:
            f.write(CSV_HEADER)
        print(f"Created CSV log: {CSV_LOG_FILE}")
    else:
        print(f"CSV log exists: {CSV_LOG_FILE}")


def append_csv(point):
    """Append a data point as a CSV row."""
    try:
        ts = datetime.datetime.fromtimestamp(point["ts"]).strftime("%Y-%m-%d %H:%M:%S")
        row = "{},{},{},{},{},{},{},{}\n".format(
            ts,
            point.get("temp", ""),
            point.get("outdoorTemp", ""),
            point.get("heatingSetpoint", ""),
            point.get("coolingSetpoint", ""),
            point.get("operatingState", ""),
            point.get("mode", ""),
            point.get("outletSwitch", ""),
        )
        with open(CSV_LOG_FILE, "a") as f:
            f.write(row)
    except Exception:
        pass


# ── History Backfill ─────────────────────────────────────────────

BACKFILL_MIN_GAP = 120  # seconds — only backfill if gap > 2 minutes
BACKFILL_SAMPLE_INTERVAL = 60  # one data point per minute


def get_last_csv_timestamp():
    """Return the timestamp of the last CSV row, or None if no data."""
    if not os.path.exists(CSV_LOG_FILE):
        return None
    try:
        with open(CSV_LOG_FILE, "r") as f:
            lines = f.readlines()
        for line in reversed(lines):
            line = line.strip()
            if not line or line.startswith("timestamp"):
                continue
            ts_str = line.split(",")[0]
            return datetime.datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S")
    except Exception:
        return None
    return None


def fetch_history_chunk(device_id, after_iso, before_iso):
    """Fetch device event history via SmartThings CLI for a time window."""
    cli_path = shutil.which("smartthings")
    if not cli_path:
        return []
    try:
        result = subprocess.run(
            [cli_path, "devices:history", device_id, "-j",
             "-L", "200", "-A", after_iso, "-B", before_iso],
            capture_output=True, timeout=30, text=True,
        )
        if result.returncode != 0:
            return []
        return json.loads(result.stdout)
    except Exception:
        return []


def find_csv_gaps(min_gap_seconds=300):
    """Scan CSV for gaps larger than min_gap_seconds. Returns list of (gap_start, gap_end, seed_state)."""
    if not os.path.exists(CSV_LOG_FILE):
        return []
    gaps = []
    prev_ts = None
    prev_state = None
    try:
        with open(CSV_LOG_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("timestamp"):
                    continue
                parts = line.split(",")
                if len(parts) < 8:
                    continue
                try:
                    ts = datetime.datetime.strptime(parts[0], "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    continue
                state = {
                    "temp": float(parts[1]) if parts[1] else None,
                    "outdoorTemp": float(parts[2]) if parts[2] else None,
                    "heatingSetpoint": float(parts[3]) if parts[3] else None,
                    "coolingSetpoint": float(parts[4]) if parts[4] else None,
                    "operatingState": parts[5] or "idle",
                    "mode": parts[6] or "heat",
                    "outletSwitch": parts[7] or "off",
                }
                if prev_ts and (ts - prev_ts).total_seconds() > min_gap_seconds:
                    gaps.append((prev_ts, ts, dict(prev_state)))
                prev_ts = ts
                prev_state = state
    except Exception:
        pass

    # Also check gap from last entry to now
    if prev_ts:
        now = datetime.datetime.now()
        if (now - prev_ts).total_seconds() > min_gap_seconds:
            gaps.append((prev_ts, now, dict(prev_state) if prev_state else None))

    return gaps


def backfill_gap(gap_start, gap_end, seed_state):
    """Backfill a single gap from SmartThings event history. Returns list of points."""
    attr_map = {
        "temperature": "temp",
        "thermostatOperatingState": "operatingState",
        "thermostatMode": "mode",
        "outdoorTemperature": "outdoorTemp",
        "heatingSetpoint": "heatingSetpoint",
        "coolingSetpoint": "coolingSetpoint",
    }

    state = seed_state or {
        "temp": None, "outdoorTemp": None,
        "heatingSetpoint": None, "coolingSetpoint": None,
        "operatingState": "idle", "mode": "heat", "outletSwitch": "off",
    }

    chunk_start = gap_start + datetime.timedelta(seconds=1)
    points = []

    while chunk_start < gap_end:
        chunk_end = min(chunk_start + datetime.timedelta(hours=1), gap_end)
        after_iso = chunk_start.strftime("%Y-%m-%dT%H:%M:%SZ")
        before_iso = chunk_end.strftime("%Y-%m-%dT%H:%M:%SZ")

        events = fetch_history_chunk(MASTERSTAT_ID, after_iso, before_iso)

        if events:
            events.sort(key=lambda e: e.get("epoch", 0))
            for event in events:
                attr = event.get("attribute", "")
                if attr in attr_map:
                    state[attr_map[attr]] = event.get("value")

            if state["operatingState"] == "heating":
                state["outletSwitch"] = "on"
            elif state["operatingState"] in ("idle", "cooling"):
                state["outletSwitch"] = "off"

        if state["temp"] is not None:
            mid = chunk_start + (chunk_end - chunk_start) / 2
            points.append({
                "ts": mid.timestamp(),
                "temp": state["temp"],
                "outdoorTemp": state["outdoorTemp"],
                "heatingSetpoint": state["heatingSetpoint"],
                "coolingSetpoint": state["coolingSetpoint"],
                "operatingState": state["operatingState"],
                "mode": state["mode"],
                "outletSwitch": state["outletSwitch"],
            })

        chunk_start = chunk_end

    return points


def backfill_from_history():
    """Scan CSV for gaps and fill them from SmartThings event history."""
    gaps = find_csv_gaps(min_gap_seconds=BACKFILL_MIN_GAP)
    if not gaps:
        print("Backfill: No gaps detected in CSV data.")
        return 0

    print(f"Backfill: Found {len(gaps)} gap(s) to fill.")
    total_points = 0

    for gap_start, gap_end, seed_state in gaps:
        gap_hours = (gap_end - gap_start).total_seconds() / 3600
        # SmartThings event history is typically retained ~7 days
        if gap_hours > 168:
            print(f"  Gap {gap_start} → {gap_end} ({gap_hours:.1f}h) — too old, skipping.")
            continue

        print(f"  Filling {gap_start} → {gap_end} ({gap_hours:.1f}h)...")
        points = backfill_gap(gap_start, gap_end, seed_state)

        if points:
            for point in points:
                append_csv(point)
            with _history_lock:
                _history.extend(points)
            total_points += len(points)
            print(f"    Recovered {len(points)} data points.")
        else:
            print(f"    No data recovered (device may have been offline).")

    if total_points:
        with _history_lock:
            # Re-sort history by timestamp after inserting backfill points
            _history.sort(key=lambda h: h.get("ts", 0))
            prune_history()
            save_history()
        print(f"Backfill: Total {total_points} data points recovered.")

    return total_points


# ── Background Poller ────────────────────────────────────────────

def start_poller(pat):
    """Background thread that polls status and records history every 60s."""
    def poll_loop():
        while True:
            try:
                status = fetch_status(pat)
                if "error" not in status:
                    record_data_point(status)
                    # Update status cache
                    _cache["status"] = {"data": status, "ts": time.time()}
            except Exception:
                pass
            time.sleep(POLL_INTERVAL)

    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()
    # Record initial data point
    try:
        status = fetch_status(pat)
        if "error" not in status:
            record_data_point(status)
            _cache["status"] = {"data": status, "ts": time.time()}
    except Exception:
        pass


# ── Cache ────────────────────────────────────────────────────────

_cache = {
    "status": {"data": None, "ts": 0},
}


def get_status_cached(pat):
    now = time.time()
    if _cache["status"]["data"] and (now - _cache["status"]["ts"]) < 30:
        return _cache["status"]["data"]
    data = fetch_status(pat)
    _cache["status"] = {"data": data, "ts": now}
    return data


# ── HTML Template ────────────────────────────────────────────────

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MasterStat Dashboard</title>
<style>
:root {
    --bg: #0f1923;
    --card-bg: #1a2736;
    --card-border: #2a3a4e;
    --text: #e0e8f0;
    --text-dim: #7a8ea0;
    --accent-heat: #e94560;
    --accent-cool: #4da8da;
    --accent-idle: #53d769;
    --accent-warn: #ffa500;
    --accent-off: #666;
    --accent-outdoor: #a78bfa;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    padding: 20px;
    max-width: 1100px;
    margin: 0 auto;
}
header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 20px;
    padding-bottom: 12px;
    border-bottom: 1px solid var(--card-border);
}
header h1 { font-size: 1.4em; font-weight: 600; }
#last-updated { color: var(--text-dim); font-size: 0.85em; }
.grid-2 {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    margin-bottom: 16px;
}
@media (max-width: 700px) { .grid-2 { grid-template-columns: 1fr; } }
.card {
    background: var(--card-bg);
    border: 1px solid var(--card-border);
    border-radius: 12px;
    padding: 20px;
    margin-bottom: 16px;
}
.card h2 {
    font-size: 0.85em;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--text-dim);
    margin-bottom: 16px;
}
.big-temp {
    font-size: 3em;
    font-weight: 700;
    line-height: 1;
    margin-bottom: 12px;
}
.status-row {
    display: flex;
    justify-content: space-between;
    padding: 6px 0;
    border-bottom: 1px solid rgba(255,255,255,0.05);
    font-size: 0.95em;
}
.status-row:last-child { border-bottom: none; }
.status-label { color: var(--text-dim); }
.status-value { font-weight: 500; }
.state-heating { color: var(--accent-heat); }
.state-cooling { color: var(--accent-cool); }
.state-idle { color: var(--accent-idle); }
.state-off { color: var(--accent-off); }
.outlet-on { color: var(--accent-heat); font-weight: 700; }
.outlet-off { color: var(--text-dim); }
.energy-metric {
    display: flex;
    flex-direction: column;
    padding: 10px 0;
    border-bottom: 1px solid rgba(255,255,255,0.05);
}
.energy-metric:last-child { border-bottom: none; }
.energy-metric .label { color: var(--text-dim); font-size: 0.85em; margin-bottom: 2px; }
.energy-metric .value { font-size: 1.3em; font-weight: 600; }
.energy-pair {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
}
.energy-pair .energy-metric { padding: 8px 0; }
.chart-container { position: relative; width: 100%; }
canvas { display: block; width: 100%; }
.insights-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: 12px;
}
.insight-item {
    text-align: center;
    padding: 12px;
    background: rgba(255,255,255,0.03);
    border-radius: 8px;
}
.insight-item .value { font-size: 1.4em; font-weight: 700; margin-bottom: 4px; }
.insight-item .label { font-size: 0.8em; color: var(--text-dim); }
.status-text {
    margin-top: 12px;
    padding: 10px 12px;
    background: rgba(255,255,255,0.03);
    border-radius: 8px;
    font-size: 0.9em;
    color: var(--text-dim);
    font-style: italic;
}
.error-banner {
    background: rgba(233,69,96,0.15);
    border: 1px solid var(--accent-heat);
    border-radius: 8px;
    padding: 12px;
    margin-bottom: 16px;
    color: var(--accent-heat);
    display: none;
}
.legend {
    display: flex;
    gap: 16px;
    justify-content: center;
    flex-wrap: wrap;
    margin-top: 8px;
    font-size: 0.8em;
    color: var(--text-dim);
}
.legend-item { display: flex; align-items: center; gap: 4px; }
.legend-swatch { width: 20px; height: 3px; border-radius: 2px; }
.chart-note {
    text-align: center;
    color: var(--text-dim);
    font-size: 0.8em;
    margin-top: 4px;
}
.zoom-controls {
    display: flex;
    gap: 6px;
    margin-bottom: 12px;
    flex-wrap: wrap;
}
.zoom-btn {
    background: rgba(255,255,255,0.06);
    border: 1px solid var(--card-border);
    color: var(--text-dim);
    padding: 5px 12px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 0.8em;
    font-family: inherit;
    transition: all 0.15s;
}
.zoom-btn:hover { background: rgba(255,255,255,0.12); color: var(--text); }
.zoom-btn.active { background: rgba(77,168,218,0.25); border-color: #4da8da; color: #4da8da; }
.chart-tooltip {
    display: none;
    position: absolute;
    background: rgba(15,25,35,0.95);
    border: 1px solid var(--card-border);
    border-radius: 8px;
    padding: 10px 12px;
    font-size: 0.82em;
    pointer-events: none;
    z-index: 10;
    white-space: nowrap;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4);
}
.chart-tooltip .tt-time { color: var(--text-dim); margin-bottom: 6px; font-size: 0.9em; }
.chart-tooltip .tt-row { padding: 2px 0; }
.chart-hint {
    text-align: center;
    color: var(--text-dim);
    font-size: 0.75em;
    margin-top: 6px;
    opacity: 0.6;
}
</style>
</head>
<body>

<header>
    <h1>MasterStat Dashboard</h1>
    <span id="last-updated">Loading...</span>
</header>

<div id="error-banner" class="error-banner"></div>

<div class="grid-2">
    <div class="card">
        <h2>Current Status</h2>
        <div id="big-temp" class="big-temp">--</div>
        <div id="status-rows">
            <div class="status-row"><span class="status-label">Mode</span><span id="s-mode" class="status-value">--</span></div>
            <div class="status-row"><span class="status-label">Setpoint</span><span id="s-setpoint" class="status-value">--</span></div>
            <div class="status-row"><span class="status-label">State</span><span id="s-state" class="status-value">--</span></div>
            <div class="status-row"><span class="status-label">Outlet</span><span id="s-outlet" class="status-value">--</span></div>
            <div class="status-row"><span class="status-label">Secondary Sensor</span><span id="s-secondary" class="status-value">--</span></div>
            <div class="status-row"><span class="status-label">Outdoor</span><span id="s-outdoor" class="status-value">--</span></div>
        </div>
        <div id="status-text" class="status-text" style="display:none;"></div>
    </div>

    <div class="card">
        <h2>Energy Today</h2>
        <div class="energy-pair">
            <div class="energy-metric">
                <span class="label">Heating</span>
                <span id="e-heat" class="value state-heating">--</span>
            </div>
            <div class="energy-metric">
                <span class="label">Cooling</span>
                <span id="e-cool" class="value state-cooling">--</span>
            </div>
        </div>
        <div class="energy-metric">
            <span class="label">Total Runtime</span>
            <span id="e-total" class="value">--</span>
        </div>
        <div class="energy-pair">
            <div class="energy-metric">
                <span class="label">Estimated Cost</span>
                <span id="e-cost" class="value">--</span>
            </div>
            <div class="energy-metric">
                <span class="label">Cycles</span>
                <span id="e-cycles" class="value">--</span>
            </div>
        </div>
        <div class="energy-metric">
            <span class="label">Comfort Efficiency</span>
            <span id="e-efficiency" class="value">--</span>
        </div>
    </div>
</div>

<div class="card">
    <h2>Temperature History</h2>
    <div class="zoom-controls">
        <button class="zoom-btn" data-range="3600000">1H</button>
        <button class="zoom-btn" data-range="14400000">4H</button>
        <button class="zoom-btn" data-range="43200000">12H</button>
        <button class="zoom-btn active" data-range="86400000">1D</button>
        <button class="zoom-btn" data-range="259200000">3D</button>
        <button class="zoom-btn" data-range="604800000">7D</button>
        <button class="zoom-btn" data-range="0">All</button>
    </div>
    <div class="chart-container">
        <canvas id="tempChart"></canvas>
        <div id="tooltip" class="chart-tooltip"></div>
    </div>
    <div class="legend">
        <div class="legend-item"><div class="legend-swatch" style="background:#4da8da;"></div> Indoor Temp</div>
        <div class="legend-item"><div class="legend-swatch" style="background:#a78bfa;"></div> Outdoor Temp</div>
        <div class="legend-item"><div class="legend-swatch" style="background:#e94560; opacity:0.7;"></div> Heat Setpoint</div>
        <div class="legend-item"><div class="legend-swatch" style="background:rgba(77,168,218,0.5);"></div> Cool Setpoint</div>
        <div class="legend-item"><div class="legend-swatch" style="background:rgba(233,69,96,0.15); height:10px;"></div> Heating</div>
        <div class="legend-item"><div class="legend-swatch" style="background:rgba(77,168,218,0.15); height:10px;"></div> Cooling</div>
    </div>
    <div class="chart-hint">Scroll to zoom &middot; Drag to pan</div>
</div>

<div class="card">
    <h2>Efficiency Insights</h2>
    <div id="insights" class="insights-grid">
        <div class="insight-item"><div id="i-duty" class="value">--</div><div class="label">Duty Cycle</div></div>
        <div class="insight-item"><div id="i-avg-cycle" class="value">--</div><div class="label">Avg Cycle</div></div>
        <div class="insight-item"><div id="i-avg-idle" class="value">--</div><div class="label">Avg Idle</div></div>
        <div class="insight-item"><div id="i-short" class="value">--</div><div class="label">Short Cycles</div></div>
        <div class="insight-item"><div id="i-longest" class="value">--</div><div class="label">Longest Run</div></div>
    </div>
</div>

<script>
function formatMins(m) {
    if (m == null || m <= 0) return '0m';
    const h = Math.floor(m / 60);
    const min = Math.round(m % 60);
    return h > 0 ? h + 'h ' + min + 'm' : min + 'm';
}

function stateClass(state) {
    if (state === 'heating') return 'state-heating';
    if (state === 'cooling') return 'state-cooling';
    if (state === 'idle') return 'state-idle';
    return 'state-off';
}

function tempStr(val, unit) {
    if (val == null) return '--';
    return Math.round(val * 10) / 10 + '\u00B0' + (unit || 'F');
}

// ── Update Status Card ──────────────────────────────────────
function updateStatus(s) {
    const unit = s.tempUnit || s.primaryTempUnit || 'F';
    // Prefer standard temperatureMeasurement; fall back to custom only if standard is missing
    const temp = s.temperature != null ? s.temperature : s.primaryTemp;
    document.getElementById('big-temp').textContent = tempStr(temp, unit);

    const modeEl = document.getElementById('s-mode');
    modeEl.textContent = (s.mode || '--').charAt(0).toUpperCase() + (s.mode || '').slice(1);
    modeEl.className = 'status-value ' + stateClass(s.mode === 'heat' ? 'heating' : s.mode === 'cool' ? 'cooling' : s.mode === 'off' ? 'off' : 'idle');

    if (s.mode === 'heat') {
        document.getElementById('s-setpoint').textContent = tempStr(s.heatingSetpoint, unit);
    } else if (s.mode === 'cool') {
        document.getElementById('s-setpoint').textContent = tempStr(s.coolingSetpoint, unit);
    } else if (s.mode === 'auto') {
        document.getElementById('s-setpoint').textContent = tempStr(s.heatingSetpoint, unit) + ' / ' + tempStr(s.coolingSetpoint, unit);
    } else {
        document.getElementById('s-setpoint').textContent = '--';
    }

    const stateEl = document.getElementById('s-state');
    stateEl.textContent = (s.operatingState || '--').charAt(0).toUpperCase() + (s.operatingState || '').slice(1);
    stateEl.className = 'status-value ' + stateClass(s.operatingState);

    const outEl = document.getElementById('s-outlet');
    outEl.textContent = (s.outletSwitch || '--').toUpperCase();
    outEl.className = 'status-value ' + (s.outletSwitch === 'on' ? 'outlet-on' : 'outlet-off');

    document.getElementById('s-secondary').textContent = s.secondaryTemp != null ? tempStr(s.secondaryTemp, unit) : '--';
    document.getElementById('s-outdoor').textContent = s.outdoorTemp != null ? tempStr(s.outdoorTemp, unit) : '--';

    const stEl = document.getElementById('status-text');
    if (s.statusText) { stEl.textContent = s.statusText; stEl.style.display = 'block'; }
    else { stEl.style.display = 'none'; }
}

// ── Update Energy Card ──────────────────────────────────────
function updateEnergy(s) {
    document.getElementById('e-heat').textContent = formatMins(s.heatingRuntime);
    document.getElementById('e-cool').textContent = formatMins(s.coolingRuntime);
    document.getElementById('e-total').textContent = formatMins(s.dailyRuntime);

    const costMatch = (s.costSummary || '').match(/\$[\d.]+/);
    document.getElementById('e-cost').textContent = costMatch ? costMatch[0] : '$0.00';
    document.getElementById('e-cycles').textContent = s.dailyCycles != null ? s.dailyCycles : '--';

    const eff = s.efficiency;
    const effEl = document.getElementById('e-efficiency');
    effEl.textContent = eff != null ? eff + '%' : '--%';
    effEl.style.color = eff >= 80 ? '#53d769' : eff >= 50 ? '#ffa500' : '#e94560';
}

// ── Chart State ─────────────────────────────────────────────
let chartViewStart = null;
let chartViewEnd = null;
let chartMeta = {};
let chartImageData = null;

// ── Draw Chart ──────────────────────────────────────────────
function drawChart(canvas, history, status) {
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.parentElement.getBoundingClientRect();
    const W = rect.width;
    const H = 320;
    canvas.width = W * dpr;
    canvas.height = H * dpr;
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    const ctx = canvas.getContext('2d');
    ctx.scale(dpr, dpr);

    const pad = { top: 20, right: 20, bottom: 45, left: 55 };
    const plotW = W - pad.left - pad.right;
    const plotH = H - pad.top - pad.bottom;

    // Filter valid data
    const indoorPts = history.filter(h => h.temp != null);
    const outdoorPts = history.filter(h => h.outdoorTemp != null);

    if (indoorPts.length === 0) {
        ctx.fillStyle = '#7a8ea0';
        ctx.font = '14px -apple-system, sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText('Collecting data... chart will appear as readings accumulate', W / 2, H / 2);
        chartMeta = {};
        return;
    }

    // Determine view range
    const dataStart = indoorPts[0].ts * 1000;
    const dataEnd = Date.now();
    let xMin, xMax;
    if (chartViewStart != null && chartViewEnd != null) {
        xMin = chartViewStart;
        xMax = chartViewEnd;
    } else {
        xMax = dataEnd;
        xMin = Math.max(dataStart, dataEnd - 86400000);
    }
    if (xMax - xMin < 600000) {
        const center = (xMin + xMax) / 2;
        xMin = center - 300000;
        xMax = center + 300000;
    }

    // Filter to visible range with margins for line continuity
    const margin = (xMax - xMin) * 0.05;
    const visIndoor = indoorPts.filter(h => h.ts * 1000 >= xMin - margin && h.ts * 1000 <= xMax + margin);
    const visOutdoor = outdoorPts.filter(h => h.ts * 1000 >= xMin - margin && h.ts * 1000 <= xMax + margin);
    const visHistory = history.filter(h => h.ts * 1000 >= xMin - margin && h.ts * 1000 <= xMax + margin);

    // Temp range from visible data
    const allVals = visIndoor.map(h => h.temp);
    visOutdoor.forEach(h => allVals.push(h.outdoorTemp));
    if (status.heatingSetpoint != null) allVals.push(status.heatingSetpoint);
    if (status.coolingSetpoint != null) allVals.push(status.coolingSetpoint);
    const dataMin = Math.min(...allVals);
    const dataMax = Math.max(...allVals);
    const yMin = Math.floor(dataMin / 5) * 5 - 5;
    const yMax = Math.ceil(dataMax / 5) * 5 + 5;

    const xMap = t => pad.left + ((t - xMin) / (xMax - xMin)) * plotW;
    const yMap = v => pad.top + plotH - ((v - yMin) / (yMax - yMin)) * plotH;

    // Store chart meta for tooltip
    chartMeta = { xMin, xMax, yMin, yMax, pad, plotW, plotH, W, H, xMap, yMap };

    ctx.clearRect(0, 0, W, H);

    // Operating state shading
    for (let i = 0; i < visHistory.length; i++) {
        const h = visHistory[i];
        if (h.operatingState === 'idle' || h.operatingState === 'off' || !h.operatingState) continue;
        const x1 = xMap(h.ts * 1000);
        const nextTs = i + 1 < visHistory.length ? visHistory[i + 1].ts * 1000 : dataEnd;
        const x2 = xMap(nextTs);
        if (x2 <= x1 || x1 > pad.left + plotW || x2 < pad.left) continue;
        const cx1 = Math.max(x1, pad.left);
        const cx2 = Math.min(x2, pad.left + plotW);
        ctx.fillStyle = h.operatingState === 'heating' ? 'rgba(233,69,96,0.12)' : 'rgba(77,168,218,0.12)';
        ctx.fillRect(cx1, pad.top, cx2 - cx1, plotH);
    }

    // Grid lines
    ctx.strokeStyle = 'rgba(255,255,255,0.06)';
    ctx.lineWidth = 1;
    ctx.font = '11px -apple-system, sans-serif';
    ctx.fillStyle = '#7a8ea0';

    // Y-axis
    ctx.textAlign = 'right';
    for (let y = yMin; y <= yMax; y += 5) {
        const py = yMap(y);
        ctx.beginPath(); ctx.moveTo(pad.left, py); ctx.lineTo(pad.left + plotW, py); ctx.stroke();
        ctx.fillText(y + '\u00B0', pad.left - 8, py + 4);
    }

    // X-axis: auto-scale labels based on visible span
    ctx.textAlign = 'center';
    const spanHours = (xMax - xMin) / 3600000;
    let stepMs;
    if (spanHours <= 2) stepMs = 1800000;
    else if (spanHours <= 6) stepMs = 3600000;
    else if (spanHours <= 12) stepMs = 7200000;
    else if (spanHours <= 36) stepMs = 14400000;
    else if (spanHours <= 96) stepMs = 43200000;
    else stepMs = 86400000;

    let labelTime = Math.ceil(xMin / stepMs) * stepMs;
    while (labelTime <= xMax) {
        const px = xMap(labelTime);
        if (px >= pad.left && px <= pad.left + plotW) {
            ctx.beginPath(); ctx.moveTo(px, pad.top); ctx.lineTo(px, pad.top + plotH); ctx.stroke();
            const d = new Date(labelTime);
            let label;
            if (stepMs >= 86400000) {
                label = (d.getMonth() + 1) + '/' + d.getDate();
            } else if (spanHours > 36) {
                let hr = d.getHours(); const ampm = hr >= 12 ? 'PM' : 'AM'; hr = hr % 12 || 12;
                label = (d.getMonth() + 1) + '/' + d.getDate() + ' ' + hr + ampm;
            } else {
                let hr = d.getHours(); const min = d.getMinutes();
                const ampm = hr >= 12 ? 'PM' : 'AM'; hr = hr % 12 || 12;
                label = min > 0 ? hr + ':' + String(min).padStart(2, '0') + ' ' + ampm : hr + ' ' + ampm;
            }
            ctx.fillText(label, px, pad.top + plotH + 20);
        }
        labelTime += stepMs;
    }

    // Setpoint lines (dashed)
    function drawHLine(val, color) {
        if (val == null || val < yMin || val > yMax) return;
        ctx.save();
        ctx.setLineDash([6, 4]);
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.globalAlpha = 0.6;
        ctx.beginPath();
        ctx.moveTo(pad.left, yMap(val));
        ctx.lineTo(pad.left + plotW, yMap(val));
        ctx.stroke();
        ctx.restore();
    }

    drawHLine(status.heatingSetpoint, '#e94560');
    drawHLine(status.coolingSetpoint, 'rgba(77,168,218,0.5)');

    // Draw a data line (clipped to plot area)
    function drawLine(pts, getVal, color, lineWidth, dash) {
        if (pts.length < 2) return;
        ctx.save();
        ctx.beginPath();
        ctx.rect(pad.left, pad.top, plotW, plotH);
        ctx.clip();
        ctx.setLineDash(dash || []);
        ctx.strokeStyle = color;
        ctx.lineWidth = lineWidth;
        ctx.beginPath();
        let started = false;
        for (const p of pts) {
            const v = getVal(p);
            if (v == null) continue;
            const x = xMap(p.ts * 1000);
            const y = yMap(v);
            if (!started) { ctx.moveTo(x, y); started = true; }
            else { ctx.lineTo(x, y); }
        }
        ctx.stroke();
        ctx.restore();
    }

    // Outdoor temperature line
    drawLine(visOutdoor, p => p.outdoorTemp, '#a78bfa', 1.5, [4, 3]);

    // Indoor temperature line (on top)
    drawLine(visIndoor, p => p.temp, '#4da8da', 2.5, []);

    // Current temp dot (if visible)
    if (visIndoor.length > 0) {
        const last = visIndoor[visIndoor.length - 1];
        const lx = xMap(last.ts * 1000);
        if (lx >= pad.left && lx <= pad.left + plotW) {
            const ly = yMap(last.temp);
            ctx.beginPath();
            ctx.arc(lx, ly, 4, 0, 2 * Math.PI);
            ctx.fillStyle = '#4da8da';
            ctx.fill();
            ctx.strokeStyle = '#0f1923';
            ctx.lineWidth = 2;
            ctx.stroke();
        }
    }

    // Current outdoor dot (if visible)
    if (visOutdoor.length > 0) {
        const last = visOutdoor[visOutdoor.length - 1];
        const lx = xMap(last.ts * 1000);
        if (lx >= pad.left && lx <= pad.left + plotW) {
            const ly = yMap(last.outdoorTemp);
            ctx.beginPath();
            ctx.arc(lx, ly, 3, 0, 2 * Math.PI);
            ctx.fillStyle = '#a78bfa';
            ctx.fill();
            ctx.strokeStyle = '#0f1923';
            ctx.lineWidth = 2;
            ctx.stroke();
        }
    }

    // Save chart image for crosshair overlay
    chartImageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
}

// ── Efficiency Insights ─────────────────────────────────────
function updateInsights(history, status) {
    const midnight = new Date();
    midnight.setHours(0, 0, 0, 0);
    const minsSinceMidnight = (Date.now() - midnight.getTime()) / 60000;

    const runtime = status.dailyRuntime || 0;
    const cycles = status.dailyCycles || 0;

    const duty = minsSinceMidnight > 0 ? Math.round(runtime / minsSinceMidnight * 100) : 0;
    document.getElementById('i-duty').textContent = duty + '%';

    // Analyze operating state transitions from local history
    let cycleDurations = [];
    let idleDurations = [];
    let activeStart = null;
    let idleStart = null;

    for (const h of history) {
        const t = h.ts * 1000;
        const st = h.operatingState;
        if (st === 'heating' || st === 'cooling') {
            if (!activeStart) activeStart = t;
            if (idleStart) {
                idleDurations.push((t - idleStart) / 60000);
                idleStart = null;
            }
        } else if (st === 'idle') {
            if (activeStart) {
                cycleDurations.push((t - activeStart) / 60000);
                activeStart = null;
            }
            if (!idleStart) idleStart = t;
        }
    }

    let avgCycle = cycleDurations.length > 0
        ? cycleDurations.reduce((a, b) => a + b, 0) / cycleDurations.length : 0;
    let avgIdle = idleDurations.length > 0
        ? idleDurations.reduce((a, b) => a + b, 0) / idleDurations.length : 0;
    const shortCycles = cycleDurations.filter(d => d < 5).length;
    let longest = cycleDurations.length > 0 ? Math.max(...cycleDurations) : 0;

    // Include current active run (not yet ended) in longest calculation
    if (activeStart) {
        const currentRun = (Date.now() - activeStart) / 60000;
        if (currentRun > longest) longest = currentRun;
        cycleDurations.push(currentRun);
    }

    // Fallback: use status data when local history is too thin
    if (cycleDurations.length === 0 && cycles > 0 && runtime > 0) {
        avgCycle = runtime / cycles;
        longest = avgCycle; // best estimate
        const idleMins = minsSinceMidnight - runtime;
        avgIdle = idleMins > 0 ? idleMins / cycles : 0;
    }

    document.getElementById('i-avg-cycle').textContent = formatMins(avgCycle);
    document.getElementById('i-avg-idle').textContent = formatMins(avgIdle);

    const shortEl = document.getElementById('i-short');
    shortEl.textContent = shortCycles > 0 ? shortCycles : 'None';
    shortEl.style.color = shortCycles > 0 ? '#ffa500' : '#53d769';

    document.getElementById('i-longest').textContent = formatMins(longest);
}

// ── Chart Interactions ──────────────────────────────────────
const chartCanvas = document.getElementById('tempChart');
const tooltipEl = document.getElementById('tooltip');
let isDragging = false;
let dragStartX = 0;
let dragStartViewStart = 0;
let dragStartViewEnd = 0;

function initChartView() {
    if (chartViewStart == null) {
        chartViewEnd = Date.now();
        chartViewStart = chartViewEnd - 86400000;
    }
}

// Zoom buttons
document.querySelectorAll('.zoom-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.zoom-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        const range = parseInt(btn.dataset.range);
        if (range === 0) {
            chartViewStart = null;
            chartViewEnd = null;
        } else {
            chartViewEnd = Date.now();
            chartViewStart = chartViewEnd - range;
        }
        if (lastHistory.length > 0) drawChart(chartCanvas, lastHistory, lastStatus);
    });
});

// Scroll to zoom
chartCanvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    initChartView();
    const rect = chartCanvas.getBoundingClientRect();
    const padL = 55, padR = 20;
    const pW = rect.width - padL - padR;
    const frac = Math.max(0, Math.min(1, (e.clientX - rect.left - padL) / pW));
    const range = chartViewEnd - chartViewStart;
    const factor = e.deltaY > 0 ? 1.3 : 1 / 1.3;
    const newRange = Math.max(600000, Math.min(7 * 86400000, range * factor));
    const anchor = chartViewStart + range * frac;
    chartViewStart = anchor - newRange * frac;
    chartViewEnd = anchor + newRange * (1 - frac);
    document.querySelectorAll('.zoom-btn').forEach(b => b.classList.remove('active'));
    if (lastHistory.length > 0) drawChart(chartCanvas, lastHistory, lastStatus);
}, { passive: false });

// Drag to pan
chartCanvas.addEventListener('mousedown', (e) => {
    isDragging = true;
    dragStartX = e.clientX;
    initChartView();
    dragStartViewStart = chartViewStart;
    dragStartViewEnd = chartViewEnd;
    chartCanvas.style.cursor = 'grabbing';
});

window.addEventListener('mousemove', (e) => {
    if (!isDragging) return;
    const rect = chartCanvas.getBoundingClientRect();
    const pW = rect.width - 55 - 20;
    const dx = e.clientX - dragStartX;
    const range = dragStartViewEnd - dragStartViewStart;
    const dt = -(dx / pW) * range;
    chartViewStart = dragStartViewStart + dt;
    chartViewEnd = dragStartViewEnd + dt;
    document.querySelectorAll('.zoom-btn').forEach(b => b.classList.remove('active'));
    if (lastHistory.length > 0) drawChart(chartCanvas, lastHistory, lastStatus);
});

window.addEventListener('mouseup', () => {
    if (isDragging) {
        isDragging = false;
        chartCanvas.style.cursor = 'crosshair';
    }
});

// Tooltip + crosshair on hover
chartCanvas.addEventListener('mousemove', (e) => {
    if (isDragging || !chartMeta.xMin) { tooltipEl.style.display = 'none'; return; }
    const rect = chartCanvas.getBoundingClientRect();
    const mouseXPx = e.clientX - rect.left;
    const frac = (mouseXPx - chartMeta.pad.left) / chartMeta.plotW;
    if (frac < 0 || frac > 1) { tooltipEl.style.display = 'none'; return; }
    const targetTs = (chartMeta.xMin + (chartMeta.xMax - chartMeta.xMin) * frac) / 1000;
    let nearest = null, nearestDist = Infinity;
    for (const h of lastHistory) {
        if (h.temp == null) continue;
        const dist = Math.abs(h.ts - targetTs);
        if (dist < nearestDist) { nearestDist = dist; nearest = h; }
    }
    if (!nearest || nearestDist > 300) { tooltipEl.style.display = 'none'; return; }
    const d = new Date(nearest.ts * 1000);
    const timeStr = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    const dateStr = d.toLocaleDateString([], { month: 'short', day: 'numeric' });
    let html = '<div class="tt-time">' + dateStr + ' ' + timeStr + '</div>';
    if (nearest.temp != null)
        html += '<div class="tt-row"><span style="color:#4da8da">\u25CF Indoor:</span> ' + (Math.round(nearest.temp * 10) / 10) + '\u00B0F</div>';
    if (nearest.outdoorTemp != null)
        html += '<div class="tt-row"><span style="color:#a78bfa">\u25CF Outdoor:</span> ' + (Math.round(nearest.outdoorTemp * 10) / 10) + '\u00B0F</div>';
    const st = nearest.operatingState || 'idle';
    const stLabel = st.charAt(0).toUpperCase() + st.slice(1);
    const stColor = st === 'heating' ? '#e94560' : st === 'cooling' ? '#4da8da' : '#53d769';
    html += '<div class="tt-row"><span style="color:' + stColor + '">\u25CF State:</span> ' + stLabel + '</div>';
    tooltipEl.innerHTML = html;
    tooltipEl.style.display = 'block';
    const containerRect = chartCanvas.parentElement.getBoundingClientRect();
    let ttLeft = mouseXPx + 12;
    if (ttLeft + tooltipEl.offsetWidth > containerRect.width - 4) ttLeft = mouseXPx - tooltipEl.offsetWidth - 12;
    let ttTop = (e.clientY - containerRect.top) - tooltipEl.offsetHeight / 2;
    ttTop = Math.max(4, Math.min(containerRect.height - tooltipEl.offsetHeight - 4, ttTop));
    tooltipEl.style.left = ttLeft + 'px';
    tooltipEl.style.top = ttTop + 'px';
    // Draw crosshair
    if (chartImageData) {
        const ctx2 = chartCanvas.getContext('2d');
        ctx2.putImageData(chartImageData, 0, 0);
        const dpr = window.devicePixelRatio || 1;
        ctx2.save();
        ctx2.scale(dpr, dpr);
        const px = chartMeta.xMap(nearest.ts * 1000);
        if (px >= chartMeta.pad.left && px <= chartMeta.pad.left + chartMeta.plotW) {
            ctx2.setLineDash([3, 3]);
            ctx2.strokeStyle = 'rgba(255,255,255,0.3)';
            ctx2.lineWidth = 1;
            ctx2.beginPath();
            ctx2.moveTo(px, chartMeta.pad.top);
            ctx2.lineTo(px, chartMeta.pad.top + chartMeta.plotH);
            ctx2.stroke();
        }
        ctx2.restore();
    }
});

chartCanvas.addEventListener('mouseleave', () => {
    tooltipEl.style.display = 'none';
    if (chartImageData) {
        chartCanvas.getContext('2d').putImageData(chartImageData, 0, 0);
    }
});

chartCanvas.style.cursor = 'crosshair';

// ── Refresh Loop ────────────────────────────────────────────
let lastStatus = {};
let lastHistory = [];

async function refresh() {
    const errorBanner = document.getElementById('error-banner');
    try {
        const [statusResp, historyResp] = await Promise.all([
            fetch('/api/status'),
            fetch('/api/history')
        ]);
        const status = await statusResp.json();
        const history = await historyResp.json();

        if (status.error) {
            errorBanner.textContent = status.error;
            errorBanner.style.display = 'block';
        } else {
            errorBanner.style.display = 'none';
        }

        lastStatus = status;
        lastHistory = history;
        updateStatus(status);
        updateEnergy(status);
        drawChart(document.getElementById('tempChart'), history, status);
        updateInsights(history, status);

        document.getElementById('last-updated').textContent =
            'Updated ' + new Date().toLocaleTimeString();
    } catch (err) {
        errorBanner.textContent = 'Failed to fetch data: ' + err.message;
        errorBanner.style.display = 'block';
    }
}

let resizeTimer;
window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
        if (lastHistory.length > 0) {
            drawChart(document.getElementById('tempChart'), lastHistory, lastStatus);
        }
    }, 200);
});

refresh();
setInterval(refresh, 60000);
</script>
</body>
</html>
"""


# ── HTTP Server ──────────────────────────────────────────────────

class DashboardHandler(http.server.BaseHTTPRequestHandler):
    pat = None

    def do_GET(self):
        if self.path == "/":
            self._serve_html()
        elif self.path == "/api/status":
            self._serve_json(get_status_cached(self.pat))
        elif self.path == "/api/history":
            self._serve_json(get_history())
        else:
            self.send_error(404)

    def _serve_html(self):
        content = DASHBOARD_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", len(content))
        self.end_headers()
        self.wfile.write(content)

    def _serve_json(self, data):
        content = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(content))
        self.end_headers()
        self.wfile.write(content)

    def log_message(self, format, *args):
        pass


# ── Main ─────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="MasterStat Energy Dashboard")
    parser.add_argument("--pat", help="SmartThings PAT (default: use CLI credentials)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"Port (default {DEFAULT_PORT})")
    args = parser.parse_args()

    if args.pat:
        pat = args.pat.strip()
        if not pat:
            print("Error: PAT value is empty.")
            sys.exit(1)
        print("Using PAT from --pat flag")
    elif os.environ.get("SMARTTHINGS_PAT", "").strip():
        pat = os.environ["SMARTTHINGS_PAT"].strip()
        print("Using PAT from SMARTTHINGS_PAT environment variable")
    elif os.path.exists(CLI_CREDS_FILE):
        pat = "CLI"
        print(f"Using SmartThings CLI credentials ({CLI_CREDS_FILE})")
    else:
        pat = getpass.getpass("SmartThings PAT: ").strip()
        if not pat:
            print("Error: No credentials found. Set SMARTTHINGS_PAT env var or install SmartThings CLI.")
            sys.exit(1)

    # Validate credential source before starting
    if pat == "CLI":
        cli_path = shutil.which("smartthings")
        if not cli_path:
            print("WARNING: smartthings CLI not found on PATH. Token refresh on 401 will fail.")
            print("TIP: Set SMARTTHINGS_PAT env var for reliable auth without CLI dependency.")

    print("Validating credentials...")
    try:
        api_get(f"/devices/{MASTERSTAT_ID}/status", pat)
        print("Credentials validated successfully.")
    except urllib.error.HTTPError as e:
        print(f"Error: SmartThings API returned {e.code}. Check your credentials.")
        sys.exit(1)
    except Exception as e:
        print(f"Error: Could not connect to SmartThings API: {e}")
        sys.exit(1)

    # Load existing history from disk
    load_history()
    init_csv()

    # Backfill any gaps from SmartThings event history
    backfill_from_history()

    # Start background poller
    DashboardHandler.pat = pat
    start_poller(pat)

    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("0.0.0.0", args.port), DashboardHandler)
    print(f"MasterStat Dashboard running at http://localhost:{args.port}")
    print(f"History file: {HISTORY_FILE}")
    print(f"CSV log: {CSV_LOG_FILE}")
    print("Data points are recorded every 60 seconds. Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
