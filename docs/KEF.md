# KEF LS50 Wireless II in MyHome

Native Swift adapter (`MyHomeApp/Sources/MyHomeCore/KEF/`) that controls a KEF LS50 Wireless II over its local HTTP API: power (On/Standby), volume, mute and input. Spec: `docs/plans/2026-11-07-kef-ls50-wireless-ii-design.md` (MYHOME-KEF-001).

## Status: protocol pending device qualification

Request/response shapes below come from **open-source reference clients** (pykefcontrol's `KefConnector`, the same `getData`/`setData` API KEF Connect uses). **Nothing has been verified on real hardware yet.** Hardware acceptance remains an open release criterion.

| Operation | Request | Value |
|---|---|---|
| Read | `GET /api/getData?path=<path>&roles=value` | JSON array; first element typed, e.g. `{"type":"i32_","i32_":35}` |
| Write | `POST /api/setData` `{"path","roles":"value","value":{"type":T,"T":V}}` | |
| Volume | `player:volume` | `i32_` 0…100 |
| Mute | `settings:/mediaPlayer/mute` | `bool_` (**from the spec; the reference client fakes mute with volume 0 — confirm on device**) |
| Input | `settings:/kef/play/physicalSource` | `kefPhysicalSource`: `wifi`, `bluetooth`, `tv`, `optic`, `analog`, `usb` |
| Power | same source path | write `powerOn` to wake, `standby` to sleep |
| Power readback | `settings:/kef/host/speakerStatus` | `kefSpeakerStatus`: `standby` / **`powerOn`** (observed; reference clients say `poweredOn`, both accepted) |
| Identity | `settings:/releasetext` (`<MODEL>_<fw>`; `modelName` is a hardware code like `SP4025`, so the model comes from releasetext), `settings:/system/primaryMacAddress` | `string_` |
| Volume ceiling | `settings:/kef/host/maximumVolume` | `i32_`, optional |

Because waking is a *source write*, MyHome refuses volume/mute/input while the speaker is in standby (in the store, not only the UI) so nothing wakes it silently.

## Hardware findings (LS50 Wireless II, firmware 420.390…, qualified 2026-11-07)

* Mute write/readback, volume write/readback and input write/readback all work, unauthenticated, via the endpoints above. Mute does not change volume.
* **Volume is per input**: each source remembers its own level (observed 8, 30 and 95 on different inputs). Switching input changes the reported volume.
* **Power is slow and asymmetric**: after `standby`, `physicalSource` flips at once but `speakerStatus` stays `powerOn` for several seconds; `powerOn` takes 3–6 s to show. MyHome derives standby from `physicalSource == standby`, treats `powerOn` as a wake marker (not an input), and polls power readback up to `KEFConfig.powerSettleTimeout` (12 s). A wake sent while the speaker is still entering standby was ignored in one run; re-sending after it settled worked.
* State is readable in standby. The speaker also has a `networkStandby` power target (`powermanager:target`).

## Setup

1. Find the primary speaker's IPv4 address (router DHCP list).
2. Settings → Speakers → **Add Speaker…** (or Speakers sidebar → Add Speaker). Enter the address, optional name/room, **Test Connection** (identity reads only), then **Add Speaker**.
3. Re-adding the same speaker (same MAC) updates its address and keeps its name and room. Removing a speaker only deletes MyHome's local record.

## Qualification procedure (read-only first)

```bash
cd MyHomeApp && swift run KEFProbe <speaker-ip>
```

`KEFProbe` issues `getData` reads only. Record firmware and observed shapes here (no real MAC/IP in git). Then qualify writes one at a time at a low listening level: power, volume, mute/unmute without a level reset, each input, unreachable address, reconnect, app restart, packaged app.

### Validation record

| Item | Result |
|---|---|
| Firmware / model | Read-only probe 2026-11-07: releasetext `LS50WII_V41192`, hardware code `SP4025`, firmware `420.390.390.070.0000` |
| Authentication required | None: all reads returned HTTP 200 unauthenticated (`webserver:addUser` not implemented) |
| Mute path/type | `settings:/mediaPlayer/mute` → `bool_`, read and write confirmed |
| Inputs present on LS50W2 | `analog` observed as current source; others assumed, pending |
| State readable in standby | Yes |
| Volume limit path | `maximumVolume` = `i32_` (95 observed); `volumeLimit` is a `bool_` flag, not a number |

## Behaviour

* Refresh rides the existing poll cycle: 15 s for speakers on screen, ≥ 60 s otherwise; 3 s request timeout; one exchange per speaker; failures back off 30/60/120 s capped at 300 s; manual Refresh bypasses once. Defaults are `KEFConfig` (UserDefaults overrides, clamped).
* Writes are never replayed. After a write one readback decides the outcome; HTTP 200 alone is never "confirmed". Rapid volume changes coalesce (last intent wins) and stay ordered around power/input.
* A stale reading is labelled **stale**, never shown as current. Offline ≠ standby.
* Assistant: "turn on the living room speakers", "set KEF volume to 30 percent", "mute the speakers" / "unmute KEF", "switch KEF to TV", "what volume are the speakers at?".

## Troubleshooting

* *Needs Setup*: the speaker answered 401/403 — authentication is not implemented yet; record the response here and file the finding.
* *Offline*: address changed (re-add by address — name/room are kept) or speaker unreachable on the LAN.
* *Unsupported model*: only LS50 Wireless II is in scope.
