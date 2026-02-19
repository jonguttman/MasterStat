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
local outdoor_temperature_cap = capabilities.build_cap_from_json_string(constants.OUTDOOR_TEMPERATURE_CAP)
local status_text_cap = capabilities.build_cap_from_json_string(constants.STATUS_TEXT_CAP)
local energy_tracking_cap = capabilities.build_cap_from_json_string(constants.ENERGY_TRACKING_CAP)

-- Standard capabilities
local temp_measurement = capabilities.temperatureMeasurement
local thermostat_mode = capabilities.thermostatMode
local heating_setpoint = capabilities.thermostatHeatingSetpoint
local cooling_setpoint = capabilities.thermostatCoolingSetpoint
local operating_state = capabilities.thermostatOperatingState

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
-- Capability command handlers
-- ============================================================

--- Handle temperature pushed from Routine via custom capability
local function handle_set_temperature(driver, device, command)
  local temp = command.args.temperature
  log.info(string.format("Received temperature: %.1f", temp))

  -- Store and emit as temperatureMeasurement for dashboard display
  device:set_field(constants.FIELD_CURRENT_TEMP, temp)
  device:set_field(constants.FIELD_LAST_TEMP_UPDATE, os.time())
  device:set_field(constants.FIELD_STALE_ALERT, false)

  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  device:emit_event(temp_measurement.temperature({ value = temp, unit = unit }))

  -- Feed trend tracker
  trend.add_reading(device, temp)

  -- Re-evaluate thermostat
  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle outdoor temperature pushed from Routine
local function handle_set_outdoor_temperature(driver, device, command)
  local temp = command.args.temperature
  log.info(string.format("Received outdoor temperature: %.1f", temp))

  device:set_field(constants.FIELD_OUTDOOR_TEMP, temp)

  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  device:emit_event(outdoor_temperature_cap.outdoorTemperature({ value = temp, unit = unit }))

  -- Re-evaluate (outdoor temp may affect heating/cooling decisions)
  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle thermostat mode change
local function handle_set_thermostat_mode(driver, device, command)
  local mode = command.args.mode
  log.info(string.format("Thermostat mode set to: %s", mode))

  device:set_field(constants.FIELD_MODE, mode, { persist = true })
  device:emit_event(thermostat_mode.thermostatMode(mode))

  -- Reset auto action when mode changes
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")

  thermostat_logic.evaluate(driver, device, build_caps())
end

--- Handle individual mode commands (setThermostatMode shortcuts)
local function handle_heat(driver, device, command)
  device:set_field(constants.FIELD_MODE, "heat", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.heat())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_cool(driver, device, command)
  device:set_field(constants.FIELD_MODE, "cool", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.cool())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_auto(driver, device, command)
  device:set_field(constants.FIELD_MODE, "auto", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.auto())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
  thermostat_logic.evaluate(driver, device, build_caps())
end

local function handle_off(driver, device, command)
  device:set_field(constants.FIELD_MODE, "off", { persist = true })
  device:emit_event(thermostat_mode.thermostatMode.off())
  device:set_field(constants.FIELD_AUTO_ACTION, "idle")
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

  -- Emit initial states
  device:emit_event(temp_measurement.temperature({ value = 0, unit = unit }))
  device:emit_event(thermostat_mode.thermostatMode.off())
  device:emit_event(operating_state.thermostatOperatingState.idle())
  device:emit_event(heating_setpoint.heatingSetpoint({ value = constants.DEFAULT_HEAT_SETPOINT, unit = unit }))
  device:emit_event(cooling_setpoint.coolingSetpoint({ value = constants.DEFAULT_COOL_SETPOINT, unit = unit }))
  device:emit_event(status_text_cap.statusText({ value = "Waiting for temperature reading..." }))
  device:emit_event(energy_tracking_cap.dailyRuntime({ value = 0, unit = "min" }))
  device:emit_event(set_temperature_cap.temperature({ value = 0, unit = unit }))
  device:emit_event(outdoor_temperature_cap.outdoorTemperature({ value = 0, unit = unit }))

  device:emit_event(thermostat_mode.supportedThermostatModes({
    "off", "heat", "cool", "auto"
  }))
end

--- Device init — restore persisted fields and start timers
local function device_init(driver, device)
  log.info("MasterStat device init: " .. device.id)

  -- Conservative defaults for transient state after reboot
  if device:get_field(constants.FIELD_OUTLET_ON) == nil then
    device:set_field(constants.FIELD_OUTLET_ON, false)
  end
  if device:get_field(constants.FIELD_STALE_ALERT) == nil then
    device:set_field(constants.FIELD_STALE_ALERT, false)
  end

  -- Re-emit persisted state so the app UI is correct after restart
  local unit = pref(device, "tempUnit", constants.DEFAULT_TEMP_UNIT)
  local heat_sp = device:get_field(constants.FIELD_HEAT_SETPOINT) or constants.DEFAULT_HEAT_SETPOINT
  local cool_sp = device:get_field(constants.FIELD_COOL_SETPOINT) or constants.DEFAULT_COOL_SETPOINT
  local mode = device:get_field(constants.FIELD_MODE) or "off"

  device:emit_event(heating_setpoint.heatingSetpoint({ value = heat_sp, unit = unit }))
  device:emit_event(cooling_setpoint.coolingSetpoint({ value = cool_sp, unit = unit }))
  device:emit_event(thermostat_mode.thermostatMode(mode))
  device:emit_event(operating_state.thermostatOperatingState.idle())
  device:emit_event(status_text_cap.statusText({ value = "Waiting for temperature reading..." }))

  -- Timer 1: Periodic evaluation (every 30s)
  device.thread:call_on_schedule(constants.EVAL_INTERVAL, function()
    thermostat_logic.evaluate(driver, device, build_caps())
  end, "eval_timer")

  -- Timer 2: Energy tracking (every 60s)
  device.thread:call_on_schedule(constants.ENERGY_TRACK_INTERVAL, function()
    energy_tracker.accumulate(driver, device, energy_tracking_cap)
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
  },
})

log.info("Starting MasterStat Virtual Thermostat driver")
masterstat_driver:run()
