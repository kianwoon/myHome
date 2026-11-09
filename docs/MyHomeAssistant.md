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
* status: `is the study fan on` / `is the study fan running`; confirmation: `yes` / `no`, `never mind`
* state questions over many devices (`ParsedIntent.stateQuery`): `how many lights are on`,
  `which fans are off`, `are any lamps on in the study`, `how many devices are on`,
  `how many fans are there`. Answered by `Voice/DeviceQueryAnswerer.swift` from the registry —
  counts always come from code; offline / never-read devices are excluded from on/off counts
  and mentioned ("1 light is offline"); long lists are cut at `stateQueryListMax` (default 5).

The parser never picks a device; `DeviceResolver` does, and asks when several match.

### Level 2 — optional model planner (`MyHomeCore/Planner/`)

Level 2 runs only when the Level-1 grammar does **not** understand an utterance (a command
the grammar fully parses, including `to two` or a misheard `to do` after a speed noun, never
reaches a model). Pick the **Cloud LLM** provider in Settings → **AI Models**; the default is
**None** (rule parser only, nothing is sent anywhere). The Cloud LLM and Jev (below) are
independent and can both be on.

**Routing** of an utterance:

1. **Rule parser** (always first, offline): direct commands, single-device status, and state
   questions (`how many lights are on`). No network.
2. **Jev router** (only if Jev is enabled and the parser returned `.unknown`): ONE decisions
   request classifies it as `command` / `query` / `inference` / `other` (the `kind`, `state`
   and `aggregation` questions ride in the same request and are read only for `query`).
   * `command` → the Jev matcher (Stage A device, Stage B action) → confirmation.
   * `query` → `DeviceQueryAnswerer` (Jev picks only the shape; counts come from code).
   * `inference` (“the room is stuffy”) → the Cloud LLM, whose plan is confirmed; with no
     Cloud LLM the reply says to configure one in Settings → AI Models and nothing runs.
   * `other` → "couldn't match it to a command".
   * route below gate / unmeasured / failed / timed out → Cloud LLM if available, else the
     Jev matcher (the pre-router behaviour).
3. **Cloud LLM** (when Jev is off): every `.unknown` utterance is planned as before.

Migration: a stored `plannerProvider = "jev"` from earlier builds is converted once at launch
(`AppSettings.migrateLegacyJevProvider`) to `jevEnabled = true` + provider `none`.

* **Apple on-device** (`FoundationModelsPlanner`, macOS 26+, off by default): the model has
  an 8,192-token window, so it sees only a compact catalogue (`handle|name|room|kind|state|can`,
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
  device names, room names, kinds, capabilities and the current state (`on 40%`, `off`,
  `offline`, `?`) are sent to the provider so it can reason about a situation (stuffy + fan off
  → turn the fan on and set a speed); device ids and credentials are not. The default
  instructions tell the model to propose actions for a described condition, using current
  state and only the listed handles. Defaults (endpoints, `anthropic-version`, budgets) live in
  `ControlSettings.swift`.

**The model only proposes**: handles are mapped back to ids and validated against the
registry, every step goes through `DeviceController` policy, and a model-authored plan is
always shown and confirmed before anything runs. Planner and command awaits are bounded by
`plannerTimeoutSeconds` / `assistantCommandTimeoutSeconds`; on timeout the command bar shows a
message, the spinner resets, and a Cancel button abandons a request in flight.

### Jev router & matcher — choice classifier (`MyHomeCore/Planner/JevClient.swift`, `JevCommandDecider.swift`, `Control/JevSettings.swift`, `MyHomeApp/JevSettingsView.swift`)

Toggle **Use Jev to route and match requests** in Settings → AI Models → *Jev router &
matcher* (setting `jevEnabled`, default off). Jev is not a planner: it only
answers *choice* questions with a label and per-label probabilities (the opencode jev wire
contract, `POST https://openrouter.ai/api/alpha/decisions`, body `{model, state, questions}`).
The rule parser always runs first — a request it fully understands (`turn off the study fan`)
never leaves the Mac. Jev is asked only when the parser cannot settle the request:

* **Stage A — which device?** Options are the short catalogue handles (`d1`, `d2` …) from the
  compact `PlannerCatalogue`, each described by name, room, kind and capabilities (budgeted,
  ≤ 255 options). For an ambiguous parse (`turn on the lamp`) only the parser's candidates are
  offered; for a known command only devices that support it.
* **Stage B — which action?** Only the actions the chosen device supports
  (`power-on`, `power-off`, `set-level`, `set-speed`, `set-color-temperature`, `open`,
  `close`, `stop`). Skipped when the parser already knows the command. Numeric values come
  from the transcript via the rule parser (`VoiceCommandParser.value(in:)`); with no value the
  user is asked for one.

The stages are **two sequential calls**: decision questions are independent within one
request, so Stage B's per-device options cannot depend on Stage A's answer in a single batch
(the same two-stage shape as opencode's `jev_hat`). A lone candidate is taken without a call.

**Gate and fail-open.** A choice is accepted only when `probabilities[choice]` ≥ the threshold
(default 0.7, slider 0.3…1.0; the 0.3 confidence floor also binds inside the fold) —
`confidence` is never used. An envelope without a non-empty `model` echo, a row whose
probability map lacks the chosen label, a label that was not offered, HTTP errors, timeouts
or no key all fail open: the reply falls back to the parser's own answer and says
"Jev wasn't sure — did you mean …?" with the options Jev leaned to (or the parser's
candidates), so the user is asked, never guessed for. Retries: network error, timeout, 429
and 5xx only — 3 attempts, 200 ms then 600 ms back-off, each attempt bounded by the timeout
(default 3 s). Worst case is about 10 s per stage, so a two-stage request is also bounded by
`plannerTimeoutSeconds`.

**What Jev cannot do.** It cannot answer free text, count, or invent an action: it only picks
labels it was offered. Questions are answered by `DeviceQueryAnswerer`; situations
("I'm cold") need a Cloud LLM.

**Safety.** Jev only advises. An accepted match becomes a proposal that waits for "yes"
(source `jev`, origin `.model`), exactly like a model-authored plan, even for a single
device; `DeviceController` policy still decides what runs. A failed call never authorizes
anything. Replies start with what was heard (`I heard "…"`).

**Key and privacy.** The key is stored in the Keychain (`SecretStore`, account
`jev-openrouter`), with `OPENROUTER_API_KEY` from the environment as a fallback; it is sent
only as a `Bearer` header to the configured host, redirects are refused, plain `http` is
allowed for localhost only, and no error text quotes a response body or the key. The
transcript plus device names, room names, kinds and capabilities are sent to the endpoint;
device ids, states and credentials are not. A pasted `openrouter/<id>` model spec has the
transport prefix stripped. **Test connection** sends a minimal two-option choice question
and reports the model echo.

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
* **MLX backend (optional)**: `speechQwenBackend` = `mlx` (default) or `onnx`, picked in
  Settings → Assistant → Speech engine. `mlx` swaps only the per-segment decode for
  Qwen3-ASR-1.7B-8bit on the Apple GPU (`MlxQwenAsr.swift`, mlx-audio-swift pinned to the
  revision Pop uses); VAD, endpointing and the echo guard are unchanged. The MLX model is
  looked up in `MyHome/speech/qwenasr-mlx-8bit`, then Pop's `qwenasr-mlx-8bit` (read-only), and
  **Install** downloads ~2.4 GB from Hugging Face. A missing model or a load failure falls
  back to the sherpa-onnx decoder. Measured here: ~6 s one-time load, 0.28 s to decode a 1.3 s
  command. The language pin does not apply to MLX; hotwords go in the decoder prompt. A
  bundled app must ship `mlx-swift_Cmlx.bundle` (Metal kernels) next to the binary.
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

### Muting the speakers while listening (`MyHomeCore/Voice/AudioOutputGate.swift`, `CoreAudioOutputController.swift`, `MyHomeApp/OutputMuteSettingsView.swift`)

While the microphone is open (hold-to-talk **and** the command-bar mic share one recogniser, so both paths are covered) the default output is muted, so music or a video never leaks into the recogniser. Settings → Assistant → **While listening**: **Off**, **Mute** (default) or **Duck** (slider: fraction of the *current* volume kept, range in `ControlSettings`).

* Captures the exact state first and restores exactly that afterwards. An output you had already muted (or set to zero) is never touched, so it can never be force-unmuted. A volume or mute change you make yourself during the hold wins over the restore.
* Restored on release, cancel, error, release-before-ready, quit (`applicationWillTerminate`) and sleep, and **before** the spoken reply (`SpeechResponder`) so the reply is audible. Overlapping sessions share one mute (reference counted).
* If the default output device changes mid-hold, the original device is restored and the new one is not touched.
* A `pendingRestore` record is written to UserDefaults before the output is changed and removed on restore; after a crash or force-quit the next launch restores the device only if it is still the same device and still in the state MyHome set.
* Prefers `kAudioDevicePropertyMute`; outputs without it (some Bluetooth, AirPlay, HDMI) fall back to the volume scalar (main, else the stereo channels). If an output has neither, the HUD and Settings show "Cannot mute this output" instead of failing silently. **Check this output** in Settings reports what the current device supports without changing the audio.

### Siri / Shortcuts (`MyHomeApp/Intents/`)

`DeviceEntity` (+ `EntityStringQuery` through the same resolver), `SetDevicePowerIntent`,
`SetDeviceLevelIntent` and the free-text `ControlHomeIntent` (same pipeline as the command
bar; multi-device plans ask for confirmation through Siri). `MyHomeShortcuts` registers the
phrases. The intents run in-process and reach the app's single `DeviceStore` through
`AppServices.shared`; a cold launch from Shortcuts does one bounded roster refresh.

## Speakers (Google Home / Nest Mini via Cast)

Cast speakers are `DeviceStore` records (`cast:<id>`, `Device.ip` empty). The controller reuses `volume` and `mute`; `CapabilityMap` plans them as `WritePlan.cast`, `DeviceStore.castWrite` sends and does one readback. No power or input. Speech: "set living room speaker volume to 30", "mute the study room speaker". Playback: "play jazz on the study room speaker", "pause/resume/stop the music on …" (`DeviceCommand.play` / `.playback`, capability `media`). Details: [Cast.md](Cast.md).

## Speakers (KEF LS50 Wireless II)

KEF speakers are native `DeviceStore` records (`kef:<mac>`, `Device.ip` empty so no Tuya/Briturn path claims them). The controller gains `volume`, `mute` and `input` capabilities; `CapabilityMap` plans them as `WritePlan.kef`, `DeviceStore.kefWrite` sends and does one readback, and `compare` verifies against the published reading. Volume/mute/input are refused in standby. Speech: "set KEF volume to 30 percent", "mute the speakers", "switch KEF to TV", "what volume are the speakers at?". Details: [KEF.md](KEF.md).

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

### Troubleshooting: OpenRouter "provisioning" keys vs API keys

OpenRouter has two kinds of keys. A **provisioning key** (also called a management key) only creates and manages other keys; it passes a generic validity check but cannot make any request, so the decisions endpoint answers `HTTP 401 User not found.` When Test connection (Jev or the cloud planner) gets a 401/403 from `openrouter.ai`, MyHome makes one extra request to OpenRouter's key-info endpoint with the same key and says whether it is a provisioning key, a normal key the service still rejects, or invalid/deleted. If it says provisioning, create a normal key with **Create API Key** (not provisioning) and save that one. Nothing is sent to any other host, and the key is never logged.

## Known limits

* Colour on Tuya bulbs is not offered (the dashboard never writes `colour_data`'s HSV
  encoding); colour is Briturn-only until a verified encoder exists.
* Numbers may be digits or spelled out up to ten ("two"); a misheard "to do" / "to too" is read as 2 only as the value of a speed setting.
* Siri / Shortcuts discovery was verified by building the bundle and inspecting
  `Metadata.appintents` (three intents, entity query, enum), not by invoking Siri on a device.

## Building and installing the app

`MyHomeApp/scripts/build-standalone.sh` builds a self-contained, ad-hoc signed (hardened runtime plus `Xcode/MyHome.entitlements`) `MyHome.app` with the Swift release binary (sherpa-onnx is statically linked, so no extra dylibs), the embedded Python bridge runtime, `bridge.py` and tinytuya. It writes to `MyHomeApp/build/standalone/` (gitignored; override with `MYHOME_OUT_DIR`, and set `MYHOME_SIGN_IDENTITY` for a real certificate) and never installs anything: copy the bundle to `/Applications` yourself after quitting the running app. For the Xcode path (needed for Siri / Shortcuts App Intents metadata), pass `-clonedSourcePackagesDirPath` pointing outside `/tmp` (e.g. `~/Library/Caches/MyHomeSourcePackages`), because `/tmp` is wiped on reboot and SwiftPM checkouts there silently disappear: `xcodebuild -project MyHome.xcodeproj -scheme MyHome -clonedSourcePackagesDirPath ~/Library/Caches/MyHomeSourcePackages build`.
