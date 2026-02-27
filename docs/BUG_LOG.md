# Bug Log

Document bugs encountered during development and deployment. Format:

```
## Bug: [Short Title]
- **Date:** YYYY-MM-DD
- **Symptoms:** What was observed
- **Root Cause:** Why it happened
- **Fix:** What was changed
- **Prevention:** How to avoid in the future
```

---

## Bug: Edge Driver Cannot Make Outbound HTTPS Calls
- **Date:** 2026-02-19
- **Symptoms:** `cosock.asyncify "ssl.https"` fails with `"host or service not provided, or not known"` when calling api.smartthings.com from the hub
- **Root Cause:** SmartThings Edge platform intentionally blocks all outbound connections to non-RFC 1918 IP addresses. This is a security design decision — Edge drivers can only reach local LAN devices (192.168.x.x, 10.x.x.x, 172.16-31.x.x).
- **Fix:** Removed all outbound API calls. Driver now operates as a pure logic engine. Temperature input comes via SmartThings Rules API (cloud relay). Outlet control via Routines that mirror thermostatOperatingState.
- **Prevention:** Never attempt direct internet API calls from Edge drivers. Use Routines/Rules or a local proxy (EdgeBridge) for external API access.

## Bug: min_cycle_time Blocks Safety Shutoffs
- **Date:** 2026-02-20
- **Symptoms:** Setting mode to "off" while heater is running within the 5-minute min_cycle_time window does NOT turn off the heater. Same for stale temp and max runtime safety shutoffs.
- **Root Cause:** `set_outlet()` unconditionally checks `can_change_state()` (min_cycle_time) before allowing ANY state change, including safety-critical ones. The min_cycle_time exists to prevent compressor short-cycling, not to block emergency shutoffs.
- **Fix:** Added `force` parameter to `set_outlet(driver, device, on, force)`. When `force=true`, skips the `can_change_state()` check. Applied `force=true` at all 3 safety call sites: off-mode, stale-temp, and max-runtime.
- **Prevention:** Safety shutoffs must ALWAYS bypass convenience timers. Any new state-change guard must have a force-bypass path for safety code.

## Bug: Max Runtime Heater Restarts After 30 Seconds
- **Date:** 2026-02-20
- **Symptoms:** Max runtime triggers and turns off heater, but 30 seconds later on the next eval cycle, `check_max_runtime()` returns false (since `FIELD_OUTLET_ON_SINCE` was cleared) and `evaluate()` re-enables heating based on current temp vs setpoint.
- **Root Cause:** Max runtime had no persistent lockout — it only turned off the outlet for one cycle. The next eval re-evaluated from scratch and saw temp below setpoint, so it turned heating back on, creating an infinite on/off cycle.
- **Fix:** Added `FIELD_MAX_RUNTIME_LOCKOUT` flag. When max runtime triggers, lockout is set (persisted). `evaluate()` checks lockout at the top and returns early with forced-off. Lockout clears only on user action (mode change or setpoint change) across all 7 command handlers.
- **Prevention:** Any safety shutoff that should persist must set a lockout flag, not just turn off the outlet. The flag should only clear on explicit user action.

## Bug: evaluate() Timer Dies Silently on Lua Error
- **Date:** 2026-02-20
- **Symptoms:** If `evaluate()` throws any Lua error (e.g., nil arithmetic from a corrupted preference), the `call_on_schedule` timer stops firing permanently. All safety checks stop, and if the heater was on, it stays on indefinitely with no monitoring.
- **Root Cause:** SmartThings Edge `call_on_schedule` does not catch errors in callbacks — an unhandled error kills the timer thread. There was no pcall wrapper and no error recovery.
- **Fix:** Wrapped `thermostat_logic.evaluate()` call in `pcall()`. On error: log CRITICAL message, force `FIELD_OUTLET_ON=false`, emit idle operating state. Also wrapped `energy_tracker.accumulate()` in pcall (errors logged only). Added defensive `tonumber()` on all numeric pref reads as belt-and-suspenders.
- **Prevention:** ALL timer callbacks in Edge drivers must be wrapped in pcall. A timer callback error = silent death of the timer. For safety-critical timers, the error handler must force a safe state.

## Bug: Power Button on SmartThings App Does Not Turn Off Thermostat
- **Date:** 2026-02-21
- **Symptoms:** User presses power button on the thermostat tile in the SmartThings app. Heater continues running indefinitely. Mode stays at "heat" — never changes to "off".
- **Root Cause:** The SmartThings app thermostat tile power button sends `switch.off` / `switch.on` commands via the `switch` capability. The MasterStat device profile did not include the `switch` capability, so the command was silently dropped by the Edge framework. The mode was never changed.
- **Fix:** Added `switch` capability (version 1) to `profiles/virtual-thermostat.yaml`. Added `handle_switch_on` and `handle_switch_off` command handlers in `init.lua`. `switch.off` sets mode to off (same as thermostatMode.off). `switch.on` restores the last non-off mode via `FIELD_LAST_MODE`. All mode change handlers now emit corresponding switch state events to keep the UI in sync.
- **Prevention:** Always include the `switch` capability on any device where the SmartThings app shows a power button. Test all UI controls in the app, not just programmatic commands.

## Bug: Outlet Stays On ~5 Minutes After Setting Mode to Off
- **Date:** 2026-02-21
- **Symptoms:** Heater continued running for ~5 minutes after setting MasterStat mode to Off via the SmartThings app.
- **Root Cause:** The driver correctly emits `thermostatOperatingState = "idle"` with `state_change = true` every 30-second eval cycle, and the "Outlet OFF when idle" Rule is configured to send `switch.off` to the outlet. However, the SmartThings Rules engine appears to not re-trigger on repeated identical attribute values (idle → idle), even with `state_change = true`. If the initial Zigbee "off" command to the Sonoff outlet is lost (mesh reliability), subsequent duplicate idle emissions don't re-trigger the Rule, leaving the outlet physically on.
- **Fix:** Created a redundant Rule "MasterStat: Outlet OFF when mode off" (`0e90e445-503b-472a-89d8-f458f1ae05ab`) that fires on `thermostatMode == "off"` — a different attribute/trigger path. Now setting mode to off triggers TWO independent Rules: one on operating state change, one on mode change. Also added CSV logging with outlet switch state for future debugging.
- **Prevention:** For critical state changes, use redundant Rules on different trigger attributes. Don't rely on a single Rule + `state_change=true` for safety-critical actions. SmartThings Rules may deduplicate events with the same value regardless of the `state_change` flag.

## Bug: Dashboard 401 Auth Error Fails Silently with CLI Credentials
- **Date:** 2026-02-26
- **Symptoms:** Dashboard gets 401 Unauthorized from SmartThings API. No useful error message — the CLI token refresh runs but the user has no indication it failed or why. Dashboard keeps retrying with the same expired token.
- **Root Cause:** `refresh_cli_token()` did not check `subprocess.run` return code or capture stderr. When the CLI itself failed (e.g., expired OAuth session requiring re-authentication), the function returned silently as if it succeeded. The caller then re-read the same stale token from the credentials file.
- **Fix:** (1) Added return code check and stderr logging to `refresh_cli_token()` with actionable TIP messages. (2) Added startup validation that checks CLI credentials file exists and CLI binary is on PATH before starting the poll loop. (3) Added `text=True` to subprocess call so stderr is captured as a string.
- **Prevention:** Always check subprocess return codes. Any function that can fail should produce actionable error messages explaining what the user should do (e.g., "run X manually" or "set env var Y").

## Bug: Hub Rejects Events for New Attributes Added to Existing Capability
- **Date:** 2026-02-19
- **Symptoms:** `WARN Failed to send event: {unit="min", value=0} for energyTracking.heatingRuntime Failed to process event` after adding `heatingRuntime`, `coolingRuntime`, `dailyCycles`, `efficiency` attributes to existing `energytracking` capability via `capabilities:update`.
- **Root Cause:** The SmartThings hub caches capability schemas per-device at device creation time. Updating a capability's attributes in the cloud does not propagate to the hub's cached schema for existing devices. Repackaging/reinstalling the driver, bumping the DIP version, and calling `try_update_metadata` all failed to refresh the cache.
- **Fix:** Created a separate new capability (`benchventure06596.energydetails`) for the new attributes. The hub downloads fresh schemas for capabilities it hasn't cached before. Added it to the profile YAML, and emitted the new attributes on the new capability.
- **Prevention:** Never add new attributes to an existing custom capability that a device is already using. Instead, create a new capability for additional attributes.
