-- MasterStat Thermostat Logic
-- Core decision engine: heat/cool/auto with hysteresis, safety checks, and integrations

local constants = require "constants"
local scheduler = require "scheduler"
local trend = require "trend"
local log = require "log"

local thermostat_logic = {}

-- ============================================================
-- Helper: Get preference with fallback
-- ============================================================
local function pref(device, key, default)
  if device.preferences and device.preferences[key] ~= nil then
    return device.preferences[key]
  end
  return default
end

-- ============================================================
-- Helper: Get effective setpoint (schedule override or device field)
-- ============================================================
local function get_setpoint(device, mode)
  local scheduled = scheduler.get_effective_setpoint(device, mode)
  if scheduled then
    return scheduled
  end
  local base
  if mode == "heat" then
    base = device:get_field(constants.FIELD_HEAT_SETPOINT) or constants.DEFAULT_HEAT_SETPOINT
  else
    base = device:get_field(constants.FIELD_COOL_SETPOINT) or constants.DEFAULT_COOL_SETPOINT
  end
  local offset = pref(device, "comfortOffset", 0)
  return base + offset
end

-- ============================================================
-- Safety: Max runtime check
-- ============================================================
local function check_max_runtime(device)
  local outlet_on = device:get_field(constants.FIELD_OUTLET_ON)
  if not outlet_on then
    return false  -- not a safety issue
  end

  local on_since = device:get_field(constants.FIELD_OUTLET_ON_SINCE)
  if not on_since then
    return false
  end

  local max_runtime = tonumber(pref(device, "maxRuntime", constants.DEFAULT_MAX_RUNTIME)) or constants.DEFAULT_MAX_RUNTIME
  local elapsed_mins = (os.time() - on_since) / 60

  if elapsed_mins >= max_runtime then
    log.warn(string.format("SAFETY: Max runtime exceeded (%.0f min >= %d min)", elapsed_mins, max_runtime))
    return true
  end
  return false
end

-- ============================================================
-- Safety: Stale temperature check
-- ============================================================
local function check_stale_temp(device)
  local now = os.time()
  local timeout = tonumber(pref(device, "staleTempTimeout", constants.DEFAULT_STALE_TEMP_TIMEOUT)) or constants.DEFAULT_STALE_TEMP_TIMEOUT
  local timeout_sec = timeout * 60

  -- Check temperature sources — respect secondary sensor toggle
  local t1_time = device:get_field(constants.FIELD_TEMP1_TIME)
  local secondary_enabled = pref(device, "secondarySensorEnabled", true)
  local t2_time = secondary_enabled and device:get_field(constants.FIELD_TEMP2_TIME) or nil

  -- If no source has ever reported, don't flag stale
  if not t1_time and not t2_time then
    -- Fall back to legacy field for backward compatibility
    local last_update = device:get_field(constants.FIELD_LAST_TEMP_UPDATE)
    if not last_update then return false end
    local elapsed_mins = (now - last_update) / 60
    if elapsed_mins >= timeout then
      log.warn(string.format("SAFETY: Stale temperature (%.0f min since last update, timeout=%d min)",
        elapsed_mins, timeout))
      -- Check stale override
      if pref(device, "staleTempOverride", false) then
        log.warn("SAFETY: Stale sensor override ACTIVE — continuing operation with stale data")
        return false
      end
      return true
    end
    return false
  end

  local t1_fresh = t1_time and (now - t1_time) < timeout_sec
  local t2_fresh = t2_time and (now - t2_time) < timeout_sec

  if t1_fresh or t2_fresh then
    return false  -- at least one source is fresh
  end

  -- All applicable sources stale
  local newest = math.max(t1_time or 0, t2_time or 0)
  local elapsed_mins = (now - newest) / 60
  log.warn(string.format("SAFETY: Stale temperature — all sources stale (%.0f min since newest update, timeout=%d min)",
    elapsed_mins, timeout))

  -- Check stale override
  if pref(device, "staleTempOverride", false) then
    log.warn("SAFETY: Stale sensor override ACTIVE — continuing operation with stale data")
    return false
  end

  return true
end

-- ============================================================
-- Min cycle time enforcement
-- ============================================================
local function can_change_state(device)
  local last_change = device:get_field(constants.FIELD_LAST_STATE_CHANGE)
  if not last_change then
    return true
  end

  local min_cycle = tonumber(pref(device, "minCycleTime", constants.DEFAULT_MIN_CYCLE_TIME)) or constants.DEFAULT_MIN_CYCLE_TIME
  local elapsed_mins = (os.time() - last_change) / 60

  if elapsed_mins < min_cycle then
    log.debug(string.format("thermostat_logic: Min cycle time not met (%.1f < %d min)", elapsed_mins, min_cycle))
    return false
  end
  return true
end

-- ============================================================
-- Outdoor temperature logic
-- ============================================================
local function should_skip_for_outdoor(device, mode, setpoint)
  local enabled = pref(device, "outdoorTempEnabled", false)
  if not enabled then
    return false
  end

  local outdoor = device:get_field(constants.FIELD_OUTDOOR_TEMP)
  if not outdoor then
    return false
  end

  if mode == "heat" and outdoor > (setpoint + constants.OUTDOOR_HEAT_SKIP_OFFSET) then
    log.info(string.format("thermostat_logic: Skipping heat — outdoor %.1f > setpoint %d + %d",
      outdoor, setpoint, constants.OUTDOOR_HEAT_SKIP_OFFSET))
    return true
  end

  if mode == "cool" and outdoor < (setpoint - constants.OUTDOOR_COOL_SKIP_OFFSET) then
    log.info(string.format("thermostat_logic: Skipping cool — outdoor %.1f < setpoint %d - %d",
      outdoor, setpoint, constants.OUTDOOR_COOL_SKIP_OFFSET))
    return true
  end

  return false
end

-- ============================================================
-- Auto mode: mode-switch cooldown check
-- ============================================================
local function check_auto_cooldown(device)
  local last_switch = device:get_field(constants.FIELD_LAST_AUTO_SWITCH_TIME)
  if not last_switch then
    return false  -- no previous switch, no cooldown needed
  end

  local cooldown = tonumber(pref(device, "modeSwitchCooldown", constants.DEFAULT_MODE_SWITCH_COOLDOWN))
    or constants.DEFAULT_MODE_SWITCH_COOLDOWN
  local elapsed_mins = (os.time() - last_switch) / 60

  if elapsed_mins < cooldown then
    log.debug(string.format("thermostat_logic: Auto mode-switch cooldown active (%.1f < %d min)", elapsed_mins, cooldown))
    return true
  end
  return false
end

-- ============================================================
-- Auto mode: smart signal evaluation for dead zone decisions
-- ============================================================
local function auto_smart_bias(device, mode_candidate)
  -- Returns true if the candidate mode should be SUPPRESSED
  local outdoor = device:get_field(constants.FIELD_OUTDOOR_TEMP)

  -- Outdoor temperature bias
  if pref(device, "autoOutdoorBias", true) and outdoor then
    local heat_below = tonumber(pref(device, "autoOutdoorHeatBelow", constants.DEFAULT_AUTO_OUTDOOR_HEAT_BELOW))
      or constants.DEFAULT_AUTO_OUTDOOR_HEAT_BELOW
    local cool_above = tonumber(pref(device, "autoOutdoorCoolAbove", constants.DEFAULT_AUTO_OUTDOOR_COOL_ABOVE))
      or constants.DEFAULT_AUTO_OUTDOOR_COOL_ABOVE

    if mode_candidate == "heating" and outdoor > cool_above then
      log.info(string.format("thermostat_logic: Auto suppressing heat — outdoor %.1f > %d (too warm outside to heat)", outdoor, cool_above))
      return true
    end
    if mode_candidate == "cooling" and outdoor < heat_below then
      log.info(string.format("thermostat_logic: Auto suppressing cool — outdoor %.1f < %d (too cold outside to cool)", outdoor, heat_below))
      return true
    end
  end

  -- Trend awareness: don't fight momentum
  local rate = trend.get_rate(device)
  if rate ~= 0 then
    if mode_candidate == "cooling" and rate < -0.1 then
      log.info(string.format("thermostat_logic: Auto suppressing cool — temp already dropping (%.3f deg/min)", rate))
      return true
    end
    if mode_candidate == "heating" and rate > 0.1 then
      log.info(string.format("thermostat_logic: Auto suppressing heat — temp already rising (%.3f deg/min)", rate))
      return true
    end
  end

  -- Time-of-day: suppress cooling in the evening when outdoor temp is below cool threshold
  if pref(device, "autoTimeAware", true) and mode_candidate == "cooling" then
    local hour = tonumber(os.date("%H"))  -- hub local time (set in SmartThings app)
    local evening_start = constants.DEFAULT_EVENING_START_HOUR
    if hour >= evening_start and outdoor then
      local cool_above = tonumber(pref(device, "autoOutdoorCoolAbove", constants.DEFAULT_AUTO_OUTDOOR_COOL_ABOVE))
        or constants.DEFAULT_AUTO_OUTDOOR_COOL_ABOVE
      -- In the evening, if outdoor temp is below the cool threshold, suppress cooling
      if outdoor < cool_above then
        log.info(string.format("thermostat_logic: Auto suppressing cool — evening (hour=%d) and outdoor %.1f < %d", hour, outdoor, cool_above))
        return true
      end
    end
  end

  return false  -- no suppression
end

-- ============================================================
-- Set outlet state (track state; Routine mirrors operating state to outlet)
-- ============================================================
local function set_outlet(driver, device, on, force)
  local current = device:get_field(constants.FIELD_OUTLET_ON) or false
  if on == current then
    return  -- no change needed
  end

  if not force and not can_change_state(device) then
    return  -- respect min cycle time
  end

  device:set_field(constants.FIELD_OUTLET_ON, on, { persist = true })
  device:set_field(constants.FIELD_LAST_STATE_CHANGE, os.time(), { persist = true })
  if on then
    device:set_field(constants.FIELD_OUTLET_ON_SINCE, os.time(), { persist = true })
  else
    device:set_field(constants.FIELD_OUTLET_ON_SINCE, nil, { persist = true })
  end
  log.info(string.format("thermostat_logic: Outlet state → %s%s (Routine controls physical outlet)",
    on and "ON" or "OFF", force and " (FORCED)" or ""))
end

-- ============================================================
-- Build status text
-- ============================================================
local function is_sensor_stale(device)
  local now = os.time()
  local timeout = tonumber(pref(device, "staleTempTimeout", constants.DEFAULT_STALE_TEMP_TIMEOUT)) or constants.DEFAULT_STALE_TEMP_TIMEOUT
  local timeout_sec = timeout * 60

  local t1_time = device:get_field(constants.FIELD_TEMP1_TIME)
  local secondary_enabled = pref(device, "secondarySensorEnabled", true)
  local t2_time = secondary_enabled and device:get_field(constants.FIELD_TEMP2_TIME) or nil

  if not t1_time and not t2_time then
    local last_update = device:get_field(constants.FIELD_LAST_TEMP_UPDATE)
    if not last_update then return false end
    return (now - last_update) / 60 >= timeout
  end

  local t1_fresh = t1_time and (now - t1_time) < timeout_sec
  local t2_fresh = t2_time and (now - t2_time) < timeout_sec
  return not (t1_fresh or t2_fresh)
end

local function build_status(device, state, setpoint)
  local temp = device:get_field(constants.FIELD_CURRENT_TEMP)
  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  local stale = device:get_field(constants.FIELD_STALE_ALERT)
  local lockout = device:get_field(constants.FIELD_MAX_RUNTIME_LOCKOUT)

  if lockout then
    return "SAFETY: Max runtime lockout — outlet OFF (change mode or setpoint to clear)"
  end

  if stale then
    return "ALERT: Stale temperature — outlet OFF for safety"
  end

  if not temp then
    return "Waiting for temperature reading..."
  end

  -- Check if stale override is active and sensor would be stale
  local stale_warning = ""
  if pref(device, "staleTempOverride", false) and is_sensor_stale(device) then
    stale_warning = " (STALE SENSOR — override active)"
  end

  if state == "heating" then
    return string.format("Heating to %d%s%s (current: %.1f%s%s)%s",
      setpoint, "\194\176", unit, temp, "\194\176", unit, stale_warning)
  elseif state == "cooling" then
    return string.format("Cooling to %d%s%s (current: %.1f%s%s)%s",
      setpoint, "\194\176", unit, temp, "\194\176", unit, stale_warning)
  else
    return string.format("Idle at %.1f%s%s (setpoint: %d%s%s)%s",
      temp, "\194\176", unit, setpoint, "\194\176", unit, stale_warning)
  end
end

-- ============================================================
-- Main evaluation function
-- Called on every temp update + periodically by timer
-- ============================================================
function thermostat_logic.evaluate(driver, device, caps)
  -- Startup lockout: skip evaluation until startup delay completes
  if device:get_field(constants.FIELD_STARTUP_LOCKOUT) then
    log.debug("thermostat_logic: Startup lockout active — skipping evaluation")
    return
  end

  local mode = device:get_field(constants.FIELD_MODE) or "off"
  local temp = device:get_field(constants.FIELD_CURRENT_TEMP)
  local outlet_on = device:get_field(constants.FIELD_OUTLET_ON) or false
  local deadband_raw = tonumber(pref(device, "deadband", 20)) or 20
  local deadband = deadband_raw / 10

  -- Lockout check: if max runtime lockout is active, force off and return early
  if device:get_field(constants.FIELD_MAX_RUNTIME_LOCKOUT) then
    set_outlet(driver, device, false, true)
    device:set_field(constants.FIELD_OPERATING_STATE, "idle")
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState(
        { value = "idle" }, { state_change = true }))
    end
    if caps.status_text then
      device:emit_event(caps.status_text.statusText({ value = build_status(device, "idle", 0) }))
    end
    return
  end

  -- Off mode: ensure outlet is off (force bypass min_cycle_time)
  if mode == "off" then
    if outlet_on then
      set_outlet(driver, device, false, true)
    end
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState(
        { value = "idle" }, { state_change = true }))
    end
    device:set_field(constants.FIELD_OPERATING_STATE, "idle")
    if caps.status_text then
      device:emit_event(caps.status_text.statusText({ value = "Off" }))
    end
    return
  end

  -- Safety: stale temperature (force bypass min_cycle_time)
  if check_stale_temp(device) then
    device:set_field(constants.FIELD_STALE_ALERT, true)
    if outlet_on then
      set_outlet(driver, device, false, true)
    end
    local state = "idle"
    device:set_field(constants.FIELD_OPERATING_STATE, state)
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState(
        { value = "idle" }, { state_change = true }))
    end
    if caps.status_text then
      device:emit_event(caps.status_text.statusText({ value = build_status(device, state, 0) }))
    end
    return
  end

  -- Clear stale alert if we have fresh temp
  device:set_field(constants.FIELD_STALE_ALERT, false)

  -- No temp yet — can't make decisions
  if not temp then
    return
  end

  -- Safety: max runtime (force bypass min_cycle_time + set lockout)
  if check_max_runtime(device) then
    device:set_field(constants.FIELD_MAX_RUNTIME_LOCKOUT, true, { persist = true })
    set_outlet(driver, device, false, true)
    local state = "idle"
    device:set_field(constants.FIELD_OPERATING_STATE, state)
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState(
        { value = "idle" }, { state_change = true }))
    end
    if caps.status_text then
      device:emit_event(caps.status_text.statusText({ value = build_status(device, state, 0) }))
    end
    return
  end

  -- Determine desired state based on mode
  local desired_state = "idle"
  local active_setpoint = 72

  if mode == "heat" then
    local heat_sp = get_setpoint(device, "heat")
    local offset = trend.get_predictive_offset(device, "heat")
    active_setpoint = heat_sp

    if should_skip_for_outdoor(device, "heat", heat_sp) then
      desired_state = "idle"
    elseif outlet_on and temp < heat_sp then
      -- Already heating, continue until setpoint reached
      desired_state = "heating"
    elseif not outlet_on and temp < (heat_sp - deadband + offset) then
      -- Below setpoint minus deadband (adjusted by trend) → start heating
      desired_state = "heating"
    else
      desired_state = "idle"
    end

  elseif mode == "cool" then
    local cool_sp = get_setpoint(device, "cool")
    local offset = trend.get_predictive_offset(device, "cool")
    active_setpoint = cool_sp

    if should_skip_for_outdoor(device, "cool", cool_sp) then
      desired_state = "idle"
    elseif outlet_on and temp > cool_sp then
      -- Already cooling, continue until setpoint reached
      desired_state = "cooling"
    elseif not outlet_on and temp > (cool_sp + deadband - offset) then
      -- Above setpoint plus deadband (adjusted by trend) → start cooling
      desired_state = "cooling"
    else
      desired_state = "idle"
    end

  elseif mode == "auto" then
    local heat_sp = get_setpoint(device, "heat")
    local cool_sp = get_setpoint(device, "cool")
    local heat_offset = trend.get_predictive_offset(device, "heat")
    local cool_offset = trend.get_predictive_offset(device, "cool")
    local auto_action = device:get_field(constants.FIELD_AUTO_ACTION) or "idle"
    local in_cooldown = check_auto_cooldown(device)
    active_setpoint = heat_sp  -- default for idle display

    -- If in cooldown between mode switches, force idle
    -- (covers post-switch idle enforcement when FIELD_LAST_AUTO_SWITCH_TIME is set)
    if in_cooldown and auto_action == "idle" then
      desired_state = "idle"

    -- Continue existing commitment (hysteresis)
    elseif auto_action == "heating" and temp < heat_sp then
      desired_state = "heating"
      active_setpoint = heat_sp

    elseif auto_action == "cooling" and temp > cool_sp then
      desired_state = "cooling"
      active_setpoint = cool_sp

    -- Hard triggers (outside deadband — unconditional)
    elseif not should_skip_for_outdoor(device, "heat", heat_sp) and temp < (heat_sp - deadband + heat_offset) then
      if not auto_smart_bias(device, "heating") then
        desired_state = "heating"
        active_setpoint = heat_sp
      end

    elseif not should_skip_for_outdoor(device, "cool", cool_sp) and temp > (cool_sp + deadband - cool_offset) then
      if not auto_smart_bias(device, "cooling") then
        desired_state = "cooling"
        active_setpoint = cool_sp
      end
    end

    -- Track mode switches for cooldown
    local prev_action = auto_action
    if desired_state ~= "idle" and desired_state ~= prev_action and prev_action ~= "idle" then
      -- Switching from one active mode to another (heat→cool or cool→heat)
      -- Force idle and start cooldown
      log.info(string.format("thermostat_logic: Auto mode switch %s→%s — entering cooldown", prev_action, desired_state))
      device:set_field(constants.FIELD_LAST_AUTO_SWITCH_TIME, os.time(), { persist = true })
      desired_state = "idle"
      active_setpoint = heat_sp
    end

    device:set_field(constants.FIELD_AUTO_ACTION, desired_state)
  end

  -- Apply desired state
  local want_on = (desired_state == "heating" or desired_state == "cooling")
  set_outlet(driver, device, want_on)

  -- Emit operating state (state_change = true ensures Routines re-fire every
  -- eval cycle, so if a Routine misses one event the next cycle catches it)
  device:set_field(constants.FIELD_OPERATING_STATE, desired_state)
  if caps.operating_state then
    device:emit_event(caps.operating_state.thermostatOperatingState(
      { value = desired_state }, { state_change = true }))
  end

  -- Emit status text
  if caps.status_text then
    device:emit_event(caps.status_text.statusText({
      value = build_status(device, desired_state, active_setpoint)
    }))
  end
end

return thermostat_logic
