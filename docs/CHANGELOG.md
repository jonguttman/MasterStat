# Changelog

## v0.7.1 — 2026-02-26

### Added
- Smart auto-switching logic in `thermostat_logic.evaluate()` for auto mode
- Outdoor temperature bias: suppress heating when outdoor temp is above cool threshold, suppress cooling when below heat threshold
- Trend awareness: suppress cooling when temp is already dropping, suppress heating when already rising (via new `trend.get_rate()`)
- Time-of-day awareness: suppress cooling in the evening when outdoor temp is below cool threshold
- Mode-switch cooldown: enforce idle period (default 10 min) between heat-to-cool or cool-to-heat transitions in auto mode
- New public function `trend.get_rate(device)` exposing raw temperature rate of change (degrees/minute)

### Changed
- Auto mode block in `evaluate()` rewritten with structured if/elseif chain: cooldown gating, hysteresis continuation, hard triggers with smart bias, and mode-switch tracking

## v0.7.0 — 2026-02-26

### Added
- Smart auto-switching constants and preferences for auto mode enhancements
- New field key `FIELD_LAST_AUTO_SWITCH_TIME` for tracking heat/cool transitions
- Default values: `DEFAULT_AUTO_OUTDOOR_HEAT_BELOW` (55°F), `DEFAULT_AUTO_OUTDOOR_COOL_ABOVE` (75°F), `DEFAULT_MODE_SWITCH_COOLDOWN` (10 min), `DEFAULT_EVENING_START_HOUR` (6 PM)
- 5 new device preferences: `autoOutdoorBias`, `autoOutdoorHeatBelow`, `autoOutdoorCoolAbove`, `modeSwitchCooldown`, `autoTimeAware`

## v0.6.4 — 2026-02-26

### Fixed
- `refresh_cli_token()` now checks return code and logs stderr on failure (previously failed silently)
- Added `text=True` to subprocess call so stderr is captured as a string, not bytes
- Actionable error messages with TIP lines guiding users to `--pat` or `SMARTTHINGS_PAT` env var

### Added
- Startup credential validation: when using CLI auth, checks that credentials file exists and CLI binary is on PATH before attempting API calls
- WARNING at startup if CLI binary is missing (token refresh on 401 will fail)

## v0.5.2 — 2026-02-21

### Fixed
- Existing device didn't pick up new `switch` capability from updated profile — added `try_update_metadata()` in `device_init` to force profile refresh on hub restart/driver update

## v0.5.1 — 2026-02-21

### Fixed
- **CRITICAL:** Power button on SmartThings app thermostat tile did nothing — device profile was missing `switch` capability. Pressing the power button sent a `switch.off` command that the driver silently ignored, leaving the heater running.
- Added `switch` capability to device profile and driver
- `switch.off` → sets mode to "off", turns off outlet (same as thermostatMode.off)
- `switch.on` → restores previous mode (heat/cool/auto), remembered via `FIELD_LAST_MODE`
- Switch state kept in sync with thermostat mode across all mode change paths

### Added
- Redundant Rule "MasterStat: Outlet OFF when mode off" for defense-in-depth outlet shutoff
- `FIELD_LAST_MODE` field to remember the last non-off mode for switch.on restore

## v0.6.3 — 2026-02-23

### Changed
- Dashboard credential resolution priority: `--pat` flag > `SMARTTHINGS_PAT` env var > CLI credentials file
- `SMARTTHINGS_PAT` env var is the recommended permanent setup (PATs never expire)
- CLI credentials auto-refresh on 401 as fallback
- No more interactive PAT prompt when any credential source is available

## v0.6.2 — 2026-02-21

### Added
- Persistent CSV log file (`dashboard_log.csv`) — appends one row per poll cycle, never pruned
  - Columns: timestamp, temperature, outdoor_temp, heating_setpoint, cooling_setpoint, operating_state, mode, outlet_switch
- Outlet switch state now recorded in JSON history data points

## v0.6.1 — 2026-02-21

### Added
- 7-day history retention (up from 24 hours)
- Zoom controls: 1H, 4H, 12H, 1D, 3D, 7D, All time range buttons
- Scroll-to-zoom on chart (mouse wheel zooms centered on cursor)
- Click-and-drag to pan the chart left/right through time
- Hover tooltip showing date/time, indoor temp, outdoor temp, and operating state
- Vertical crosshair line on hover for precise time reading
- Multi-day x-axis labels (date + time for >36h spans, date only for >4 day spans)
- Chart data clipped to plot area for clean rendering during zoom

## v0.6.0 — 2026-02-20

### Added
- Local Python web dashboard (`dashboard.py`) for energy monitoring and efficiency analysis
- Real-time display: temperature, mode, operating state, outlet status, setpoints
- Energy tracking: daily runtime breakdown (heat/cool), estimated cost, cycle count, efficiency %
- 24-hour temperature history chart with setpoint lines and heating/cooling period shading
- Efficiency insights: duty cycle %, average cycle/idle duration, short-cycling detection, longest run
- Auto-refresh every 60 seconds via SmartThings REST API
- Dark theme, card-based responsive layout
- Single-file, zero-dependency (Python stdlib only)

## Hub Cleanup — 2026-02-20

### Removed
- 13 unused Edge drivers uninstalled from hub: Aqara Presence, Zigbee Thermostat, Zigbee Temp Sensor Mc, Harman Luxury, Virtual Switch, JBL, Zigbee Thermostat Mc, DEEPSMART KNX, Z-Wave Thermostat Mc, Z-Wave Thermostat, Bose, SamsungAudio, zigbee-tuya-switch
- Philips Hue Edge driver was already removed (404 on uninstall)
- Hub went from 33 → 17 Edge drivers (each runs as a separate Lua process)
- "SmartThings Clothing Care" SmartApp not found in installed apps list (may have been auto-removed)

### Pending (manual via SmartThings app)
- 4 stale scenes to delete: Good Night!, Good Morning!, Goodbye!, I'm Back! (API returns 405 — must delete from app)
- Z-Wave network repair after cleanup
- Review 48 VIPER cloud devices for removed hardware

## v0.5.0 — 2026-02-20

### Added
- New `benchventure06596.energysummary` capability with 3 formatted string tiles:
  - **runtimeSummary**: Human-readable runtime (e.g., "Heat: 2h 15m (total)")
  - **costSummary**: Estimated daily cost + average cycle length (e.g., "Est. cost: $0.56 | Avg cycle: 18m")
  - **efficiencySummary**: Comfort percentage + cycle count (e.g., "Comfort: 87% | 5 cycles today")
- New preferences: `heaterWattage` (default 1500W) and `electricityRate` (default 15 cents/kWh) for cost estimation
- `format_mins()` helper for human-readable time formatting (e.g., "2h 15m" instead of "135")

### Fixed
- Startup safety bypass: temperature updates arriving during the 60s startup delay triggered `evaluate()` directly, causing the outlet to turn on before the idle Routine had time to turn it off. Added `FIELD_STARTUP_LOCKOUT` that blocks all evaluation until the startup delay completes.

## v0.4.0 — 2026-02-20

### Fixed
- **CRITICAL:** `min_cycle_time` no longer blocks safety shutoffs — off mode, stale temp, and max runtime now force-bypass the 5-minute cycle window
- **CRITICAL:** Max runtime now sets a lockout flag that prevents the heater from restarting on the next eval cycle; lockout clears when user changes mode or setpoint
- **CRITICAL:** `evaluate()` timer callback wrapped in `pcall` — a Lua error no longer kills the timer forever; on error, outlet is forced OFF

### Added
- Max runtime lockout flag (`FIELD_MAX_RUNTIME_LOCKOUT`) with persistent state and clear-on-user-action semantics
- Startup safety: outlet forced OFF on init, idle state emitted, first eval delayed 60 seconds so Routine can turn off physical outlet
- Temperature input validation: readings outside 0–150°F / -18–66°C are rejected and logged
- Secondary sensor toggle preference (`secondarySensorEnabled`) — disable Mysa averaging when readings are inaccurate
- Stale sensor override preference (`staleTempOverride`) — continue operating with stale data when sensor delays are expected; shows warning in status text
- Defensive `tonumber()` wrappers on all numeric preference reads to prevent corrupted prefs from crashing `evaluate()`
- `pcall` wrapper on energy tracker timer (non-safety-critical, errors logged only)
- Persisted temperature fields (`FIELD_TEMP1`, `FIELD_TEMP1_TIME`, `FIELD_TEMP2`, `FIELD_TEMP2_TIME`, `FIELD_CURRENT_TEMP`, `FIELD_LAST_TEMP_UPDATE`) survive hub reboots — driver resumes with last known temperature instead of waiting for the next Cielo Rule trigger

### Changed
- `set_outlet()` now accepts `force` parameter to bypass min_cycle_time for safety shutoffs
- Critical state fields (`FIELD_OUTLET_ON`, `FIELD_OUTLET_ON_SINCE`, `FIELD_LAST_STATE_CHANGE`) now persisted across hub reboots
- Status text shows lockout message when max runtime lockout is active
- Status text appends "(STALE SENSOR — override active)" when stale override is enabled and sensor would be stale
- Startup status text shows "Starting up — waiting 60s before first evaluation..."

## v0.3.3 — 2026-02-19

### Changed
- Deadband preference now supports decimal values (0.5°, 1°, 1.5°, 2°, 3°, 4°, 5°) via enumeration instead of integer
- Allows tighter temperature control (e.g., 0.5° deadband for ±0.5° from setpoint)

## v0.3.2 — 2026-02-19

### Added
- New `benchventure06596.energydetails` capability with `heatingRuntime`, `coolingRuntime`, `dailyCycles`, `efficiency` attributes
- Heating vs cooling runtime split: separate minute counters for heating and cooling
- Daily cycle count: increments each time the system transitions from idle to heating or cooling
- Comfort efficiency: percentage of tracked time that the current temperature is within the deadband of the active setpoint
- New device fields: `heat_mins_today`, `cool_mins_today`, `cycles_today`, `comfort_mins_today`, `tracked_mins_today`, `last_tracked_state`

### Changed
- `energy_tracker.accumulate()` now runs every tick regardless of outlet state (tracks comfort/efficiency even when idle)
- Existing `dailyRuntime` attribute on `energytracking` preserved for backward compatibility
- Daily reset now clears all new counters alongside the existing runtime counter

## v0.3.1 — 2026-02-19

### Fixed
- Operating state events not re-firing mid-cycle: added `state_change = true` to all `thermostatOperatingState` emissions so Routines re-fire every eval cycle (30s). If a Routine misses one event, the next cycle catches it. Ensures heater outlet and Mysa minisplit stay in sync.

## v0.3.0 — 2026-02-19

### Added
- Secondary temperature source via `benchventure06596.settemperature2` capability (Mysa thermostat)
- Temperature averaging: when both sources are fresh, uses the average; when only one is fresh, uses that one alone
- Dual-source stale check: only triggers stale alert when ALL temperature sources have timed out

### Changed
- Default stale temperature timeout increased from 30 to 60 minutes (configurable via preference)
- Stale check now evaluates individual source timestamps instead of a single `FIELD_LAST_TEMP_UPDATE`

## v0.2.0 — 2026-02-19

### Changed
- Removed outbound REST API calls from Edge driver (SmartThings hub blocks external HTTPS)
- Driver is now a pure logic engine — receives temperature via Routines/Rules, emits operating state
- Outlet control delegated to SmartThings Routines that mirror thermostatOperatingState
- Temperature input via SmartThings Rules API that relays Cielo readings to setTemperature command
- Removed polling timer and api_client dependency from thermostat_logic and init

## v0.1.0 — 2026-02-18

### Added
- Initial implementation of MasterStat Virtual Thermostat Edge driver
- Core thermostat modes: Heat, Cool, Auto, Off with hysteresis deadband
- REST API client (`cosock` async HTTPS) for controlling Sonoff S31 Lite ZB outlet
- Custom capability `masterstat.setTemperature` for Routine-pushed indoor temperature
- Custom capability `masterstat.outdoorTemperature` for Routine-pushed outdoor temperature
- Custom capability `masterstat.statusText` for dashboard status display
- Custom capability `masterstat.energyTracking` for daily runtime tracking
- `thermostatOperatingState` emission for Routines fallback outlet control
- Safety features: max runtime shutoff, stale temperature failsafe
- Minimum cycle time enforcement to prevent short cycling
- Day/night temperature setback scheduling
- Temperature trend detection with predictive heating/cooling offset
- Outdoor temperature logic to skip unnecessary heating/cooling
- Daily energy runtime tracking with midnight reset
- Configurable preferences: PAT, outlet device ID, temp unit, setpoints, deadband, timers, schedule, outdoor temp toggle
- Virtual LAN device creation via discovery handler
- Driver config, profile, and fingerprint YAML files
- README with installation guide and feature documentation
