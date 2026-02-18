-- MasterStat Trend Detection
-- Rolling window linear regression for temperature rate of change

local constants = require "constants"
local log = require "log"

local trend = {}

--- Add a temperature reading to the rolling window
-- @param device table SmartThings device object
-- @param temp number Current temperature
function trend.add_reading(device, temp)
  local readings = device:get_field(constants.FIELD_TREND_READINGS) or {}
  table.insert(readings, {
    temp = temp,
    time = os.time()
  })

  -- Keep only the last TREND_WINDOW_SIZE readings
  while #readings > constants.TREND_WINDOW_SIZE do
    table.remove(readings, 1)
  end

  device:set_field(constants.FIELD_TREND_READINGS, readings)
end

--- Calculate rate of temperature change using linear regression
-- @param readings table Array of {temp, time} entries
-- @return number rate of change in degrees per minute (positive = warming)
local function calc_rate(readings)
  if #readings < 3 then
    return 0
  end

  local n = #readings
  local sum_x, sum_y, sum_xy, sum_xx = 0, 0, 0, 0
  local base_time = readings[1].time

  for _, r in ipairs(readings) do
    local x = (r.time - base_time) / 60  -- minutes since first reading
    local y = r.temp
    sum_x = sum_x + x
    sum_y = sum_y + y
    sum_xy = sum_xy + (x * y)
    sum_xx = sum_xx + (x * x)
  end

  local denom = (n * sum_xx) - (sum_x * sum_x)
  if denom == 0 then
    return 0
  end

  local slope = ((n * sum_xy) - (sum_x * sum_y)) / denom
  return slope  -- degrees per minute
end

--- Get predictive offset to adjust trigger points
-- When temp is dropping fast, start heating earlier (positive offset added to heating threshold)
-- When temp is rising fast, start cooling earlier (positive offset subtracted from cooling threshold)
-- @param device table SmartThings device object
-- @param mode string "heat" or "cool"
-- @return number offset in degrees (0 to TREND_MAX_OFFSET)
function trend.get_predictive_offset(device, mode)
  local readings = device:get_field(constants.FIELD_TREND_READINGS)
  if not readings or #readings < 3 then
    return 0
  end

  local rate = calc_rate(readings)
  local offset = 0

  if mode == "heat" and rate < 0 then
    -- Temperature dropping → start heating earlier
    -- rate is negative (deg/min), convert to positive offset
    offset = math.min(math.abs(rate) * 10, constants.TREND_MAX_OFFSET)
  elseif mode == "cool" and rate > 0 then
    -- Temperature rising → start cooling earlier
    offset = math.min(rate * 10, constants.TREND_MAX_OFFSET)
  end

  if offset > 0.1 then
    log.debug(string.format("trend: mode=%s rate=%.3f deg/min offset=%.1f", mode, rate, offset))
  end

  return offset
end

return trend
