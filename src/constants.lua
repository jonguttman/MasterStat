-- MasterStat Constants
-- All default values, field keys, timer intervals, and custom capability definitions

local constants = {}

-- ============================================================
-- Default values
-- ============================================================
constants.DEFAULT_HEAT_SETPOINT = 72
constants.DEFAULT_COOL_SETPOINT = 76
constants.DEFAULT_DEADBAND = 2
constants.DEFAULT_MAX_RUNTIME = 120       -- minutes
constants.DEFAULT_STALE_TEMP_TIMEOUT = 30 -- minutes
constants.DEFAULT_MIN_CYCLE_TIME = 5      -- minutes
constants.DEFAULT_TEMP_UNIT = "F"

-- Schedule defaults
constants.DEFAULT_DAY_START_HOUR = 6
constants.DEFAULT_DAY_SETPOINT = 72
constants.DEFAULT_NIGHT_START_HOUR = 22
constants.DEFAULT_NIGHT_SETPOINT = 65

-- Outdoor temp threshold offset
constants.OUTDOOR_HEAT_SKIP_OFFSET = 5
constants.OUTDOOR_COOL_SKIP_OFFSET = 5

-- Trend detection
constants.TREND_WINDOW_SIZE = 10
constants.TREND_MAX_OFFSET = 2            -- max predictive offset in degrees

-- ============================================================
-- Timer intervals (seconds)
-- ============================================================
constants.EVAL_INTERVAL = 30
constants.STALE_CHECK_INTERVAL = 60
constants.ENERGY_TRACK_INTERVAL = 60

-- ============================================================
-- Device field keys (for set_field / get_field)
-- ============================================================
constants.FIELD_CURRENT_TEMP = "current_temp"
constants.FIELD_OUTDOOR_TEMP = "outdoor_temp"
constants.FIELD_HEAT_SETPOINT = "heat_setpoint"
constants.FIELD_COOL_SETPOINT = "cool_setpoint"
constants.FIELD_MODE = "thermostat_mode"
constants.FIELD_OPERATING_STATE = "operating_state"
constants.FIELD_OUTLET_ON = "outlet_on"
constants.FIELD_OUTLET_ON_SINCE = "outlet_on_since"
constants.FIELD_LAST_TEMP_UPDATE = "last_temp_update"
constants.FIELD_LAST_STATE_CHANGE = "last_state_change"
constants.FIELD_AUTO_ACTION = "auto_action"
constants.FIELD_TREND_READINGS = "trend_readings"
constants.FIELD_ENERGY_TODAY_MINS = "energy_today_mins"
constants.FIELD_ENERGY_DAY_OF_YEAR = "energy_day_of_year"
constants.FIELD_STALE_ALERT = "stale_alert"

-- ============================================================
-- Custom capability JSON definitions
-- Used with capabilities.build_cap_from_json_string()
-- ============================================================

constants.SET_TEMPERATURE_CAP = [[
{
  "id": "masterstat.setTemperature",
  "version": 1,
  "name": "Set Temperature",
  "status": "proposed",
  "attributes": {
    "temperature": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "number" },
          "unit": {
            "type": "string",
            "enum": ["F", "C"],
            "default": "F"
          }
        }
      }
    }
  },
  "commands": {
    "setTemperature": {
      "name": "setTemperature",
      "arguments": [
        {
          "name": "temperature",
          "schema": { "type": "number" },
          "required": true
        }
      ]
    }
  }
}
]]

constants.OUTDOOR_TEMPERATURE_CAP = [[
{
  "id": "masterstat.outdoorTemperature",
  "version": 1,
  "name": "Outdoor Temperature",
  "status": "proposed",
  "attributes": {
    "outdoorTemperature": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "number" },
          "unit": {
            "type": "string",
            "enum": ["F", "C"],
            "default": "F"
          }
        }
      }
    }
  },
  "commands": {
    "setOutdoorTemperature": {
      "name": "setOutdoorTemperature",
      "arguments": [
        {
          "name": "temperature",
          "schema": { "type": "number" },
          "required": true
        }
      ]
    }
  }
}
]]

constants.STATUS_TEXT_CAP = [[
{
  "id": "masterstat.statusText",
  "version": 1,
  "name": "Status Text",
  "status": "proposed",
  "attributes": {
    "statusText": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "string" }
        }
      }
    }
  },
  "commands": {}
}
]]

constants.ENERGY_TRACKING_CAP = [[
{
  "id": "masterstat.energyTracking",
  "version": 1,
  "name": "Energy Tracking",
  "status": "proposed",
  "attributes": {
    "dailyRuntime": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "number" },
          "unit": {
            "type": "string",
            "enum": ["min"],
            "default": "min"
          }
        }
      }
    }
  },
  "commands": {}
}
]]

return constants
