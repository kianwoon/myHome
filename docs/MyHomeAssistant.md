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

### Level 2 — optional model planner (`MyHomeCore/Planner/`)

Level 2 runs only when the Level-1 grammar does **not** understand an utterance (a command
the grammar fully parses, including `to two` or a misheard `to do` after a speed noun, never
reaches a model). Pick the provider in Settings → Assistant; the default is **None** (rule
parser only, nothing is sent anywhere).

* **Apple on-device** (`FoundationModelsPlanner`, macOS 26+, off by default): the model has
  an 8,192-token window, so it sees only a compact catalogue (`handle|name|room|kind|caps`,
  capped by `plannerCatalogueBudgetChars`, best name matches first) plus bounded
  `listDevices` / `findDevices` tools (`plannerToolOutputBudgetChars`). A fresh session is
  created per request; on a context-overflow the request is retried once with a much smaller
  catalogue.
* **Anthropic API** and **OpenAI-compatible** (`CloudPlanner`, URLSession, no dependencies):
  one JSON-plan request per utterance. Settings: base URL (editable, so local servers work;
  plain `http` only for localhost), free-text model name, API key, timeout, max tokens, and
  a **Test connection** button. The key is stored in the macOS Keychain
  (`SecretStore`), sent only as a request header to the configured host, never logged and
  scrubbed from error text; HTTP error bodies are never quoted. **Privacy:** the command plus
  device names, room names, kinds and capabilities are sent to the provider; device ids,
  states and credentials are not. Defaults (endpoints, `anthropic-version`, budgets) live in
  `ControlSettings.swift`.

**The model only proposes**: handles are mapped back to ids and validated against the
registry, every step goes through `DeviceController` policy, and a model-authored plan is
always shown and confirmed before anything runs. Planner and command awaits are bounded by
`plannerTimeoutSeconds` / `assistantCommandTimeoutSeconds`; on timeout the command bar shows a
message, the spinner resets, and a Cancel button abandons a request in flight.

### Speech (`MyHomeCore/Voice/SpeechCommandRecognizer.swift`, `SpeechResponder.swift`)

Speech-to-text runs **offline on this Mac** with the same engine stack as the Pop app;
Apple's `SFSpeechRecognizer` is no longer used (the Speech framework is not linked).

* **Engines** (`SherpaSpeechEngines.swift`, sherpa-onnx 1.13.8): **Qwen3-ASR-0.6B INT8** is
  the primary engine (Pop's pinned, tested ring) and **SenseVoice INT8** the fallback
  (language pinned from the voice locale, inverse text normalisation on). Pop's whisper.cpp
  ring is not ported: in Pop it is a Chinese-only tail ring. Order and fallback live in
  `SpeechEngineChain` (`SpeechEngine.swift`): membership = enabled AND installed, an
  optional pin (`speechPreferredEngine`), the last engine that produced text leads, and an
  engine that loads but stays silent is marked dead for the process and sorts last.
* **Models** are looked up in `~/Library/Application Support/MyHome/speech/{qwenasr,sensevoice}`
  first, then (read-only, `speechUsePopModels`) in Pop's
  `~/Library/Application Support/Pop/{qwenasr,sensevoice}`. A usability gate (size floors,
  ONNX header byte, tokenizer tables) runs before any recognizer is built, because
  sherpa-onnx aborts on a bad asset. With no usable model the mic button is disabled and
  Settings → Assistant → Speech engine offers **Install** (~1 GB download from the sherpa-onnx
  release page into MyHome's own folder; Pop's folder is never written).
* **Capture and endpointing**: `AVAudioEngine` tap → 16 kHz mono (`PCMFeeder`) → Silero VAD
  with Pop's dictation profile (threshold 0.5, 0.35 s min silence, 0.25 s min speech, 10 s
  max segment, 500 ms pre-roll clamped to observed silence) → one offline decode per segment
  (`SegmentingTranscriber`). `UtteranceEndpointer` ends a push-to-talk command once a
  segment was transcribed and no new speech starts within `speechEndpointHangoverSeconds`
  (0.6 s); it also stops a session where nothing is said (`speechNoSpeechTimeoutSeconds`)
  and caps one at `speechMaxUtteranceSeconds`. Pressing the mic again stops capture and
  decodes what is buffered (bounded by `speechFlushTimeoutSeconds`).
* **Bounded waits**: microphone permission uses `AVAudioApplication` (macOS 14+,
  `AVCaptureDevice` on 13) under Pop's 10 s handshake watchdog; recognizer construction is
  off the main thread under `speechModelLoadTimeoutSeconds` (45 s) and falls to the next
  engine on failure; a 5 s liveness probe restarts the session on the next engine when an
  engine processed nothing while audible audio flowed.
* **Vocabulary bias**: device and room names are passed to Qwen3-ASR as comma-separated
  hotwords (`speechHotwordBias`, at most 64). SenseVoice has no hotword input. Spelled-out
  numbers and the "speed to do / too" homophones are normalised in `VoiceCommandParser`.
* Every default and range is in `Voice/SpeechSettings.swift`. Offline tests cover the VAD
  segmenting/pre-roll state machine (energy-segmenter stand-in with synthetic tones), the
  endpointer, the engine chain and liveness verdict, config clamping and the install gate;
  `SpeechModelInferenceTests` transcribe a `say`-rendered command with the real models and
  are skipped when no model is installed.

Replies use `AVSpeechSynthesizer`. Permission requests are gated on the bundle carrying
`NSMicrophoneUsageDescription`; a process without it (`swift run`) gets a clear message
instead of a crash and keeps typed commands.

**Xcode build note:** the onnxruntime XCFramework contains framework symlinks that Xcode's
package extractor rejects when `SourcePackages` sits under `/tmp` (a symlink to
`/private/tmp`). Use a derived-data path outside `/tmp`, pass
`-clonedSourcePackagesDirPath <path outside /tmp>`, or make `<derivedData>/SourcePackages` a
symlink to such a path.

### Global hold-to-talk shortcut (`MyHomeCore/Hotkey/`, `MyHomeApp/CarbonHotkeyRegistrar.swift`, `HotkeyHUD.swift`, `HotkeySettingsView.swift`)

Settings → Assistant → **Hold-to-talk shortcut**: click the field, press a combination (Esc cancels), **Clear** or **Reset**. **Hold to talk, release to run** — press starts listening, release stops and runs the utterance through the same `AssistantCoordinator` path as the command bar. There is no toggle mode. No shortcut is set by default.

* `HotkeyBinding` (key code + modifier mask, stored as JSON under `assistantHotkeyBinding`) must include at least one modifier; bare keys and modifier-only keys are rejected, and well-known system combinations (⌘Space, ⌘Tab, ⇧⌘3/4/5, …) are accepted with a warning.
* Registered with Carbon `RegisterEventHotKey` (as Pop does): works from any app, needs no Accessibility / Input Monitoring permission, and delivers both key-down and key-up. A conflict with another app is shown under the field. Changing the setting re-registers live; the shortcut is paused while recording.
* `HotkeyController` is the testable state machine (registration is injected): key-repeat and release-without-press are ignored, re-binding or sleep while held counts as a release. Releasing before the speech model has loaded (or while the microphone prompt is up) cancels the pending start instead of leaving the recogniser listening; the first press with no microphone permission triggers the normal permission prompt.
* The utterance wiring lives in `AppServices`, so it works with every window closed. A small non-activating floating panel (never takes focus from the frontmost app) shows Listening…, the live transcript, the result and **Yes / No** for a pending confirmation (model plans always need one), then disappears after `hotkeyHUDDismissSeconds` (default 4; `hotkeyHUDConfirmDismissSeconds`, default 15, while a confirmation is pending — a confirmation left unanswered stays pending in the command bar). The spoken reply is unchanged.
* Safety is unchanged: the shortcut only starts listening; policy checks, the multi-device threshold and always-confirm for model plans still apply.

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
* **Settings → Assistant**: spoken replies, voice language, the speech engine (engine choice,
  model install state, listening/VAD knobs), the
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
* Numbers may be digits or spelled out up to ten ("two"); a misheard "to do" / "to too" is read as 2 only as the value of a speed setting.
* Siri / Shortcuts discovery was verified by building the bundle and inspecting
  `Metadata.appintents` (three intents, entity query, enum), not by invoking Siri on a device.
