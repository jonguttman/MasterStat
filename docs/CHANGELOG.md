# Changelog

## v0.2.0 — 2026-02-19

### Changed
- Removed outbound REST API calls from Edge driver (SmartThings hub blocks external HTTPS)
- Driver is now a pure logic engine — receives temperature via Routines/Rules, emits operating state
- Outlet control delegated to SmartThings Routines that mirror thermostatOperatingState
- Temperature input via SmartThings Rules API that relays Cielo readings to setTemperature command
- Removed polling timer and api_client dependency from thermostat_logic and init

## v0.1.0 — 2026-02-18

### Added
- Initial implementation of MasterStat Virtual Thermostat Edge driver
- Core thermostat modes: Heat, Cool, Auto, Off with hysteresis deadband
- REST API client (`cosock` async HTTPS) for controlling Sonoff S31 Lite ZB outlet
- Custom capability `masterstat.setTemperature` for Routine-pushed indoor temperature
- Custom capability `masterstat.outdoorTemperature` for Routine-pushed outdoor temperature
- Custom capability `masterstat.statusText` for dashboard status display
- Custom capability `masterstat.energyTracking` for daily runtime tracking
- `thermostatOperatingState` emission for Routines fallback outlet control
- Safety features: max runtime shutoff, stale temperature failsafe
- Minimum cycle time enforcement to prevent short cycling
- Day/night temperature setback scheduling
- Temperature trend detection with predictive heating/cooling offset
- Outdoor temperature logic to skip unnecessary heating/cooling
- Daily energy runtime tracking with midnight reset
- Configurable preferences: PAT, outlet device ID, temp unit, setpoints, deadband, timers, schedule, outdoor temp toggle
- Virtual LAN device creation via discovery handler
- Driver config, profile, and fingerprint YAML files
- README with installation guide and feature documentation
