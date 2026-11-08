# Google Home / Nest Mini (Google Cast)

Local control of Cast speakers through [SwiftCast](https://github.com/CreatureSurvive/SwiftCast) (pure Swift, Cast V2 over TLS, `Network.framework`). No cloud account or Google Home API is used by this path.

## Capabilities
| Control | Notes |
|---|---|
| Volume 0–100 | Receiver volume (Cast 0.0–1.0). Voice: "set living room speaker volume to 30". |
| Mute / unmute | Receiver mute. |
| Play / pause / resume / stop | Pause/resume/stop act on the running session. `stop` stops the app (Cast has no power state). Starting music: see below. |

## Playing music
Google's own "play music" (Spotify / YouTube Music through your Google account) is not reachable over Cast. MyHome instead plays:
- **Radio presets** — saved stations (seeded with Radio Paradise, Radio Paradise Mellow, KEXP; add/remove in a speaker's detail panel).
- **Any http(s) audio URL** — Play → Play URL…
- **Files from this Mac** — Play → Play File…; served over the LAN by `CastFileServer` (only the picked file, behind an unguessable token, GET/HEAD with byte ranges). macOS may ask to allow incoming connections the first time.

Voice/text: "play jazz on the study room speaker", "play music" (last station, else the first), "pause the living room speaker", "resume music in the study", "stop the music on the living room speaker".

**The Mac keeps a connection open while playing**: the Default Media Receiver quits when its last sender disconnects (observed on Nest Mini), so quitting MyHome ends playback it started. Stop releases the connection.

No power and no input: Cast has neither, so they are refused rather than faked.

## Discovery and identity
Bonjour `_googlecast._tcp` (declared in `Xcode/Info.plist`; macOS asks for Local Network access once). Speakers are keyed by the TXT `id`, never IP/port; the record stores the Bonjour instance name so DHCP changes do not break it. Video devices and KEF LS50 (owned by the KEF adapter) are excluded. Speaker groups appear as separate devices and are labelled.

## Behaviour
- Each exchange is a short-lived TLS session (connect, one operation, disconnect), bounded by `castRequestTimeoutSeconds` (default 6).
- Refresh rides the shared poll cycle (visible 20 s, background 120 s, back-off 30/60/120 s). Keys: `castVisibleRefreshSeconds`, `castBackgroundRefreshSeconds`, `castVolumeStep`, `castDiscoveryTimeoutSeconds`.
- Writes are confirmed by one readback; the requested value is never shown before it is read.

## Qualification (2026-11-08, three Google Nest Mini)
`swift run CastProbe` lists speakers and prints state (read-only). `CAST_QUALIFY_WRITE=<deviceID> swift run CastProbe` nudges volume by 1 and restores it: Study room 38 → 37 (read 37) → 38 (read 38). Idle speakers report no foreground app and no playback state; transport needs something playing.

Playback qualification (2026-11-08, Study room Mini): `CAST_QUALIFY_PLAY=<deviceID> swift run CastProbe` plays Radio Paradise until the speaker reports playing, then stops it; with `CAST_QUALIFY_FILE=<audio file>` it serves that file from the Mac instead (AAC/m4a verified). Audible on that speaker.

## Requirements
macOS 14+ (SwiftCast floor; the app target was raised from 13).
