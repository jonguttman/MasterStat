-- MasterStat Virtual Thermostat — SmartThings Edge Driver
-- Controls a Sonoff S31 Lite ZB outlet based on Cielo Breez Plus temperature readings

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local constants = require "constants"
local thermostat_logic = require "thermostat_logic"
local trend = require "trend"
local energy_tracker = require "energy_tracker"

-- ============================================================
-- Register custom capabilities from embedded JSON
-- ============================================================
local set_temperature_cap = capabilities.build_cap_from_json_string(constants.SET_TEMPERATURE_CAP)
local set_temperature_2_cap = capabilities.build_cap_from_json_string(constants.SET_TEMPERATURE_2_CAP)
local outdoor_temperature_cap = capabilities.build_cap_from_json_string(constants.OUTDOOR_TEMPERATURE_CAP)
local status_text_cap = capabilities.build_cap_from_json_string(constants.STATUS_TEXT_CAP)
local energy_tracking_cap = capabilities.build_cap_from_json_string(constants.ENERGY_TRACKING_CAP)
local energy_details_cap = capabilities.build_cap_from_json_string(constants.ENERGY_DETAILS_CAP)
local energy_summary_cap = capabilities.build_cap_from_json_string(constants.ENERGY_SUMMARY_CAP)

-- Standard capabilities
local temp_measurement = capabilities.temperatureMeasurement
local thermostat_mode = capabilities.thermostatMode
local heating_setpoint = capabilities.thermostatHeatingSetpoint
local cooling_setpoint = capabilities.thermostatCoolingSetpoint
local operating_state = capabilities.thermostatOperatingState
local switch_cap = capabilities.switch

-- Caps table passed to thermostat_logic
local function build_caps()
  return {
    operating_state = operating_state,
    status_text = status_text_cap,
  }
end

-- ============================================================
-- Helper: get preference with fallback
-- ============================================================
local function pref(device, key, default)
  if device.preferences and device.preferences[key] ~= nil then
    return device.preferences[key]
  end
  return default
end

-- ============================================================
-- Temperature input validation
-- ============================================================
local function validate_temperature(temp, source_label)
  if type(temp) ~= "number" then
    log.warn(string.format("REJECTED: Non-numeric temperature from %s: %s", source_label, tostring(temp)))
    return false
  end
  -- Valid range: 0–150°F / -18–66°C — reject anything outside
  if temp < -18 or temp > 150 then
    log.warn(string.format("REJECTED: Temperature %.1f from %s out of valid range (-18 to 150)", temp, source_label))
    return false
  end
  return true
end

-- ============================================================
-- Temperature averaging: compute from fresh sources
-- ============================================================
local function compute_averaged_temp(device)
  local now = os.time()
  local timeout = (tonumber(pref(device, "staleTempTimeout", constants.DEFAULT_STALE_TEMP_TIMEOUT)) or constants.DEFAULT_STALE_TEMP_TIMEOUT) * 60

  local t1 = device:get_field(constants.FIELD_TEMP1)
  local t1_time = device:get_field(constants.FIELD_TEMP1_TIME)

  -- Respect secondary sensor toggle
  local secondary_enabled = pref(device, "secondarySensorEnabled", true)
  local t2 = secondary_enabled and device:get_field(constants.FIELD_TEMP2) or nil
  local t2_time = secondary_enabled and device:get_field(constants.FIELD_TEMP2_TIME) or nil

  local t1_fresh = t1 and t1_time and (now - t1_time) < timeout
  local t2_fresh = t2 and t2_time and (now - t2_time) < timeout

  if t1_fresh and t2_fresh then
    return (t1 + t2) / 2
  elseif t1_fresh then
    return t1
  elseif t2_fresh then
    return t2
  end
  return nil  -- both stale
end

local function update_temperature(driver, device, source_label)
  local avg = compute_averaged_temp(device)
  if avg then
    device:set_field(constants.FIELD_CURRENT_TEMP, avg, { persist = true })
    device:set_field(constants.FIELD_LAST_TEMP_UPDATE, os.time(), { persist = true })
    device:set_field(constants.FIELD_STALE_ALERT, false)

    local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
    device:emit_event(temp_measurement.temperature({ value = avg, unit = unit }))
    log.info(string.format("Temperature updated (via %s): avg=%.1f", source_label, avg))

    trend.add_reading(device, avg)
  end

  thermostat_logic.evaluate(driver, device, build_caps())
end

-- ============================================================
-- Capability command handlers
-- ============================================================

--- Handle temperature pushed from Cielo (primary) via custom capability
local function handle_set_temperature(driver, device, command)
  local temp = command.args.temperature
  if not validate_temperature(temp, "Cielo") then return end
  log.info(string.format("Received primary temperature (Cielo): %.1f", temp))

  device:set_field(constants.FIELD_TEMP1, temp, { persist = true })
  device:set_field(constants.FIELD_TEMP1_TIME, os.time(), { persist = true })

  update_temperature(driver, device, "Cielo")
end

--- Handle temperature pushed from Mysa (secondary) via custom capability
local function handle_set_temperature_2(driver, device, command)
  local temp = command.args.temperature
  if not validate_temperature(temp, "Mysa") then return end
  log.info(string.format("Received secondary temperature (Mysa): %.1f", temp))

  device:set_field(constants.FIELD_TEMP2, temp, { persist = true })
  device:set_field(constants.FIELD_TEMP2_TIME, os.time(), { persist = true })

  update_temperature(driver, device, "Mysa")
end

--- Handle outdoor temperature pushed from Routine
local function handle_set_outdoor_temperature(driver, device, command)
  local temp = command.args.temperature
  if not validate_temperature(temp, "outdoor") then return end
  log.info(string.format("Received outdoor temperature: %.1f", temp))

  device:set_field(constants.FIELD_OUTDOOR_TEMP, temp)

  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  device:emit_event(outdoor_temperature_cap.outdoorTemperature({ value = temp, unit = unit }))

  -- Re-evaluate (outdoor temp may affect heating/cooling decisions)
  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle thermostat mode change
local function clear_lockout(device)
  if device:get_field(constants.FIELD_MAX_RUNTIME_LOCKOUT) then
    log.info("Clearing max runtime lockout")
    device:set_field(constants.FIELD_MAX_RUNTIME_LOCKOUT, nil, { persist = true })
  end
end

local function handle_set_thermostat_mode(driver, device, command)
  local mode = command.args.mode
  log.info(string.format("Thermostat mode set to: %s", mode))

  device:set_field(constants.FIELD_MODE, mode, { persist = true })
  device:emit_event(thermostat_mode.thermostatMode(mode))

  if mode ~= "off" then
    device:set_field(constants.FIELD_LAST_MODE, mode, { persist = true })
    device:emit_event(switch_cap.switch.on())
  else
    device:emit_event(switch_cap.switch.off())
  end

  -- Reset auto action when mode changes
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)

  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle individual mode commands (setThermostatMode shortcuts)
local function handle_heat(driver, device, command)
  device:set_field(constants.FIELD_MODE, "heat", { persist = true })
  device:set_field(constants.FIELD_LAST_MODE, "heat", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.heat())
  device:emit_event(switch_cap.switch.on())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_cool(driver, device, command)
  device:set_field(constants.FIELD_MODE, "cool", { persist = true })
  device:set_field(constants.FIELD_LAST_MODE, "cool", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.cool())
  device:emit_event(switch_cap.switch.on())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_auto(driver, device, command)
  device:set_field(constants.FIELD_MODE, "auto", { persist = true })
  device:set_field(constants.FIELD_LAST_MODE, "auto", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.auto())
  device:emit_event(switch_cap.switch.on())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_off(driver, device, command)
  device:set_field(constants.FIELD_MODE, "off", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.off())
  device:emit_event(switch_cap.switch.off())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)
  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle switch on/off (power button in SmartThings app)
local function handle_switch_on(driver, device, command)
  local last_mode = device:get_field(constants.FIELD_LAST_MODE) or "heat"
  log.info(string.format("Switch ON — restoring mode to: %s", last_mode))
  device:set_field(constants.FIELD_MODE, last_mode, { persist = true })
  device:emit_event(thermostat_mode.thermostatMode(last_mode))
  device:emit_event(switch_cap.switch.on())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_switch_off(driver, device, command)
  log.info("Switch OFF — setting mode to off")
  device:set_field(constants.FIELD_MODE, "off", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.off())
  device:emit_event(switch_cap.switch.off())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  clear_lockout(device)
  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle heating setpoint change
--- SmartThings delivers standard thermostat setpoints in Celsius; convert to user unit
local function handle_set_heating_setpoint(driver, device, command)
  local setpoint = command.args.setpoint
  local unit = pref(device, "tempUnit", "F")
  if unit == "F" then
    setpoint = (setpoint * 9 / 5) + 32
  end
  setpoint = math.floor(setpoint + 0.5)  -- round to integer
  log.info(string.format("Heating setpoint set to: %d°%s (raw: %.2f°C)", setpoint, unit, command.args.setpoint))

  device:set_field(constants.FIELD_HEAT_SETPOINT, setpoint, { persist = true })
  device:emit_event(heating_setpoint.heatingSetpoint({ value = setpoint, unit = unit }))
  clear_lockout(device)

  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle cooling setpoint change
--- SmartThings delivers standard thermostat setpoints in Celsius; convert to user unit
local function handle_set_cooling_setpoint(driver, device, command)
  local setpoint = command.args.setpoint
  local unit = pref(device, "tempUnit", "F")
  if unit == "F" then
    setpoint = (setpoint * 9 / 5) + 32
  end
  setpoint = math.floor(setpoint + 0.5)  -- round to integer
  log.info(string.format("Cooling setpoint set to: %d°%s (raw: %.2f°C)", setpoint, unit, command.args.setpoint))

  device:set_field(constants.FIELD_COOL_SETPOINT, setpoint, { persist = true })
  device:emit_event(cooling_setpoint.coolingSetpoint({ value = setpoint, unit = unit }))
  clear_lockout(device)

  thermostat_logic.evaluate(driver, device, build_caps())
end

-- ============================================================
-- Lifecycle handlers
-- ============================================================

--- Device added — initialize all fields and emit initial states
local function device_added(driver, device)
  log.info("MasterStat device added: " .. device.id)

  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)

  -- Initialize fields (setpoints will be relayed from Cielo thermostat via Rules)
  device:set_field(constants.FIELD_MODE, "off", { persist = true })
  device:set_field(constants.FIELD_HEAT_SETPOINT, constants.DEFAULT_HEAT_SETPOINT, { persist = true })
  device:set_field(constants.FIELD_COOL_SETPOINT, constants.DEFAULT_COOL_SETPOINT, { persist = true })
  device:set_field(constants.FIELD_OUTLET_ON, false)
  device:set_field(constants.FIELD_STALE_ALERT, false)
  device:set_field(constants.FIELD_ENERGY_TODAY_MINS, 0)
  device:set_field(constants.FIELD_ENERGY_DAY_OF_YEAR, tonumber(os.date("%j")))
  device:set_field(constants.FIELD_HEAT_MINS_TODAY, 0)
  device:set_field(constants.FIELD_COOL_MINS_TODAY, 0)
  device:set_field(constants.FIELD_CYCLES_TODAY, 0)
  device:set_field(constants.FIELD_LAST_TRACKED_STATE, "idle")
  device:set_field(constants.FIELD_COMFORT_MINS_TODAY, 0)
  device:set_field(constants.FIELD_TRACKED_MINS_TODAY, 0)

  -- Emit initial states
  device:emit_event(temp_measurement.temperature({ value = 0, unit = unit }))
  device:emit_event(thermostat_mode.thermostatMode.off())
  device:emit_event(operating_state.thermostatOperatingState.idle())
  device:emit_event(heating_setpoint.heatingSetpoint({ value = constants.DEFAULT_HEAT_SETPOINT, unit = unit }))
  device:emit_event(cooling_setpoint.coolingSetpoint({ value = constants.DEFAULT_COOL_SETPOINT, unit = unit }))
  device:emit_event(status_text_cap.statusText({ value = "Waiting for temperature reading..." }))
  device:emit_event(energy_tracking_cap.dailyRuntime({ value = 0, unit = "min" }))
  device:emit_event(energy_details_cap.heatingRuntime({ value = 0, unit = "min" }))
  device:emit_event(energy_details_cap.coolingRuntime({ value = 0, unit = "min" }))
  device:emit_event(energy_details_cap.dailyCycles({ value = 0 }))
  device:emit_event(energy_details_cap.efficiency({ value = 0, unit = "%" }))
  device:emit_event(energy_summary_cap.runtimeSummary({ value = "No runtime today" }))
  device:emit_event(energy_summary_cap.costSummary({ value = "Est. cost: $0.00 | No cycles" }))
  device:emit_event(energy_summary_cap.efficiencySummary({ value = "Comfort: --% | 0 cycles today" }))
  device:emit_event(set_temperature_cap.temperature({ value = 0, unit = unit }))
  device:emit_event(set_temperature_2_cap.temperature({ value = 0, unit = unit }))
  device:emit_event(outdoor_temperature_cap.outdoorTemperature({ value = 0, unit = unit }))

  device:emit_event(switch_cap.switch.off())

  device:emit_event(thermostat_mode.supportedThermostatModes({
    "off", "heat", "cool", "auto"
  }))
end

--- Device init — restore persisted fields and start timers
local function device_init(driver, device)
  log.info("MasterStat device init: " .. device.id)

  -- Force profile refresh so existing devices pick up new capabilities (e.g. switch)
  device:try_update_metadata({ profile = "virtual-thermostat" })

  -- Startup safety: force outlet OFF regardless of persisted state
  device:set_field(constants.FIELD_OUTLET_ON, false, { persist = true })
  device:set_field(constants.FIELD_STALE_ALERT, false)
  device:set_field(constants.FIELD_STARTUP_LOCKOUT, true)

  -- Re-emit persisted state so the app UI is correct after restart
  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  local heat_sp = device:get_field(constants.FIELD_HEAT_SETPOINT) or constants.DEFAULT_HEAT_SETPOINT
  local cool_sp = device:get_field(constants.FIELD_COOL_SETPOINT) or constants.DEFAULT_COOL_SETPOINT
  local mode = device:get_field(constants.FIELD_MODE) or "off"

  device:emit_event(heating_setpoint.heatingSetpoint({ value = heat_sp, unit = unit }))
  device:emit_event(cooling_setpoint.coolingSetpoint({ value = cool_sp, unit = unit }))
  device:emit_event(thermostat_mode.thermostatMode(mode))
  device:emit_event(mode ~= "off" and switch_cap.switch.on() or switch_cap.switch.off())
  -- Emit idle so the "idle" Routine fires and turns off the physical outlet
  device:emit_event(operating_state.thermostatOperatingState(
    { value = "idle" }, { state_change = true }))

  -- Re-emit persisted temperature so UI is correct and evaluate() has data
  local persisted_temp = device:get_field(constants.FIELD_CURRENT_TEMP)
  if persisted_temp then
    device:emit_event(temp_measurement.temperature({ value = persisted_temp, unit = unit }))
    log.info(string.format("Restored persisted temperature: %.1f°%s", persisted_temp, unit))
  end

  device:emit_event(status_text_cap.statusText({ value = "Starting up — waiting 60s before first evaluation..." }))

  -- Timer 1: Periodic evaluation (every 30s) — delayed start by STARTUP_DELAY_SEC
  -- Gives the "idle" Routine time to turn off the physical outlet before any heating logic runs
  device.thread:call_with_delay(constants.STARTUP_DELAY_SEC, function()
    log.info("MasterStat startup delay complete — clearing lockout, starting eval timer")
    device:set_field(constants.FIELD_STARTUP_LOCKOUT, nil)
    device.thread:call_on_schedule(constants.EVAL_INTERVAL, function()
      local ok, err = pcall(thermostat_logic.evaluate, driver, device, build_caps())
      if not ok then
        log.error(string.format("CRITICAL: evaluate() error: %s — forcing outlet OFF", tostring(err)))
        device:set_field(constants.FIELD_OUTLET_ON, false, { persist = true })
        device:set_field(constants.FIELD_OPERATING_STATE, "idle")
        device:emit_event(operating_state.thermostatOperatingState(
          { value = "idle" }, { state_change = true }))
      end
    end, "eval_timer")
  end, "eval_delay")

  -- Timer 2: Energy tracking (every 60s) — starts immediately (not safety-critical)
  device.thread:call_on_schedule(constants.ENERGY_TRACK_INTERVAL, function()
    local ok, err = pcall(energy_tracker.accumulate, driver, device, energy_tracking_cap, energy_details_cap, energy_summary_cap)
    if not ok then
      log.error(string.format("energy_tracker error: %s", tostring(err)))
    end
  end, "energy_timer")
end

--- Device removed — cleanup
local function device_removed(driver, device)
  log.info("MasterStat device removed: " .. device.id)
end

--- Preferences changed — re-evaluate
local function info_changed(driver, device, event, args)
  log.info("MasterStat preferences changed")

  -- Re-emit setpoints if they may have changed via defaults
  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  local heat_sp = device:get_field(constants.FIELD_HEAT_SETPOINT) or constants.DEFAULT_HEAT_SETPOINT
  local cool_sp = device:get_field(constants.FIELD_COOL_SETPOINT) or constants.DEFAULT_COOL_SETPOINT
  device:emit_event(heating_setpoint.heatingSetpoint({ value = heat_sp, unit = unit }))
  device:emit_event(cooling_setpoint.coolingSetpoint({ value = cool_sp, unit = unit }))

  thermostat_logic.evaluate(driver, device, build_caps())
end

-- ============================================================
-- Discovery handler — creates virtual LAN device
-- ============================================================
local function discovery_handler(driver, opts, cons)
  log.info("MasterStat discovery started")

  -- Check if device already exists (idempotent)
  local devices = driver:get_devices()
  if #devices > 0 then
    log.info("MasterStat device already exists, skipping creation")
    return
  end

  local device_info = {
    type = "LAN",
    device_network_id = "masterstat-virtual-thermostat",
    label = "MasterStat Thermostat",
    profile = "virtual-thermostat",
    manufacturer = "MasterStat",
    model = "v1",
    vendor_provided_label = "MasterStat Virtual Thermostat",
  }

  local success, msg = driver:try_create_device(device_info)
  if success then
    log.info("MasterStat virtual device created successfully")
  else
    log.error("Failed to create MasterStat device: " .. tostring(msg))
  end
end

-- ============================================================
-- Build and run the driver
-- ============================================================
local masterstat_driver = Driver("MasterStat", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    removed = device_removed,
    infoChanged = info_changed,
  },
  capability_handlers = {
    -- Custom capabilities
    [set_temperature_cap.ID] = {
      [set_temperature_cap.commands.setTemperature.NAME] = handle_set_temperature,
    },
    [set_temperature_2_cap.ID] = {
      [set_temperature_2_cap.commands.setTemperature.NAME] = handle_set_temperature_2,
    },
    [outdoor_temperature_cap.ID] = {
      [outdoor_temperature_cap.commands.setOutdoorTemperature.NAME] = handle_set_outdoor_temperature,
    },
    -- Standard thermostat capabilities
    [thermostat_mode.ID] = {
      [thermostat_mode.commands.setThermostatMode.NAME] = handle_set_thermostat_mode,
      [thermostat_mode.commands.heat.NAME] = handle_heat,
      [thermostat_mode.commands.cool.NAME] = handle_cool,
      [thermostat_mode.commands.auto.NAME] = handle_auto,
      [thermostat_mode.commands.off.NAME] = handle_off,
    },
    [heating_setpoint.ID] = {
      [heating_setpoint.commands.setHeatingSetpoint.NAME] = handle_set_heating_setpoint,
    },
    [cooling_setpoint.ID] = {
      [cooling_setpoint.commands.setCoolingSetpoint.NAME] = handle_set_cooling_setpoint,
    },
    [switch_cap.ID] = {
      [switch_cap.commands.on.NAME] = handle_switch_on,
      [switch_cap.commands.off.NAME] = handle_switch_off,
    },
  },
})

log.info("Starting MasterStat Virtual Thermostat driver")
masterstat_driver:run()
