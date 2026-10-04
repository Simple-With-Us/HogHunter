# Remote host stays online when Bonjour updates

Sat, Oct 4, 2026

## Why

A saved Tailscale, IP, or domain host uses an address, not a Bonjour peer id.  Every browse update called reconcile, which marked that Mac offline and dropped the dashboard.  A clean confirmation in flight went with it.

## What

`CompanionReach.keepsManualHost` is true when the saved remote host trims to a non-empty string.  `noteDiscovery` and `reconcile` return before they can set the offline phase.  A failed fetch still reports that the Mac did not answer.  A Wi-Fi-only saved Mac still goes offline when Bonjour cannot see it.

## Verification

macOS unit test `testManualHostStaysPutWhenBonjourCannotSeeIt`.  The iOS companion target compiles the same helper.

## Not in this change

Remote quit and tame still identify a process by pid only (issue #63).  Widgets and the cold-start Clean tap stay on issue #65.  No App Group entitlement was added.
