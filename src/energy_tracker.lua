-- MasterStat Energy Tracker
-- Tracks daily cumulative outlet runtime in minutes

local constants = require "constants"
local log = require "log"

local energy_tracker = {}

--- Check if a new day has started and reset the counter if so
-- @param device table SmartThings device object
local function check_daily_reset(device)
  local current_day = tonumber(os.date("%j"))
  local stored_day = device:get_field(constants.FIELD_ENERGY_DAY_OF_YEAR)

  if stored_day ~= current_day then
    log.info("energy_tracker: New day detected, resetting daily runtime counter")
    device:set_field(constants.FIELD_ENERGY_TODAY_MINS, 0)
    device:set_field(constants.FIELD_ENERGY_DAY_OF_YEAR, current_day)
  end
end

--- Accumulate runtime if outlet is currently on
-- Should be called every 60 seconds by the energy tracking timer
-- @param driver table SmartThings driver object
-- @param device table SmartThings device object
-- @param energy_cap table The energy tracking capability for emitting events
function energy_tracker.accumulate(driver, device, energy_cap)
  check_daily_reset(device)

  local outlet_on = device:get_field(constants.FIELD_OUTLET_ON)
  if not outlet_on then
    return
  end

  local current_mins = device:get_field(constants.FIELD_ENERGY_TODAY_MINS) or 0
  current_mins = current_mins + 1
  device:set_field(constants.FIELD_ENERGY_TODAY_MINS, current_mins)

  -- Emit the daily runtime event
  if energy_cap then
    device:emit_event(energy_cap.dailyRuntime({ value = current_mins, unit = "min" }))
  end

  log.debug(string.format("energy_tracker: Daily runtime = %d min", current_mins))
end

--- Get current daily runtime
-- @param device table SmartThings device object
-- @return number minutes of runtime today
function energy_tracker.get_daily_runtime(device)
  check_daily_reset(device)
  return device:get_field(constants.FIELD_ENERGY_TODAY_MINS) or 0
end

return energy_tracker
