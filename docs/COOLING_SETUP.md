# Cooling Setup: Zigbee Plug + Alexa Routine Bridge

## Background

MasterStat's auto-switching logic emits `thermostatOperatingState = "cooling"` when cooling is needed, but the Mysa mini-split's SmartThings integration doesn't expose cooling capabilities (only `thermostatHeatingSetpoint`). The Mysa **Alexa skill** does support full mode control (cool, heat, off, setpoint).

The bridge: a physical Zigbee plug acts as a signal device that Alexa can trigger on. Rules API flips the plug on/off based on MasterStat's operating state, and Alexa routines translate that into Mysa commands.

```
MasterStat (cooling) → Rules API → Zigbee plug ON → Alexa routine → Mysa: Cool mode
MasterStat (idle)    → Rules API → Zigbee plug OFF → Alexa routine → Mysa: Off
```

## What You Need

- 1x Zigbee smart plug (e.g., Sonoff S31 Lite ZB, ~$10-15)
- The plug does NOT need to control anything — just plug it into a wall outlet for power

## Step 1: Pair the Zigbee Plug

1. Open SmartThings app → Devices → "+" → Add Device
2. Put the plug in pairing mode (usually hold button 5-10s until LED blinks)
3. SmartThings will discover it — name it **"MasterStat Cooling Signal"**
4. Note the device ID: SmartThings app → Device → three-dot menu → Information → Device ID
   - Or run: `smartthings devices -j | python3 -c "import json,sys; [print(d['deviceId'], d['label']) for d in json.load(sys.stdin) if 'cooling' in d.get('label','').lower()]"`

## Step 2: Create Rules API Rules

Replace `PLUG_DEVICE_ID` below with the actual device ID from Step 1.

MasterStat device ID: `e9cbfaea-3060-4835-95d6-8fb0649ca1e4`
Location ID: `3e7de89c-5859-40e5-be1f-77121be5cec8`

### Rule 1: Cooling Signal ON when cooling

```bash
smartthings rules:create -l "3e7de89c-5859-40e5-be1f-77121be5cec8" -j <<'EOF'
{
  "name": "MasterStat: Cooling Signal ON when cooling",
  "actions": [
    {
      "if": {
        "equals": {
          "left": {
            "device": {
              "devices": ["e9cbfaea-3060-4835-95d6-8fb0649ca1e4"],
              "component": "main",
              "capability": "thermostatOperatingState",
              "attribute": "thermostatOperatingState"
            }
          },
          "right": { "string": "cooling" }
        },
        "then": [
          {
            "command": {
              "devices": ["PLUG_DEVICE_ID"],
              "commands": [{ "component": "main", "capability": "switch", "command": "on" }]
            }
          }
        ]
      }
    }
  ]
}
EOF
```

### Rule 2: Cooling Signal OFF when idle

```bash
smartthings rules:create -l "3e7de89c-5859-40e5-be1f-77121be5cec8" -j <<'EOF'
{
  "name": "MasterStat: Cooling Signal OFF when idle",
  "actions": [
    {
      "if": {
        "equals": {
          "left": {
            "device": {
              "devices": ["e9cbfaea-3060-4835-95d6-8fb0649ca1e4"],
              "component": "main",
              "capability": "thermostatOperatingState",
              "attribute": "thermostatOperatingState"
            }
          },
          "right": { "string": "idle" }
        },
        "then": [
          {
            "command": {
              "devices": ["PLUG_DEVICE_ID"],
              "commands": [{ "component": "main", "capability": "switch", "command": "off" }]
            }
          }
        ]
      }
    }
  ]
}
EOF
```

### Rule 3: Cooling Signal OFF when mode off (safety)

```bash
smartthings rules:create -l "3e7de89c-5859-40e5-be1f-77121be5cec8" -j <<'EOF'
{
  "name": "MasterStat: Cooling Signal OFF when mode off",
  "actions": [
    {
      "if": {
        "equals": {
          "left": {
            "device": {
              "devices": ["e9cbfaea-3060-4835-95d6-8fb0649ca1e4"],
              "component": "main",
              "capability": "thermostatMode",
              "attribute": "thermostatMode"
            }
          },
          "right": { "string": "off" }
        },
        "then": [
          {
            "command": {
              "devices": ["PLUG_DEVICE_ID"],
              "commands": [{ "component": "main", "capability": "switch", "command": "off" }]
            }
          }
        ]
      }
    }
  ]
}
EOF
```

## Step 3: Set Up Alexa

### 3a: Enable Mysa Alexa Skill

1. Alexa app → More → Skills & Games → search "Mysa"
2. Enable and link your Mysa account

### 3b: Discover Devices

1. Alexa app → Devices → "+" → Add Device
2. Or say: "Alexa, discover my devices"
3. Verify "MasterStat Cooling Signal" appears in the device list

### 3c: Create Alexa Routine — Cool ON

1. Alexa app → More → Routines → "+"
2. **When This Happens:** Smart Home → MasterStat Cooling Signal → turns ON
3. **Add Action:** Smart Home → Mysa thermostat → set mode **Cool**, set temp to your desired cooling setpoint (e.g., 73°F)
4. Save

### 3d: Create Alexa Routine — Cool OFF

1. Alexa app → More → Routines → "+"
2. **When This Happens:** Smart Home → MasterStat Cooling Signal → turns OFF
3. **Add Action:** Smart Home → Mysa thermostat → turn OFF
4. Save

## Step 4: Test

1. In SmartThings app, set MasterStat to **Auto** mode
2. Set the cooling setpoint a few degrees below the current room temperature to trigger cooling
3. Wait for the next eval cycle (30 seconds)
4. Verify:
   - MasterStat operating state shows "cooling"
   - The Zigbee plug turns ON
   - Alexa routine fires and Mysa switches to cool mode
5. Set the cooling setpoint back above room temperature
6. Verify:
   - MasterStat goes to "idle"
   - Zigbee plug turns OFF
   - Alexa routine fires and Mysa turns off

## Notes

- The cooling setpoint in the Alexa routine is **fixed** — to change the cooling target on the mini-split, update the Alexa routine
- MasterStat's cooling setpoint controls **when** it decides to cool; the Alexa routine controls **what temp the mini-split targets**
- The heater outlet is automatically forced OFF when cooling is active (safety rule already in place)
- Cloud-to-cloud latency (SmartThings → Alexa → Mysa) adds a few seconds of delay
