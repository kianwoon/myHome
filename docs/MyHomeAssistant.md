# MyHome app: unified device control, voice, Siri and natural language

The MyHome macOS app (`MyHomeApp/`) controls Tuya devices (through `bridge.py`) and
Briturn lights (cloud / WiFi / Bluetooth). This document describes the control layer
that sits between every way of asking ("turn off the bedroom lights" typed, spoken,
via Siri/Shortcuts, or planned by Apple's on-device model) and the devices.

## Architecture

```
Interaction layer      command bar (text / push-to-talk)   Siri & Shortcuts (App Intents)
                                  │                                   │
AI intent / planning   VoiceCommandParser (Level 1, grammar)  ──►  AssistantCoordinator
                       FoundationModelsPlanner (Level 2, proposes only)        │
                                                                               ▼
Unified Device         DeviceController: resolve (DeviceResolver) → policy (isControllable,
Control API            reachability, CapabilityMap) → execute (DeviceStore writes) → verify
                       (store's published state, config timeout) → CommandResult + spoken summary
                                                                               │
Adapters (existing)    DeviceStore → bridge.py (Tuya LAN / Tuya cloud fallback), Briturn cloud,
                       Briturn WiFi, Briturn BLE          [Matter: future adapter, see below]
```

All of it lives in `MyHomeApp/Sources/MyHomeCore` (library, unit-tested offline) except the
SwiftUI command bar, the Settings tab and the App Intents, which live in the app target.

### Unified Device Control API (`MyHomeCore/Control/`)

| File | Role |
|---|---|
| `DeviceCommand.swift` | Semantic commands: `power`, `level` (percent), `color`, `colorTemperature` (percent warm→cool), `mode`, `fanSpeed` (gear), `cover` (open/close/stop); `SemanticCapability`; `Percent` scaling helpers. |
| `CapabilityMap.swift` | `DeviceKind` + spec `Capability` codes + live `DeviceState` → which semantic capabilities a device has, and the exact write for a command (`WritePlan`: a Tuya dp value or Briturn arguments). Dp selection mirrors the dashboard views (fan speed key, curtain action/position keys, light dp 2/3, Briturn 0–100) and prefers the spec's declared ranges. A command is only offered when the device supports it. |
| `DeviceResolver.swift` | Name / room / group / kind matching with content-agnostic scoring. Returns `single`, `set` (plural or "all", with a scope), `briturnGroup` (exact group membership → group write), or **`ambiguous`** with the candidates. Ambiguity is surfaced, never guessed. |
| `DeviceController.swift` | `@MainActor` entry point: registry (`DeviceSummary`, `Sendable`), `resolve`, `check` (policy), `perform`. Multi-device requests above the confirmation threshold return `needsConfirmation` with a `pendingRequest` to re-issue. Writes run sequentially. |
| `CommandPhrasing.swift` | Spoken / displayed summaries built from the structured result. |
| `ControlSettings.swift` | `AppSettings` keys + defaults for every knob (verify timeout, confirmation threshold, resolver margins, voice, planner). |
| `TextNormalizer.swift` | Shared folding / tokenising / singularising. |

**Verification semantics.** The controller never polls a device (aggressive polling crashes
consumer firmware). After a write it waits, up to `commandVerifyTimeoutSeconds`, for
`DeviceStore`'s *published* state to show the expected value, observing `objectWillChange`
only. Because the store paints discrete writes optimistically and defends them for its grace
window, the per-device outcome distinguishes:

| Outcome | Meaning |
|---|---|
| `confirmed` | the store reported success and the published state shows the value |
| `unverified` | success reported, but a continuous value's reply carried no dps; the store's own poll settles it |
| `uncertain` | transport error with unknown outcome; the optimistic paint is kept (store invariant) |
| `rejected` | the bridge/device rejected the write; the store reverted |
| `denied` | policy refused (no control path, offline) |
| `unsupported` | the device cannot do this (with the reason, e.g. the valid mode list) |

### Level 1 — direct commands, no model (`MyHomeCore/Voice/VoiceCommandParser.swift`)

A deterministic grammar (`CommandGrammar`, injectable for other languages) over tokens:

* power: `turn on/off X`, `switch X off`, `X on`, `turn everything off`
* levels: `set X to 50%`, `dim X to 20`, `set X brightness to 80`, `move the curtain to 40%`
* fan: `set X speed to 3`, `X speed 4`, `set the fan to 3` (bare numbers up to the top gear are gears, larger ones percents)
* modes / colour: `set X to sleep mode`, `set X mode to nature`, `make X red`, `set X to warm white`
* covers: `open / close / stop X`
* rooms: `turn off the lights in the master bedroom`
* status: `is the study fan on`; confirmation: `yes` / `no`, `never mind`

The parser never picks a device; `DeviceResolver` does, and asks when several match.

### Level 2 — Apple Foundation Models (`MyHomeCore/Planner/`)

`FoundationModelsPlanner` is used only when the Level-1 grammar does not understand the
utterance (or names no known device) and only when `#available(macOS 26, *)` and
`SystemLanguageModel.default.availability == .available`; otherwise the app degrades to
Level 1 with a visible reason (Settings → Assistant). The model sees the registry (ids,
names, rooms, capabilities, state) through `listDevices` / `findDevices` tools and returns
a `@Generable` structured plan. **The model only proposes**: every id is validated against
the registry, every step goes through `DeviceController` policy, and a model-authored plan
is always shown and confirmed before anything runs. Instructions come from
`AppSettings.plannerInstructions` (override) with a reviewed default.

### Speech (`MyHomeCore/Voice/SpeechCommandRecognizer.swift`, `SpeechResponder.swift`)

Push-to-talk capture with `SFSpeechRecognizer` + `AVAudioEngine` (on-device recognition when
the locale supports it and `speechPreferOnDevice` is set), silence / max-utterance timers,
and `AVSpeechSynthesizer` replies. Permission requests are gated on the bundle carrying
`NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`; a process
without them (`swift run`) gets a clear message instead of a crash and keeps typed commands.

### Siri / Shortcuts (`MyHomeApp/Intents/`)

`DeviceEntity` (+ `EntityStringQuery` through the same resolver), `SetDevicePowerIntent`,
`SetDeviceLevelIntent` and the free-text `ControlHomeIntent` (same pipeline as the command
bar; multi-device plans ask for confirmation through Siri). `MyHomeShortcuts` registers the
phrases. The intents run in-process and reach the app's single `DeviceStore` through
`AppServices.shared`; a cold launch from Shortcuts does one bounded roster refresh.

## Using it

* **Command bar** (bottom of the dashboard): type a command and press Return, or press the
  microphone (⇧⌘M) and speak. Replies show up inline with **Yes / No** for multi-device plans
  and one button per candidate when a request was ambiguous.
* **Settings → Assistant**: spoken replies, on-device recognition, voice language, the
  on-device planner switch, the confirmation threshold and the verification timeout.
* **Siri / Shortcuts** (Xcode-built app only): "Control my home with MyHome", "Set *device*
  power with MyHome", "Set *device* level with MyHome". Shortcuts also lists the three actions.

## Building the app bundle (Xcode path)

`swift build` / `swift test` stay the CI path, and `scripts/build-standalone.sh` still
produces the self-contained bundle (its Info.plist now carries the microphone and speech
usage strings). The Xcode project adds what only a real app target provides: usage
prompts, App Intents metadata extraction (`Metadata.appintents`), entitlements and signing.

```bash
cd MyHomeApp
xcodegen generate                      # regenerates MyHome.xcodeproj from project.yml (brew install xcodegen)
xcodebuild -project MyHome.xcodeproj -scheme MyHome -configuration Debug build
```

Choices and why:

* **Generated, checked-in `.xcodeproj` from `project.yml`.** The app target compiles the
  same `Sources/MyHomeApp` files as SwiftPM and depends on this package's `MyHomeCore`
  library product, so there is one source of truth; the spec is reviewable and the project
  is reproducible. Re-run `xcodegen generate` after adding app-target files.
* **Hardened Runtime, not App Sandbox.** The app spawns the embedded Python bridge and
  reaches devices over LAN and Bluetooth, which the sandbox would block. Entitlements:
  `com.apple.security.device.audio-input`, `com.apple.security.device.bluetooth`. Network
  client/server access needs no hardened-runtime entitlement.
* **Ad-hoc signing** for local runs (`CODE_SIGN_IDENTITY=-`, no team in the spec). Set a team
  in Xcode or an un-tracked xcconfig for distribution. Note that Xcode applies the hardened
  runtime flag to the Release configuration (`codesign -dv` shows `adhoc,runtime`) but not to
  ad-hoc Debug builds (`adhoc` only); the entitlements are embedded in both.
* The scheme sets `MYHOME_BRIDGE_DIR=$(SRCROOT)/..` so a DerivedData build finds this
  checkout's `bridge.py`.

## Extension points (deferred by design)

* **Level 3 — scene engine.** Scenes are lists of `(DeviceQuery | ids, DeviceCommand)` steps;
  run them through `DeviceController.perform` so policy, verification and confirmation apply.
  `ProposedPlan` is already that shape, so the model could author scenes too.
* **MCP server.** Expose `DeviceController.summaries()`, `resolve` and `perform` as tools; the
  `DeviceSummary` / `CommandResult` types are `Sendable` and JSON-friendly for that purpose.
* **Matter adapter.** Add a transport behind `DeviceStore` and teach `CapabilityMap` the
  cluster → `SemanticCapability` mapping; nothing above the controller changes.

## Known limits

* Colour on Tuya bulbs is not offered (the dashboard never writes `colour_data`'s HSV
  encoding); colour is Briturn-only until a verified encoder exists.
* Numbers must be digits ("50", "50%"); number words are not parsed.
* Siri / Shortcuts discovery was verified by building the bundle and inspecting
  `Metadata.appintents` (three intents, entity query, enum), not by invoking Siri on a device.
