# MyHome — KEF LS50 Wireless II Integration Specification

| Document control | Value |
|---|---|
| Document ID | MYHOME-KEF-001 |
| Version | 0.1 |
| Status | Draft — pending device validation |
| Date | 7 November 2026 |
| Product | MyHome for macOS |
| Supported hardware | KEF LS50 Wireless II |
| Target release | Initial KEF integration |

**Objective:** Provide native speaker control with power/standby, volume, mute, input selection, room placement and unified assistant access.

**Architecture:** A native Swift LAN adapter in MyHomeCore integrates with DeviceStore and the existing DeviceController pipeline. SwiftUI provides the speaker card, setup flow and detail panel.

**Platform:** Swift tools 5.9, macOS 13 or later, Foundation URLSession, SwiftUI and XCTest. Authentication credentials, where required, use the existing Keychain infrastructure. No additional package dependency is planned.

**Requirement convention:** “Shall” identifies a mandatory requirement. “Should” identifies a recommendation. Proposed protocol details require validation against the supported hardware before release. This is a MyHome integration specification, not a KEF-issued protocol document.

## 1. Context and scope

This specification covers the KEF LS50 Wireless II speaker system. The original LS50 Wireless and other KEF models are outside the initial compatibility scope. KEF Connect version 1.32.0 (3070) is the application compatibility reference.

Initial release requirements:

- Manual addition of a speaker by local IPv4 address; verify model and identity before saving.
- One card per speaker pair, identified by the primary speaker's stable identity.
- Power active/standby, absolute volume, mute, supported input selection.
- Freshness, connection, pending-command and error states.
- Persistent local name, room and endpoint configuration.
- A Speakers sidebar category, room views, and compact menu controls.
- The same controls available through the existing command/controller pipeline, including text and voice examples below.

Deferred: automatic discovery, playback/transport controls, artwork, streaming-service integration, EQ, subwoofer controls, multiroom grouping, schedules, scenes, firmware updates and speaker onboarding to Wi-Fi. Playback and EQ interfaces are outside the initial release scope.

## 2. Communication interface

### 2.1 Interface baseline

The following interface definitions have been identified in the KEF Connect application reference. Compatibility with the target speaker firmware remains subject to device validation. No hardware validation has been completed at this document revision.

| Operation | Endpoint | Parameters or body |
|---|---|---|
| Read data | GET `/api/getData` | Query parameters: `path`, `roles` |
| Write data | POST `/api/setData` | JSON fields: `path`, `role`, `value` |
| Read collection | GET `/api/getRows` | Query parameters include `path`, `roles`, `from`, `to` |
| Event delivery | `/api/event/modifyQueue`, `/api/event/pollQueue` | Reserved for a future event-driven implementation |

The input value model includes the property `kefPhysicalSource`. The application reference also includes speaker account provisioning through `webserver:addUser`; the applicability of this mechanism to the supported firmware is unconfirmed.

### 2.2 Resource catalogue

| Purpose | Resource path |
|---|---|
| Power read | `powermanager:target` |
| Power request | `powermanager:targetRequest` |
| Speaker status | `settings:/kef/host/speakerStatus` |
| Volume | `player:volume` |
| Mute | `settings:/mediaPlayer/mute` |
| Input | `settings:/kef/play/physicalSource` |
| Model | `settings:/kef/host/modelName` |
| Firmware | `settings:/kef/host/firmwareVersion` |
| Stable identity candidate | `settings:/system/primaryMacAddress` |
| Volume limit candidates | `settings:/kef/host/maximumVolume`, `settings:/kef/host/volumeLimit` |

The application-wide input enumeration contains `standby`, `wifi`, `bluetooth`, `tv`, `optical`, `coaxial`, `analog`, `usb`, `boundaryDetection` and `phono`. This enumeration spans multiple products. The integration shall expose only inputs verified for LS50 Wireless II.

### 2.3 Device qualification requirements

The following items shall be validated before control operations are enabled:

1. Speaker endpoint scheme, port, access restrictions and any authentication requirements on the user's firmware.
2. Identity/read response envelopes and role selection.
3. Exact typed values, role names, units, ranges, and successful/error responses for all four controls.
4. Power versus standby semantics, including whether waking requires input selection.
5. Model-specific input support, including how Wi-Fi and TV are represented.
6. Relationship between native volume, maximum volume and configured volume limits.
7. Whether state remains readable during standby, and actual timeout behaviour.

Request encoding shall use verified value types and role definitions. Resource paths alone are insufficient to define a valid command. Authentication shall follow the applicable speaker setup process, with credentials stored in Keychain. Speaker account provisioning shall require an explicit setup action and shall not occur silently. Unvalidated operations shall remain unavailable and shall be documented as pending qualification.

## 3. User interface

Follow existing MyHome typography, spacing, materials, colours and control sizes. Use `speaker.wave.2.fill` where available. Do not add a separate visual theme.

### Sidebar and listing

Add **Speakers** beside existing device categories. Include KEF in room views and search. Preserve existing active-first sorting: active, unknown, standby, then name/id for stability. Reachability is separate from power: standby can be reachable; offline is not proof of standby.

### Card

```text
┌─────────────────────────────────────────┐
│ 🔊 Living Room KEF                Active │
│ LS50 Wireless II · Living Room           │
│                                         │
│ Power                            [ On ] │
│ Input                       [ Wi-Fi ▾ ] │
│                                         │
│ Volume   ━━━━━━━●──────────────     35%  │
│ [ − ]                    [ Mute ] [ + ]  │
│                              [Details]  │
└─────────────────────────────────────────┘
```

- Title is the user-defined local display name; subtitle contains model and room if set.
- Badge states: Connecting, Active, Standby, Offline, or Needs Setup. Stale state is visibly labelled.
- Power is labelled On/Standby, not mains power off.
- Slider uses a 0–100 user scale only once native mapping is verified. Label it Volume, never Brightness.
- While dragging, show a local preview and commit once on release. Keyboard adjustments commit with a short debounce. Coalesce pending volume changes so the last intent wins.
- ± changes one user-volume step and respects verified limits. A limit must never be bypassed by scaling or writes.
- Mute is independent of volume; unmuting restores the speaker's retained level, not a hard-coded default.
- Input displays confirmed supported sources with friendly labels such as Wi-Fi, Bluetooth, TV, Optical, Coaxial and AUX where verified.
- Unknown input values display as Unknown; never guess or overwrite them automatically.
- Disable volume/mute/input while in standby in version one. Power is available in reachable standby; source selection must not silently wake a speaker.
- Disable writes while offline or setup is incomplete. Show last known values as stale, not current.
- A pending control shows progress; server readback supplies the confirmed value. On failure restore confirmed state and show a concise inline error.
- Provide accessibility labels, keyboard control and non-colour status cues.

### Add speaker

Entry point: existing device/settings UI → Add Speaker → KEF LS50 Wireless II.

Fields: primary speaker IPv4 address, optional local display name, optional room. Use a structured address field, not an arbitrary URL. Validate input; construct only the verified endpoint. Do not follow redirects to unrelated hosts or fall back to cloud endpoints.

**Test Connection** performs identity and state reads only. Display verified model, name and firmware; reject unsupported models with a clear explanation. **Add Speaker** becomes available after successful identity validation. Re-adding the same stable identity updates its endpoint rather than creating a duplicate. Preserve the room/name when an IP changes.

If an address is reachable but not authenticated, show Needs Setup with the verified next action. A failed test does not save a working device or show false success.

### Detail panel and menu

Detail panel repeats the controls and shows model, firmware, address, last successful update, Refresh, Edit Connection, local name/room, and Remove from MyHome. Removal deletes only local configuration and any integration-specific saved credentials; it must not reset or unpair the speaker.

The menu shows name, power, mute, current volume, ± and Open Details. Reuse the same state and command path as the dashboard. Do not create a second polling loop.

## 4. Swift model and adapter contract

Proposed source layout (subject to repository conventions):

- `MyHomeApp/Sources/MyHomeCore/KEF/KEFModels.swift`
- `MyHomeApp/Sources/MyHomeCore/KEF/KEFClient.swift`
- `MyHomeApp/Sources/MyHomeCore/KEF/KEFConfigurationStore.swift`
- `MyHomeApp/Sources/MyHomeCore/DeviceStore+KEF.swift`
- `MyHomeApp/Sources/MyHomeApp/KEFSpeakerCard.swift`
- `MyHomeApp/Sources/MyHomeApp/KEFSpeakerDetailView.swift`
- `MyHomeApp/Sources/MyHomeApp/AddKEFSpeakerView.swift`

Define typed models for identity, endpoint/configuration, input, power, state and errors. Keep unknown input/power values representable. State fields may be unavailable individually; never turn a missing value into false, zero or standby. Track last-success time independently from the latest request error.

Application adapter contract (independent of the device payload schema):

```swift
protocol KEFClientProtocol {
    func fetchIdentity() async throws -> KEFIdentity
    func fetchState() async throws -> KEFState
    func setPower(_ on: Bool) async throws
    func setVolume(_ percent: Int) async throws
    func setMuted(_ muted: Bool) async throws
    func setInput(_ input: KEFInput) async throws
}
```

Inject transport/client for offline tests. Isolate mutable request coordination in an actor or an equivalent serial boundary; publish store state on MainActor. Keep UI, protocol serialization and persistence separate. Use explicit typed errors for invalid address, unsupported model/input, authentication required, timeout, unreachable, malformed response and rejected command. Error text must not include secrets or raw authenticated responses.

Use a versioned configuration record with stable identity, address, display name and room. Reuse existing preferences conventions for non-secret metadata. Credentials, if required, belong in existing Keychain facilities. Application installation packages, third-party implementation material, real device addresses, credentials and private response captures shall be excluded from commits and test fixtures.

## 5. Existing integration points

Implementation shall comply with `AGENTS.md`, `DESIGN.md` and `docs/MyHomeAssistant.md`. Integration points shall be checked against the current repository revision before development.

| Existing file | Required integration |
|---|---|
| `Sources/MyHomeCore/Device.swift` | Add speaker classification and icon; category `kef`; stable namespaced id such as `kef:<verified-identity>` |
| `Sources/MyHomeCore/DeviceStore.swift` | Merge local KEF records into derived devices without letting bridge/cloud refresh erase them; reachability and controllability |
| `Sources/MyHomeCore/DeviceStore+DerivedCache.swift` | Invalidate derived device/room caches when KEF configuration/state changes |
| `Sources/MyHomeCore/Control/DeviceCommand.swift` | Add explicit volume, mute and input capabilities/commands; retain power |
| `Sources/MyHomeCore/Control/CapabilityMap.swift` | KEF write plan and confirmed-state expectations; advertise only supported capabilities |
| `Sources/MyHomeCore/Control/DeviceController.swift` | Execute KEF via store; verify from published state |
| `Sources/MyHomeCore/Control/DeviceResolver.swift` | Resolve KEF names/rooms without bypassing ambiguity handling |
| `Sources/MyHomeCore/Control/CommandPhrasing.swift` | Human-readable speaker commands and outcomes |
| `Sources/MyHomeCore/Voice/VoiceCommandParser.swift` | Explicit speaker volume, mute and input grammar |
| `Sources/MyHomeCore/Voice/DeviceQueryAnswerer.swift` | Speaker power/volume/input queries using fresh state |
| `Sources/MyHomeCore/Agent/HousekeeperTools.swift` and planner catalogue/converters | Expose typed capabilities through existing validation, not a raw HTTP tool |
| `Sources/MyHomeApp/MainWindow.swift` | Speakers category, card/detail routing and room inclusion |
| `Sources/MyHomeApp/MenuContentView.swift` | Compact speaker controls |
| `Sources/MyHomeApp/SettingsView.swift` | Setup/configuration entry point |
| `Sources/MyHomeApp/AppServices.swift` | Shared dependencies/lifecycle; no per-view client instance |
| `Sources/MyHomeApp/Intents/` | Preserve exhaustive switches and existing Shortcuts behaviour; dedicated speaker intents may be deferred |

All paths in the table are relative to `MyHomeApp/`. Audit every exhaustive command/capability/kind switch and serialization schema after adding cases. Keep old commands and device behaviour intact. KEF volume, mute and input shall have explicit semantic capabilities, independent of Tuya DPS, light brightness and generic device modes.

Required examples:

- “Turn on the living room speakers.” → power on.
- “Set KEF volume to 30 percent.” → volume 30.
- “Mute the speakers.” / “Unmute KEF.” → mute boolean.
- “Switch KEF to TV.” → validated supported input.
- “What volume are the speakers at?” → answer from confirmed fresh state.

Ambiguous device references ask for clarification through existing handling. A volume instruction must not select a light. Unsupported controls and stale-state queries shall return explicit availability or freshness messages. Preserve existing model-output confirmation policy.

## 6. Refresh, writes and verification

Start with conservative, configurable defaults: 3-second request timeout; one in-flight exchange per speaker; visible speaker status refresh every 15 seconds; menu-only/background refresh no faster than 60 seconds. Integrate with existing lifecycle scheduling and stop duplicate loops. These are initial engineering defaults, not tested firmware limits.

Read-only transient failures may retry once with bounded delay. Back off repeated failures (30, 60, 120 seconds, capped at 5 minutes); manual Refresh bypasses delay once. Do not automatically replay failed writes. Cancel obsolete refreshes safely and prevent stale responses from overwriting a newer command's readback using a request generation or equivalent ordering.

DeviceStore sends the command and performs one bounded readback, with at most one delayed follow-up within the verification window if hardware proves necessary. DeviceController observes the published state using its existing verification mechanism; it must not add its own KEF polling. HTTP success alone is not command success. Represent mismatch/timeouts as unconfirmed, retaining actual readback. Do not publish a requested value as confirmed before reading it.

An idempotent volume/mute command may be sent in place of an older queued intent, but operations must remain ordered around power/input changes. No timer-driven power changes, maximum-volume changes or automatic unmute.

## 7. Implementation work packages

1. **Interface qualification:** confirm request/response schemas and authentication against the application reference and target speaker. Record validated payloads in `docs/KEF.md`. Obtain the primary speaker address when the read-only validation procedure is ready. Qualify control operations individually using a controlled listening level.
2. **Adapter and fixtures:** implement typed parsing and injected transport using synthetic fixtures based on verified shapes. Cover partial responses and failures before store/UI integration.
3. **Configuration and store:** persist the local speaker record, merge it into roster-derived views, add freshness/reachability and ordered writes/readback. Prove bridge/cloud refresh does not discard KEF.
4. **Semantic control:** add volume/mute/input cases, KEF write plans and expectations; update relevant switch sites, parsers, query answers, catalogue and assistant tools.
5. **SwiftUI:** add setup, card, details, category and menu, using the existing shared controller/store. Verify active, standby, stale, pending and offline views.
6. **Regression and documentation:** run checks below; update docs and release notes; report exact hardware/firmware exercised and remaining limitations.

Each work package shall produce reviewable changes. Production UI shall report confirmed device state. Where hardware is unavailable, offline development may proceed; device qualification and hardware acceptance shall remain open release criteria.

## 8. Verification and acceptance criteria

Offline XCTest coverage belongs in `MyHomeApp/Tests/MyHomeCoreTests/`, suggested suites `KEFClientTests`, `KEFStoreTests` and `KEFControlTests`:

- Correct verified request encoding and typed response decoding, including unknown enums and missing fields.
- Volume bounds, real device-limit enforcement, invalid input rejection, and no silent wake/unmute.
- Timeout/authentication/non-2xx/malformed reply handling with no secret leakage.
- Ordered/coalesced volume intents and stale-response protection.
- Readback match/mismatch/timeout; accepted HTTP response alone never confirms a change.
- Stable identity deduplication, persistence reload, changed IP, room inclusion and cache invalidation.
- Bridge/cloud roster refresh retains KEF and existing devices.
- Speaker grammar/resolution/capability validation; brightness commands still target lights.
- Existing light/fan/curtain and assistant policy tests remain green.

Run from the repository root:

```sh
swift build --package-path MyHomeApp
swift test --package-path MyHomeApp
python -m tests
python testcontrib.py
pylint --recursive y -E tinytuya/
```

Use the pinned Python lint environment. Dependency downloads/build prerequisites can block Swift checks; record blockers accurately. These changes should not alter TinyTuya wire code. Inspect `MyHomeApp/scripts/build-standalone.sh`, `project.yml` and the app entitlements/Info configuration before packaged-app validation; verify the LAN access path in the distributed app as well as SwiftPM execution.

Hardware acceptance requires the user's actual LS50 Wireless II: add/test identity, active→standby→active, modest volume adjustment, mute/unmute without volume reset, every exposed input, unreachable address, reconnect, app restart, and a packaged app launch. Record firmware and observed authentication requirements locally without publishing private identifiers. UI QA must check card/detail/menu consistency, keyboard operation, status/error legibility and room filtering.

Documentation to update in the implementation: `docs/KEF.md` (setup, verified protocol and troubleshooting), `DESIGN.md` (native KEF adapter and control path), `README.md` (MyHome capabilities), `docs/MyHomeAssistant.md` (speaker commands), and `RELEASE.md` (user-visible feature with actual author/PR credit when known; do not invent a PR number).

## 9. Implementation handoff

**Target implementation agent:** GPT-6 Luna.

**Implementation brief:**

> Implement the initial release defined in `docs/plans/2026-11-07-kef-ls50-wireless-ii-design.md`. Confirm repository requirements and integration boundaries before development. Qualify the communication interface against KEF Connect 1.32.0 (3070) and the target LS50 Wireless II firmware. Deliver the native Swift adapter, persistent configuration, speaker UI and unified power, volume, mute and input controls. Preserve existing device transports and assistant policy. Provide offline regression coverage, complete the documentation updates and report hardware acceptance separately from automated test results. Obtain the primary speaker address when ready for read-only device qualification.

### Reference material

- Application compatibility reference: `KEF+Connect_1.32.0+(3070)_APKPure.xapk`, containing `com.kef.connect.apk`.
- Internal interface references: `com.kef.streamunlimitedapi.model.base.ApiPath`, `ApiRequestSetData`, `kefPhysicalSource` and `com.kef.streamunlimitedapi.model.settings.ApiPhysicalSource`.
- Repository architecture: `DESIGN.md` and `docs/MyHomeAssistant.md`.
- Validation record: pending; to be maintained in `docs/KEF.md` during implementation.
