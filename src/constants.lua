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
constants.DEFAULT_STALE_TEMP_TIMEOUT = 60 -- minutes
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

-- Auto-switching defaults
constants.DEFAULT_AUTO_OUTDOOR_HEAT_BELOW = 55  -- outdoor °F below which auto biases to heating
constants.DEFAULT_AUTO_OUTDOOR_COOL_ABOVE = 75  -- outdoor °F above which auto biases to cooling
constants.DEFAULT_MODE_SWITCH_COOLDOWN = 10     -- minutes between heat↔cool transitions
constants.DEFAULT_EVENING_START_HOUR = 18       -- 6 PM — evening suppression begins

-- ============================================================
-- Timer intervals (seconds)
-- ============================================================
constants.EVAL_INTERVAL = 30
constants.STALE_CHECK_INTERVAL = 60
constants.ENERGY_TRACK_INTERVAL = 60
constants.STARTUP_DELAY_SEC = 60

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
constants.FIELD_HEAT_MINS_TODAY = "heat_mins_today"
constants.FIELD_COOL_MINS_TODAY = "cool_mins_today"
constants.FIELD_CYCLES_TODAY = "cycles_today"
constants.FIELD_LAST_TRACKED_STATE = "last_tracked_state"
constants.FIELD_COMFORT_MINS_TODAY = "comfort_mins_today"
constants.FIELD_TRACKED_MINS_TODAY = "tracked_mins_today"
constants.FIELD_STALE_ALERT = "stale_alert"
constants.FIELD_MAX_RUNTIME_LOCKOUT = "max_runtime_lockout"
constants.FIELD_STARTUP_LOCKOUT = "startup_lockout"
constants.FIELD_TEMP1 = "temp_source_1"
constants.FIELD_TEMP1_TIME = "temp_source_1_time"
constants.FIELD_TEMP2 = "temp_source_2"
constants.FIELD_TEMP2_TIME = "temp_source_2_time"
constants.FIELD_LAST_MODE = "last_non_off_mode"
constants.FIELD_LAST_AUTO_SWITCH_TIME = "last_auto_switch_time"

-- ============================================================
-- Custom capability JSON definitions
-- Used with capabilities.build_cap_from_json_string()
-- ============================================================

constants.SET_TEMPERATURE_CAP = [[
{
  "id": "benchventure06596.settemperature",
  "version": 1,
  "name": "setTemperature",
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
          "schema": { "type": "number" }
        }
      ]
    }
  }
}
]]

constants.SET_TEMPERATURE_2_CAP = [[
{
  "id": "benchventure06596.settemperature2",
  "version": 1,
  "name": "setTemperature2",
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
          "schema": { "type": "number" }
        }
      ]
    }
  }
}
]]

constants.OUTDOOR_TEMPERATURE_CAP = [[
{
  "id": "benchventure06596.outdoortemperature",
  "version": 1,
  "name": "outdoorTemperature",
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
          "schema": { "type": "number" }
        }
      ]
    }
  }
}
]]

constants.STATUS_TEXT_CAP = [[
{
  "id": "benchventure06596.statustext",
  "version": 1,
  "name": "statusText",
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
  "id": "benchventure06596.energytracking",
  "version": 1,
  "name": "energyTracking",
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

constants.ENERGY_DETAILS_CAP = [[
{
  "id": "benchventure06596.energydetails",
  "version": 1,
  "name": "energyDetails",
  "status": "proposed",
  "attributes": {
    "heatingRuntime": {
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
    },
    "coolingRuntime": {
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
    },
    "dailyCycles": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "number" }
        }
      }
    },
    "efficiency": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "number" },
          "unit": {
            "type": "string",
            "enum": ["%"],
            "default": "%"
          }
        }
      }
    }
  },
  "commands": {}
}
]]

constants.ENERGY_SUMMARY_CAP = [[
{
  "id": "benchventure06596.energysummary",
  "version": 1,
  "name": "energySummary",
  "status": "proposed",
  "attributes": {
    "runtimeSummary": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "string" }
        }
      }
    },
    "costSummary": {
      "schema": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "value": { "type": "string" }
        }
      }
    },
    "efficiencySummary": {
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

return constants
