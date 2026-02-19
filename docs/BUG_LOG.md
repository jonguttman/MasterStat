# Bug Log

Document bugs encountered during development and deployment. Format:

```
## Bug: [Short Title]
- **Date:** YYYY-MM-DD
- **Symptoms:** What was observed
- **Root Cause:** Why it happened
- **Fix:** What was changed
- **Prevention:** How to avoid in the future
```

---

## Bug: Edge Driver Cannot Make Outbound HTTPS Calls
- **Date:** 2026-02-19
- **Symptoms:** `cosock.asyncify "ssl.https"` fails with `"host or service not provided, or not known"` when calling api.smartthings.com from the hub
- **Root Cause:** SmartThings Edge platform intentionally blocks all outbound connections to non-RFC 1918 IP addresses. This is a security design decision — Edge drivers can only reach local LAN devices (192.168.x.x, 10.x.x.x, 172.16-31.x.x).
- **Fix:** Removed all outbound API calls. Driver now operates as a pure logic engine. Temperature input comes via SmartThings Rules API (cloud relay). Outlet control via Routines that mirror thermostatOperatingState.
- **Prevention:** Never attempt direct internet API calls from Edge drivers. Use Routines/Rules or a local proxy (EdgeBridge) for external API access.
