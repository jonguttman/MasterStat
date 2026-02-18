# MasterStat Virtual Thermostat

A SmartThings Edge driver that creates a virtual thermostat to control a **Sonoff S31 Lite ZB** outlet based on temperature readings from a **Cielo Breez Plus** thermostat. Runs locally on the SmartThings hub.

## How It Works

The Cielo Breez Plus reports room temperature but can't directly control the Sonoff outlet. MasterStat bridges them:

1. A SmartThings **Routine** pushes the Cielo's temperature reading to MasterStat's virtual thermostat
2. MasterStat evaluates heat/cool/auto logic with hysteresis and safety checks
3. MasterStat sends a **REST API command** to turn the Sonoff outlet on or off
4. MasterStat also emits `thermostatOperatingState` so a **Routine fallback** can control the outlet if the API path fails

## Features

| Feature | Description |
|---------|-------------|
| **4 Modes** | Heat, Cool, Auto, Off |
| **Hysteresis Deadband** | Configurable (default 2°F) to prevent short cycling |
| **Safety Timer** | Configurable max runtime (default 2 hrs) auto-shutoff |
| **Stale Temp Failsafe** | Shuts off if no temperature update received (default 30 min) |
| **Min Cycle Time** | Prevents rapid on/off toggling (default 5 min) |
| **Day/Night Schedule** | Two-period setback with configurable hours and setpoints |
| **Trend Detection** | Predicts temperature direction to start heating/cooling earlier |
| **Outdoor Temp Logic** | Skips unnecessary heating/cooling based on outdoor temperature |
| **Energy Tracking** | Tracks daily outlet runtime in minutes |
| **Dashboard Status** | Human-readable status text on the device tile |
| **Routines Fallback** | Emits operating state for Routine-based outlet control |

## Prerequisites

- SmartThings Hub (v3 or later with Edge driver support)
- Sonoff S31 Lite ZB outlet paired to your hub
- Cielo Breez Plus thermostat connected to SmartThings
- SmartThings CLI installed
- SmartThings Personal Access Token (PAT)

## Installation

### Step 1: Install SmartThings CLI

```bash
brew install smartthingscommunity/smartthings/smartthings
smartthings --version
```

### Step 2: Authenticate

```bash
smartthings login
# Enter your PAT when prompted
```

### Step 3: Find Your Device IDs

```bash
smartthings devices
smartthings devices --capability switch   # Find the Sonoff outlet
```

Note the **Device ID** of your Sonoff S31 Lite ZB outlet — you'll need it for preferences.

### Step 4: Register Custom Capabilities

Register the 4 custom capabilities. Create JSON files for each, then:

```bash
smartthings capabilities:create -i set-temperature-cap.json
smartthings capabilities:create -i outdoor-temperature-cap.json
smartthings capabilities:create -i status-text-cap.json
smartthings capabilities:create -i energy-tracking-cap.json
```

The JSON definitions are embedded in `src/constants.lua` — extract them to create the files above.

### Step 5: Create a Driver Channel

```bash
smartthings edge:channels:create
# Name: MasterStat
```

Note the **Channel ID** returned.

### Step 6: Package and Upload

```bash
smartthings edge:drivers:package .
smartthings edge:drivers:publish <driver-id> --channel <channel-id>
```

### Step 7: Enroll Hub and Install

```bash
smartthings edge:channels:enrollments  # Enroll your hub in the channel
smartthings edge:drivers:install <driver-id> --hub <hub-id>
```

### Step 8: Create Virtual Device

Open the SmartThings app → Add Device → Scan for nearby devices. The "MasterStat Thermostat" should appear.

### Step 9: Configure Preferences

In the SmartThings app, open the MasterStat device → Settings:

1. **PAT** — Your SmartThings Personal Access Token
2. **Outlet Device ID** — The UUID of your Sonoff S31 Lite ZB
3. Adjust other settings as desired (deadband, max runtime, schedule, etc.)

### Step 10: Create Temperature Routine

In the SmartThings app, create a Routine:

- **IF:** Cielo Breez Plus temperature changes
- **THEN:** Call `setTemperature` on MasterStat Thermostat with the Cielo's temperature value

For outdoor temperature (optional):

- **IF:** Weather temperature changes (or outdoor sensor)
- **THEN:** Call `setOutdoorTemperature` on MasterStat Thermostat

## Modes

| Mode | Behavior |
|------|----------|
| **Off** | Outlet always off |
| **Heat** | Turns outlet ON when temp drops below (setpoint - deadband), OFF when temp reaches setpoint |
| **Cool** | Turns outlet ON when temp rises above (setpoint + deadband), OFF when temp reaches setpoint |
| **Auto** | Heats below heat setpoint, cools above cool setpoint, idle in the deadband between them |

## Safety Features

- **Max Runtime:** Outlet automatically shuts off after continuous run exceeding the configured limit (default 2 hours). Prevents runaway heating/cooling.
- **Stale Temperature:** If no temperature reading is received within the timeout (default 30 min), outlet shuts off and status shows an alert. Prevents heating/cooling based on outdated data.
- **Min Cycle Time:** Prevents outlet from toggling more frequently than the configured interval (default 5 min). Protects connected equipment.

## Schedule

Enable the day/night schedule in preferences:

- **Day period:** Default 6:00 AM - 10:00 PM at 72°F
- **Night period:** Default 10:00 PM - 6:00 AM at 65°F

The schedule overrides manual setpoints when enabled.

## Routines Fallback

If REST API calls fail (e.g., internet outage), create a backup Routine:

- **IF:** MasterStat operating state = "heating" → **THEN:** Turn ON Sonoff outlet
- **IF:** MasterStat operating state = "idle" → **THEN:** Turn OFF Sonoff outlet

This provides local-only control as a fallback.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Outlet not responding | Check PAT is valid and not expired. Check outlet device ID is correct. |
| No temperature on dashboard | Verify Routine is set up to push Cielo temp to MasterStat. |
| "Stale temperature" alert | Cielo may be offline or Routine not firing. Check Cielo connection. |
| Short cycling | Increase deadband or min cycle time in preferences. |
| Outlet stays on too long | Lower max runtime setting. Check if temperature sensor is reporting. |

## File Structure

```
MasterStat/
├── config.yaml                     # Driver metadata & permissions
├── fingerprints.yaml               # Device fingerprint
├── profiles/
│   └── virtual-thermostat.yaml     # Capabilities & preferences
├── src/
│   ├── init.lua                    # Driver entry point
│   ├── constants.lua               # Defaults & custom capability JSON
│   ├── thermostat_logic.lua        # Core heat/cool/auto decision engine
│   ├── api_client.lua              # SmartThings REST API client
│   ├── scheduler.lua               # Day/night schedule
│   ├── trend.lua                   # Temperature trend detection
│   └── energy_tracker.lua          # Daily runtime tracking
├── docs/
│   ├── CHANGELOG.md
│   └── BUG_LOG.md
└── README.md
```
