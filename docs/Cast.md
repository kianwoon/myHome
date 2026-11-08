# Google Home / Nest Mini (Google Cast)

Local control of Cast speakers through [SwiftCast](https://github.com/CreatureSurvive/SwiftCast) (pure Swift, Cast V2 over TLS, `Network.framework`). No cloud account or Google Home API is used by this path.

## Capabilities
| Control | Notes |
|---|---|
| Volume 0–100 | Receiver volume (Cast 0.0–1.0). Voice: "set living room speaker volume to 30". |
| Mute / unmute | Receiver mute. |
| Play / pause / stop | On the **running** session only; nothing is launched. `stop` stops the app (Cast has no power state). |

No power and no input: Cast has neither, so they are refused rather than faked.

## Discovery and identity
Bonjour `_googlecast._tcp` (declared in `Xcode/Info.plist`; macOS asks for Local Network access once). Speakers are keyed by the TXT `id`, never IP/port; the record stores the Bonjour instance name so DHCP changes do not break it. Video devices and KEF LS50 (owned by the KEF adapter) are excluded. Speaker groups appear as separate devices and are labelled.

## Behaviour
- Each exchange is a short-lived TLS session (connect, one operation, disconnect), bounded by `castRequestTimeoutSeconds` (default 6).
- Refresh rides the shared poll cycle (visible 20 s, background 120 s, back-off 30/60/120 s). Keys: `castVisibleRefreshSeconds`, `castBackgroundRefreshSeconds`, `castVolumeStep`, `castDiscoveryTimeoutSeconds`.
- Writes are confirmed by one readback; the requested value is never shown before it is read.

## Qualification (2026-11-08, three Google Nest Mini)
`swift run CastProbe` lists speakers and prints state (read-only). `CAST_QUALIFY_WRITE=<deviceID> swift run CastProbe` nudges volume by 1 and restores it: Study room 38 → 37 (read 37) → 38 (read 38). Idle speakers report no foreground app and no playback state; transport needs something playing.

## Requirements
macOS 14+ (SwiftCast floor; the app target was raised from 13).
