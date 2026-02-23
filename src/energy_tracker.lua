-- MasterStat Energy Tracker
-- Tracks daily runtime (total, heating, cooling), cycle counts, and comfort efficiency

local constants = require "constants"
local log = require "log"

local energy_tracker = {}

--- Helper: format minutes as human-readable "Xh Ym" or "Xm"
local function format_mins(mins)
  if mins <= 0 then return "0m" end
  local h = math.floor(mins / 60)
  local m = mins % 60
  if h > 0 then
    return string.format("%dh %dm", h, m)
  else
    return string.format("%dm", m)
  end
end

--- Helper: get preference with fallback
local function pref(device, key, default)
  if device.preferences and device.preferences[key] ~= nil then
    return device.preferences[key]
  end
  return default
end

--- Check if a new day has started and reset all counters if so
-- @param device table SmartThings device object
local function check_daily_reset(device)
  local current_day = tonumber(os.date("%j"))
  local stored_day = device:get_field(constants.FIELD_ENERGY_DAY_OF_YEAR)

  if stored_day ~= current_day then
    log.info("energy_tracker: New day detected, resetting all counters")
    device:set_field(constants.FIELD_ENERGY_TODAY_MINS, 0)
    device:set_field(constants.FIELD_HEAT_MINS_TODAY, 0)
    device:set_field(constants.FIELD_COOL_MINS_TODAY, 0)
    device:set_field(constants.FIELD_CYCLES_TODAY, 0)
    device:set_field(constants.FIELD_COMFORT_MINS_TODAY, 0)
    device:set_field(constants.FIELD_TRACKED_MINS_TODAY, 0)
    device:set_field(constants.FIELD_LAST_TRACKED_STATE, "idle")
    device:set_field(constants.FIELD_ENERGY_DAY_OF_YEAR, current_day)
  end
end

--- Accumulate runtime, cycle counts, and comfort tracking
-- Called every 60 seconds by the energy tracking timer
-- @param driver table SmartThings driver object
-- @param device table SmartThings device object
-- @param energy_cap table The energy tracking capability (dailyRuntime)
-- @param details_cap table The energy details capability (heatingRuntime, coolingRuntime, dailyCycles, efficiency)
-- @param summary_cap table The energy summary capability (runtimeSummary, costSummary, efficiencySummary)
function energy_tracker.accumulate(driver, device, energy_cap, details_cap, summary_cap)
  check_daily_reset(device)

  -- Always increment tracked minutes (denominator for efficiency)
  local tracked_mins = (device:get_field(constants.FIELD_TRACKED_MINS_TODAY) or 0) + 1
  device:set_field(constants.FIELD_TRACKED_MINS_TODAY, tracked_mins)

  -- Read current operating state
  local op_state = device:get_field(constants.FIELD_OPERATING_STATE) or "idle"
  local prev_state = device:get_field(constants.FIELD_LAST_TRACKED_STATE) or "idle"

  -- Detect state transitions for cycle counting
  local cycles = device:get_field(constants.FIELD_CYCLES_TODAY) or 0
  local was_idle = (prev_state == "idle")
  local now_active = (op_state == "heating" or op_state == "cooling")
  if was_idle and now_active then
    cycles = cycles + 1
    device:set_field(constants.FIELD_CYCLES_TODAY, cycles)
  end
  device:set_field(constants.FIELD_LAST_TRACKED_STATE, op_state)

  -- Accumulate heating or cooling minutes
  local heat_mins = device:get_field(constants.FIELD_HEAT_MINS_TODAY) or 0
  local cool_mins = device:get_field(constants.FIELD_COOL_MINS_TODAY) or 0
  local total_mins = device:get_field(constants.FIELD_ENERGY_TODAY_MINS) or 0

  if op_state == "heating" then
    heat_mins = heat_mins + 1
    total_mins = total_mins + 1
    device:set_field(constants.FIELD_HEAT_MINS_TODAY, heat_mins)
    device:set_field(constants.FIELD_ENERGY_TODAY_MINS, total_mins)
  elseif op_state == "cooling" then
    cool_mins = cool_mins + 1
    total_mins = total_mins + 1
    device:set_field(constants.FIELD_COOL_MINS_TODAY, cool_mins)
    device:set_field(constants.FIELD_ENERGY_TODAY_MINS, total_mins)
  end

  -- Comfort tracking: is current temp within deadband of active setpoint?
  local comfort_mins = device:get_field(constants.FIELD_COMFORT_MINS_TODAY) or 0
  local current_temp = device:get_field(constants.FIELD_CURRENT_TEMP)
  local mode = device:get_field(constants.FIELD_MODE) or "off"
  local deadband_raw = tonumber(pref(device, "deadband", 20)) or 20
  local deadband = deadband_raw / 10

  if current_temp and mode ~= "off" then
    local at_comfort = false
    if mode == "heat" then
      local heat_sp = device:get_field(constants.FIELD_HEAT_SETPOINT) or constants.DEFAULT_HEAT_SETPOINT
      at_comfort = math.abs(current_temp - heat_sp) <= deadband
    elseif mode == "cool" then
      local cool_sp = device:get_field(constants.FIELD_COOL_SETPOINT) or constants.DEFAULT_COOL_SETPOINT
      at_comfort = math.abs(current_temp - cool_sp) <= deadband
    elseif mode == "auto" then
      local heat_sp = device:get_field(constants.FIELD_HEAT_SETPOINT) or constants.DEFAULT_HEAT_SETPOINT
      local cool_sp = device:get_field(constants.FIELD_COOL_SETPOINT) or constants.DEFAULT_COOL_SETPOINT
      at_comfort = current_temp >= (heat_sp - deadband) and current_temp <= (cool_sp + deadband)
    end
    if at_comfort then
      comfort_mins = comfort_mins + 1
      device:set_field(constants.FIELD_COMFORT_MINS_TODAY, comfort_mins)
    end
  end

  -- Calculate efficiency percentage
  local efficiency = 0
  if tracked_mins > 0 then
    efficiency = math.floor(comfort_mins / tracked_mins * 100 + 0.5)
  end

  -- Emit dailyRuntime on original capability (backward compat)
  if energy_cap then
    device:emit_event(energy_cap.dailyRuntime({ value = total_mins, unit = "min" }))
  end

  -- Emit detailed attributes on new capability
  if details_cap then
    device:emit_event(details_cap.heatingRuntime({ value = heat_mins, unit = "min" }))
    device:emit_event(details_cap.coolingRuntime({ value = cool_mins, unit = "min" }))
    device:emit_event(details_cap.dailyCycles({ value = cycles }))
    device:emit_event(details_cap.efficiency({ value = efficiency, unit = "%" }))
  end

  log.debug(string.format(
    "energy_tracker: total=%dm heat=%dm cool=%dm cycles=%d comfort=%dm/%dm eff=%d%%",
    total_mins, heat_mins, cool_mins, cycles, comfort_mins, tracked_mins, efficiency
  ))

  -- Emit formatted summary strings
  if summary_cap then
    -- Runtime summary
    local runtime_str
    if total_mins == 0 then
      runtime_str = "No runtime today"
    elseif heat_mins > 0 and cool_mins > 0 then
      runtime_str = string.format("Heat: %s | Cool: %s | Total: %s",
        format_mins(heat_mins), format_mins(cool_mins), format_mins(total_mins))
    elseif heat_mins > 0 then
      runtime_str = string.format("Heat: %s (total)", format_mins(heat_mins))
    else
      runtime_str = string.format("Cool: %s (total)", format_mins(cool_mins))
    end

    -- Cost summary
    local wattage = tonumber(pref(device, "heaterWattage", 1500)) or 1500
    local rate_cents = tonumber(pref(device, "electricityRate", 15)) or 15
    local cost = (total_mins / 60) * (wattage / 1000) * (rate_cents / 100)
    local cost_str
    if cycles > 0 then
      local avg_cycle = math.floor(total_mins / cycles + 0.5)
      cost_str = string.format("Est. cost: $%.2f | Avg cycle: %s", cost, format_mins(avg_cycle))
    else
      cost_str = string.format("Est. cost: $%.2f | No cycles", cost)
    end

    -- Efficiency summary
    local eff_str
    if tracked_mins < 2 then
      eff_str = string.format("Comfort: --%% | %d cycles today", cycles)
    else
      eff_str = string.format("Comfort: %d%% | %d cycles today", efficiency, cycles)
    end

    device:emit_event(summary_cap.runtimeSummary({ value = runtime_str }))
    device:emit_event(summary_cap.costSummary({ value = cost_str }))
    device:emit_event(summary_cap.efficiencySummary({ value = eff_str }))
  end
end

--- Get current daily runtime
-- @param device table SmartThings device object
-- @return number minutes of runtime today
function energy_tracker.get_daily_runtime(device)
  check_daily_reset(device)
  return device:get_field(constants.FIELD_ENERGY_TODAY_MINS) or 0
end

return energy_tracker
