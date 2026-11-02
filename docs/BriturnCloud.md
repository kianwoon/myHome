# Briturn Cloud sign-in in MyHome

Open **Settings → Cloud → Briturn Cloud**, enter the email/password used in the Briturn mobile app, choose the account's server region (United States, Europe or China), and choose **Sign In**. A successful login displays a masked email and remembers the session in macOS Keychain. **Sign Out** deletes this Mac's saved session; no server-side revocation endpoint has been verified.

Cloud devices sync at launch, on the normal cloud refresh cycle, and with **Sync Devices** in Settings. They appear in the Briturn dashboard and menu, merged with local devices by exact MAC address. Cloud-only lights have no local IP. The cloud is the base for Briturn lights: the dashboard lists the cloud's lights, and group names/membership come from the cloud (`/app/device/group/list` + `/app/device/relation/list`) and override bridge/BLE groups. Local groups in `devices.json` and `briturn.bleGroups` are kept untouched but only used as a fallback before the first successful sync. Groups cannot be edited in MyHome; change them in the Briturn app. Bridge-only Briturn lights with no cloud match are still shown (and logged). A remembered session may expire; sign in again if necessary. No password-based automatic re-login is performed.

## Implementation

`MyHomeApp/Sources/MyHomeCore/BriturnCloudClient.swift` implements the email protocol traced in Briturn Android 1.0.23 (build 67):

1. POST `/app/sys/config` on the chosen `https://app-{us,eu,cn}.briturn.net` host and obtain server time.
2. POST `/app/user/login` with JSON `codeType: EMAIL`, `username: <email>`, and `password: uppercase MD5(UTF-8 password)`.
3. Both requests carry common query metadata and a lowercase MD5 query signature. Concatenate raw query values in this order: `appBVer`, `appKey`, `appVer`, `lang`, `os`, `osSystem`, `platform`, `sdkVersion`, `time`, `timeZoneId`, `v`, then the literal `appSecure=` and the Android app's distributed signing constant. Hash before URL encoding. The client deliberately uses the inspected Android protocol metadata (`67`, `BR001`, `1.0.23`, `Android`, `36`, `1.0`, `1`) plus an identifying platform string `MyHome-macOS`.
4. Require HTTP 200, integer application code 0, nonempty top-level `token` and a `data` object. Accept returned `webApi` only when it is the root HTTPS URL of one of the three known hosts, without credentials, query, fragment or custom port.
5. Store only masked account metadata, API URL and token in a generic-password Keychain item (`com.myhome.app.briturn-cloud`, account `session`). Passwords, password hashes and raw server responses are never persisted. The embedded app-wide signing constant is protocol metadata, not a user's account secret.

The ephemeral URLSession disables cookies, persistent URL credentials and cached response reuse. Redirects are rejected so login bodies cannot be forwarded elsewhere. Server messages and network error details are not shown verbatim or logged because they could contain sensitive values. Normal platform HTTPS certificate checks remain enabled.

## Validation

Run `swift test --package-path MyHomeApp`. Mock HTTP tests verify hashing/signature order, time synchronization, the login body, masked persistence, sign-out, application errors, HTTP rejection, unsafe returned URLs, missing tokens, invalid input and Keychain-save failures. Tests use synthetic accounts/tokens and in-memory persistence. They do not access real Keychain items or log in to a real account.

The earlier reverse-engineering investigation verified the public configuration endpoint with a credential-free request (HTTP 200/application code 0). The owner confirmed successful real login. Subsequent live verification discovered 26 devices, all `TCP_WF` product 95; 21 returned fresh state packets. A same-state power command followed by readback succeeded without toggling a light. This confirms the HTTP cloud route, not MQTT or every lighting mode on real hardware.


## Device sync, state and control

`BriturnCloudDevice.swift` maps POST `/app/home/list` and per-home POST `/app/device/list` into canonical `briturn-<normalized MAC>` identities. The actual device records contain `deviceId`, `productId`, `entityType`, `macAddress`, `name`, `functionList`, and `entityData.online`. Cloud IP addresses and cached `entityData.state` are deliberately not treated as local reachability or fresh device state. The live cached state was an extended `ea81...` format; fresh `device.quest` returned the standard checksummed 14-byte `815f...` state.

Authenticated requests use the saved regional host and `token` header, serialize session operations to avoid token-update races, and save nonempty replacement response tokens in Keychain. HTTP 401/403 clears the rejected session. No raw responses or credentials are logged.

Lighting controls use POST `/app/command/custom` with `entityType: TCP_WF`, `type: device.quest` or `device.hex`, and `body: [{id: <numeric deviceId>, value: <hex string>}]`. Fresh queries send `818A8B96`. The parser validates hex, packet length, prefix, power byte and checksum. Control packets are generated only for the verified product 95 and supported function flags, with firmware >=10 confirmed from fresh state:

- Power: `3B 23|24` plus ten zero bytes and sum checksum.
- RGB: `3B A1 hue/2 saturation value 00 00 00 00 1E 00 00` plus checksum; saturation/value use 0–100.
- Brightness: `3B 01 00 00 level 00 level 00 00 00 00 00` plus checksum.
- White temperature: `3B B1 00 00 00 cct brightness 00 00 1E 00 00` plus checksum; CCT/brightness use 0–100.

Commands are grouped by entity and stage, in batches of at most 32. Each operation queries firmware/state before sending and queries state again after acknowledgement. Offline group members are omitted from writes, and missing readbacks are reported as unconfirmed rather than painted as success. The store retains local Wi-Fi/Bluetooth handling; cloud-only individual controls and linked group controls use cloud, and failed local individual writes/status reads can fall back to cloud. Menu toggles use the same routing. Status refresh uses grouped cloud requests, with existing UI debounce behavior retained.

The client currently implements HTTP device discovery/status/control, not MQTT or cloud schedules. On-bulb schedule editing still requires local Wi-Fi. Unrecognized models remain visible but cloud commands are rejected rather than guessed.

Run `swift run --package-path MyHomeApp BridgePingTest briturncloud` for read-only count/status diagnostics. The explicit `briturncloud-verify-control` mode also reasserts one light's existing power state and verifies its readback. Both use the saved Keychain session and print counts/outcomes only.
