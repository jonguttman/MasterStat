-- MasterStat REST API Client
-- Uses cosock async HTTPS to control SmartThings devices without blocking

local cosock = require "cosock"
local https = cosock.asyncify "ssl.https"
local json = require "st.json"
local log = require "log"

local api_client = {}

local API_BASE = "https://api.smartthings.com/v1"

--- Send a command to a SmartThings device via REST API
-- @param pat string Personal Access Token
-- @param device_id string Target device UUID
-- @param capability string Capability ID (e.g., "switch")
-- @param command string Command name (e.g., "on" or "off")
-- @param args table|nil Optional command arguments
-- @return boolean success
function api_client.send_command(pat, device_id, capability, command, args)
  if not pat or pat == "" then
    log.warn("api_client: No PAT configured, skipping API call")
    return false
  end
  if not device_id or device_id == "" then
    log.warn("api_client: No device ID configured, skipping API call")
    return false
  end

  local body = json.encode({
    commands = {
      {
        component = "main",
        capability = capability,
        command = command,
        arguments = args or {}
      }
    }
  })

  local url = API_BASE .. "/devices/" .. device_id .. "/commands"

  local ok, status_code, headers = https.request({
    url = url,
    method = "POST",
    headers = {
      ["Authorization"] = "Bearer " .. pat,
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#body)
    },
    source = require("ltn12").source.string(body),
    sink = require("ltn12").sink.null(),
    verify = "none"
  })

  if not ok then
    log.error(string.format("api_client: Network error for %s.%s to %s — %s",
      capability, command, device_id, tostring(status_code)))
    return false
  end

  if status_code == 200 then
    log.info(string.format("api_client: Command %s.%s sent to %s", capability, command, device_id))
    return true
  else
    log.error(string.format("api_client: Failed %s.%s to %s — HTTP %s",
      capability, command, device_id, tostring(status_code)))
    return false
  end
end

--- Turn outlet switch on
-- @param pat string Personal Access Token
-- @param device_id string Outlet device UUID
-- @return boolean success
function api_client.set_switch(pat, device_id, on)
  local command = on and "on" or "off"
  return api_client.send_command(pat, device_id, "switch", command)
end

return api_client
