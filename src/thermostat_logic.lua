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

  local max_runtime = pref(device, "maxRuntime", constants.DEFAULT_MAX_RUNTIME)
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
  local last_update = device:get_field(constants.FIELD_LAST_TEMP_UPDATE)
  if not last_update then
    -- No temp ever received — don't flag stale until we've had at least one reading
    return false
  end

  local timeout = pref(device, "staleTempTimeout", constants.DEFAULT_STALE_TEMP_TIMEOUT)
  local elapsed_mins = (os.time() - last_update) / 60

  if elapsed_mins >= timeout then
    log.warn(string.format("SAFETY: Stale temperature (%.0f min since last update, timeout=%d min)",
      elapsed_mins, timeout))
    return true
  end
  return false
end

-- ============================================================
-- Min cycle time enforcement
-- ============================================================
local function can_change_state(device)
  local last_change = device:get_field(constants.FIELD_LAST_STATE_CHANGE)
  if not last_change then
    return true
  end

  local min_cycle = pref(device, "minCycleTime", constants.DEFAULT_MIN_CYCLE_TIME)
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
-- Set outlet state (track state; Routine mirrors operating state to outlet)
-- ============================================================
local function set_outlet(driver, device, on)
  local current = device:get_field(constants.FIELD_OUTLET_ON) or false
  if on == current then
    return  -- no change needed
  end

  if not can_change_state(device) then
    return  -- respect min cycle time
  end

  device:set_field(constants.FIELD_OUTLET_ON, on)
  device:set_field(constants.FIELD_LAST_STATE_CHANGE, os.time())
  if on then
    device:set_field(constants.FIELD_OUTLET_ON_SINCE, os.time())
  else
    device:set_field(constants.FIELD_OUTLET_ON_SINCE, nil)
  end
  log.info(string.format("thermostat_logic: Outlet state → %s (Routine controls physical outlet)", on and "ON" or "OFF"))
end

-- ============================================================
-- Build status text
-- ============================================================
local function build_status(device, state, setpoint)
  local temp = device:get_field(constants.FIELD_CURRENT_TEMP)
  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  local stale = device:get_field(constants.FIELD_STALE_ALERT)

  if stale then
    return "ALERT: Stale temperature — outlet OFF for safety"
  end

  if not temp then
    return "Waiting for temperature reading..."
  end

  if state == "heating" then
    return string.format("Heating to %d%s%s (current: %.1f%s%s)",
      setpoint, "\194\176", unit, temp, "\194\176", unit)
  elseif state == "cooling" then
    return string.format("Cooling to %d%s%s (current: %.1f%s%s)",
      setpoint, "\194\176", unit, temp, "\194\176", unit)
  else
    return string.format("Idle at %.1f%s%s (setpoint: %d%s%s)",
      temp, "\194\176", unit, setpoint, "\194\176", unit)
  end
end

-- ============================================================
-- Main evaluation function
-- Called on every temp update + periodically by timer
-- ============================================================
function thermostat_logic.evaluate(driver, device, caps)
  local mode = device:get_field(constants.FIELD_MODE) or "off"
  local temp = device:get_field(constants.FIELD_CURRENT_TEMP)
  local outlet_on = device:get_field(constants.FIELD_OUTLET_ON) or false
  local deadband = pref(device, "deadband", constants.DEFAULT_DEADBAND)

  -- Off mode: ensure outlet is off
  if mode == "off" then
    if outlet_on then
      set_outlet(driver, device, false)
    end
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState.idle())
    end
    device:set_field(constants.FIELD_OPERATING_STATE, "idle")
    if caps.status_text then
      device:emit_event(caps.status_text.statusText({ value = "Off" }))
    end
    return
  end

  -- Safety: stale temperature
  if check_stale_temp(device) then
    device:set_field(constants.FIELD_STALE_ALERT, true)
    if outlet_on then
      set_outlet(driver, device, false)
    end
    local state = "idle"
    device:set_field(constants.FIELD_OPERATING_STATE, state)
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState.idle())
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

  -- Safety: max runtime
  if check_max_runtime(device) then
    set_outlet(driver, device, false)
    local state = "idle"
    device:set_field(constants.FIELD_OPERATING_STATE, state)
    if caps.operating_state then
      device:emit_event(caps.operating_state.thermostatOperatingState.idle())
    end
    if caps.status_text then
      device:emit_event(caps.status_text.statusText({
        value = "SAFETY: Max runtime exceeded — outlet OFF"
      }))
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

    if should_skip_for_outdoor(device, "heat", heat_sp) then
      -- Don't heat
    elseif auto_action == "heating" and temp < heat_sp then
      desired_state = "heating"
      active_setpoint = heat_sp
    elseif temp < (heat_sp - deadband + heat_offset) then
      desired_state = "heating"
      active_setpoint = heat_sp
    end

    if desired_state == "idle" then
      if should_skip_for_outdoor(device, "cool", cool_sp) then
        -- Don't cool
      elseif auto_action == "cooling" and temp > cool_sp then
        desired_state = "cooling"
        active_setpoint = cool_sp
      elseif temp > (cool_sp + deadband - cool_offset) then
        desired_state = "cooling"
        active_setpoint = cool_sp
      end
    end

    if desired_state == "idle" then
      active_setpoint = heat_sp  -- show heat setpoint when idle in auto
    end

    device:set_field(constants.FIELD_AUTO_ACTION, desired_state)
  end

  -- Apply desired state
  local want_on = (desired_state == "heating" or desired_state == "cooling")
  set_outlet(driver, device, want_on)

  -- Emit operating state
  device:set_field(constants.FIELD_OPERATING_STATE, desired_state)
  if caps.operating_state then
    if desired_state == "heating" then
      device:emit_event(caps.operating_state.thermostatOperatingState.heating())
    elseif desired_state == "cooling" then
      device:emit_event(caps.operating_state.thermostatOperatingState.cooling())
    else
      device:emit_event(caps.operating_state.thermostatOperatingState.idle())
    end
  end

  -- Emit status text
  if caps.status_text then
    device:emit_event(caps.status_text.statusText({
      value = build_status(device, desired_state, active_setpoint)
    }))
  end
end

return thermostat_logic
