# Briturn Cloud Sync and Control Implementation Plan

**Goal:** Connect the signed-in Briturn account to the existing dashboard, refresh and lighting controls.

**Architecture:** Extend the native authenticated client with serialized token updates, live device discovery and verified command envelopes. Merge cloud identities with local MAC identities, keep cloud-only cards, prefer local transport when available and fall back to cloud. Reconcile writes from device status rather than treating an HTTP acknowledgement as actual state.

**Steps:** Inspect owner-authorized read-only API data and APK mappings; add models and authenticated calls; add tested firmware-aware lighting commands/status parsing; wire store sync/polling/individual and group controls; expose Settings sync feedback; run mock/unit tests and build/install; verify live sync without arbitrary light changes.

**Privacy:** Use the saved Keychain session in memory. Never print tokens, raw account responses or credentials. Live diagnostics print shapes/counts and command/status outcomes only.

## Verification so far

Fourteen Swift tests pass. Live owner-authorized discovery returned 26 devices; 21 returned fresh states. A same-state power command and readback succeeded without toggling the light. No credentials or tokens were printed. Python offline suite passes with an isolated data directory (123 tests, one skip), and Contrib initialization passes. Release packaging and UI review follow.
