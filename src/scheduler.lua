-- MasterStat Scheduler
-- Two-period day/night temperature setback schedule

local log = require "log"

local scheduler = {}

--- Determine if the current hour falls within the "day" period
-- Handles midnight wrap-around (e.g., day=6, night=22 → day is 6-21, night is 22-5)
-- @param hour number Current hour (0-23)
-- @param day_start number Day period start hour
-- @param night_start number Night period start hour
-- @return boolean true if currently in day period
local function is_day_period(hour, day_start, night_start)
  if day_start < night_start then
    -- Normal: day 6am to night 10pm
    return hour >= day_start and hour < night_start
  else
    -- Wrapped: e.g., day 22 to night 6 (night is the "shorter" period)
    return hour >= day_start or hour < night_start
  end
end

--- Get the effective setpoint based on the current schedule
-- @param device table SmartThings device object (for reading preferences)
-- @param mode string "heat" or "cool"
-- @return number|nil scheduled setpoint, or nil if schedule is disabled
function scheduler.get_effective_setpoint(device, mode)
  local enabled = device.preferences and device.preferences.scheduleEnabled
  if not enabled then
    return nil
  end

  local day_start = (device.preferences.dayStartHour or 6)
  local night_start = (device.preferences.nightStartHour or 22)
  local day_sp = device.preferences.daySetpoint or 72
  local night_sp = device.preferences.nightSetpoint or 65

  local current_hour = tonumber(os.date("%H"))

  if is_day_period(current_hour, day_start, night_start) then
    log.debug(string.format("scheduler: Day period (hour %d), setpoint %d", current_hour, day_sp))
    return day_sp
  else
    log.debug(string.format("scheduler: Night period (hour %d), setpoint %d", current_hour, night_sp))
    return night_sp
  end
end

return scheduler
