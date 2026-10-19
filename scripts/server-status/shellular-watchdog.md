# Shellular Server Watchdog

The isolated Coolify Shellular runtime uses a root cron check every 10 minutes.
The watchdog reads only `/root/apps/shellular-runtime/bin/status-json`, whose
output is restricted to manager identity fields.  An online Shellular process is
left alone.  A down process is started through the pinned wrapper with its
existing `/root` state, dedicated `PM2_HOME`, Node runtime, `/root/apps/lanes`
working directory, and `requires-approval` policy; the watchdog never prints
child output or displays QR material.

The status request has a 10-second timeout and the start request has a
25-second timeout.  A manager timeout, invalid identity, unknown status, or
process-presence inconsistency produces an error without a start or stop call.
A PID that disappears just after an online manager check is queried again; the
watchdog starts only if that second check reports a recognized down state.
The cron entry takes one non-blocking file lock so overlapping checks cannot
start the app twice.  A 0600 atomic status document is written at
`/root/apps/shellular-runtime/var/watchdog-status.json`; its schema contains
only `version`, `checked_at_utc`, `result`, `action`, and a bounded reason code.
The Hog Hunter server collector can read this file to show the latest watchdog
result, while its own manager check remains the source for current running
state.

Deployment cadence:

```cron
*/10 * * * * /usr/bin/timeout 60s /usr/bin/python3 -S /root/apps/shellular-runtime/bin/shellular-watchdog.py --runtime /root/apps/shellular-runtime --home /root >/dev/null 2>&1
```

The helper is tested with fake manager responses for online, down, timeout,
invalid identity, and start timeout.  No test starts, stops, or signals the live
Shellular process.  Live installation verification should compare the pre/post
Shellular PID and confirm the cron row and status-document permissions.
