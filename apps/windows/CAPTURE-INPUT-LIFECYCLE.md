# Windows host — capture, input, session lifecycle and connecting

What the Windows host actually does now, and what is still waiting on a Windows machine.
`WINDOWS-HOST.md` is the historical feasibility study; where the two disagree, this file is the
later one. `protocol/PROTOCOL.md` and `protocol/API.md` remain the contract.

Written 2026-10-17 and extended 2026-10-18, from macOS. Nothing Windows-only in here has been
*run*. §0 and §6 are the signalling, authentication and account work; the rest is capture,
input and injection.

---

## 0. Connecting to the shipping Mac app

The host could not connect at all. `host.rs` ran no §2.17 exchange and built SDP answers with an
empty `fp`, `pubkey`, `sig` and `mac`; the Mac controller verifies all four, so every session
died at `bye{peer_auth_failed}`. Two more blockers were behind it: `register` carried a v1
access-code verifier, which a v5 server answers `bad_request`, and the shipping path reached a
compiled-in IP behind a certificate pin.

**The rules this layer holds to**

1. **The Mac's verification is never weakened.** `rc_identity::sdp::verify` is the function the
   Mac's own `SdpAuth.verify` reaches through `rc-ffi`, and it is the function
   `tests/signed_answer.rs` checks this host's answers against. Nothing here has its own idea
   of §2.12.
2. **No picture and no clicks until the code is proved *and* the owner agrees.** A
   `session_start` starts nothing: no peer connection, no capture. Only a verified exchange and,
   with unattended access off, an Allow does.
3. **A guess is paid for when the confirmation leaves, not when it fails.** Step 2 lets whoever
   sent step 1 check one guess offline, so both budgets are charged before it is sent and
   withdrawn only when step 3 verifies. A charge that cannot be *stored* refuses the exchange.
4. **Unattended access is off on a new install.** The access code says a controller *may*
   connect; whoever is at the PC says whether it connects now.
5. **One configured value.** The API base domain, with `wss://<domain>/ws` and the sign-in site
   derived from it. No address, no pin: ordinary public-CA validation, like the Mac.

**Where it lives**

| Concern | Crate / file | Tested here? |
|---|---|---|
| The one config value and everything derived from it | `rc-host/backend.rs` | yes |
| §2.17 exchange, both guess budgets, `bye` reasons | `rc-host/pake.rs` | yes |
| §2.12 signing, verification, candidate stripping | `rc-identity/sdp.rs` (shared) | yes |
| Whether a signed answer the Mac would accept comes out | `rc-host/tests/signed_answer.rs` | yes |
| A whole v5 session against the real Go server | `rc-host/tests/live_server.rs` | yes, needs `go` |
| §2.17 Consent at the console | `rc-host/consent.rs` | partly (the parsing) |
| Session wiring: holds, dispositions, teardown, reconnect | `rc-host/host.rs` | no |
| Account API, nonce binding, device token | `rc-host/{api,account}.rs` | the pure parts only |
| DPAPI, the user-only DACL, atomic writes | `rc-host/secrets.rs` | logic yes, DPAPI no |
| `skipperdesk://` registration | `rc-host/urlhandler.rs` | the hand-off only |

---

## 1. The rules this layer holds to

1. **No picture, no clicks.** Remote input is applied only while capture is live and the
   display geometry is known. Capture failure, a locked or secure desktop, or geometry that
   does not hang together each suspend input and release everything held.
2. **Never a substitute picture.** A synthetic screen is a diagnostic (`--synthetic`) and is
   only ever paired with the recording injector. Capture failure surfaces as *unavailable*.
3. **Coordinates are per-monitor; `SendInput` is per-virtual-desktop.** The translation
   between them is explicit and tested, including negative origins.
4. **The wire stays macOS-oriented.** `key_down.keycode` is a `kVK_*` code for every peer
   that exists; all translation is in `rc-input`, which has no `windows` dependency and runs
   its tests anywhere.
5. **Claim only what was measured.** The encode envelope comes from a measurement, and the
   measurement says which machine it was taken on.

## 2. Where things live

| Concern | Crate / file | Tested here? |
|---|---|---|
| Virtual-desktop geometry, `display_info` | `rc-input/geometry.rs` | yes |
| Mac -> Windows key policy | `rc-input/policy.rs` | yes |
| Keycode table, modifiers, scroll, gestures | `rc-input/{keycodes,modifiers,scroll,gestures}.rs` | yes |
| Held keys/buttons, suspension, `SendInput` failures | `rc-host/inject.rs` | yes |
| Capture -> encode -> track loop, cancellation, pacing | `rc-host/pump.rs`, `rc-host/media.rs` | yes |
| Session lifecycle, input gating, `display_info` publishing | `rc-host/host.rs` | no (needs signaling) |
| `SendInput` | `rc-host/inject_windows.rs` | compile-checked only |
| DXGI capture, primary display, DPI, secure desktop | `rc-host/capture_windows.rs` | compile-checked only |

## 3. Decisions worth knowing

**Primary display.** Adapter 0 / output 0 is not the primary display. The source searches
every adapter's attached outputs for `MONITORINFOF_PRIMARY` and creates the D3D11 device on
that output's own adapter, because `DuplicateOutput` requires it. `D3D11CreateDevice` is
called with `D3D_DRIVER_TYPE_UNKNOWN`, which is mandatory whenever an adapter is passed.

**Geometry changes.** A resolution change arrives as `DXGI_ERROR_ACCESS_LOST`. A **DPI**
change does not, so the geometry is also polled every 500 ms. Either one republishes
`display_info` and forces a keyframe.

**Secure desktop.** Detected from the input desktop's name (`Winlogon`), or from
`OpenInputDesktop` being refused — not inferred from a black frame. `E_ACCESSDENIED` from
`DuplicateOutput` means the same thing. Getting *past* it still needs the session-0 service
model (`WINDOWS-HOST.md` §3c).

**Held keys.** `key_down` presses and holds; `key_up` releases. A modifier arrives as its own
event (the controller forwards `flagsChanged` that way), and a lost modifier `key_up` is
healed from the next event's `mods`. Caps Lock and `fn` are never pressed.

**Termination.** Everything held is released on `input_reset`, on suspension, when capture
stops, on session teardown, when ICE closes or fails, and on Ctrl-C or the console window
being closed. The last one matters because process exit sends no key-up: `SendInput` injects
into the system input queue, so a host that dies with Ctrl down leaves Ctrl down. The console
Ctrl handler is Windows-only, so the Mac product's dependency graph gains nothing
(`signal-hook-registry` and `errno` appear in `Cargo.lock`, which records every target, but
are never compiled for macOS).

**Cancellation.** The pump is blocking, so `abort()` cannot stop it. It checks a stop flag
between frames and inside every sleep, and hands the frame source back on exit so the next
session can reuse it.

**Quality.** The controller's `quality` message is honoured through the Mac's ladder and gate
(`quality.rs`, pinned with the Mac by `protocol/vectors/quality-vectors.json`): `smooth` /
`auto` / `sharp` cap the encode width at 1280 / 1920 / 2560 and the bitrate at 1 / 2 / 8 Mbps,
30 fps, and the request is clamped to the account's `limits.maxQuality`, which a background
loop re-reads every `refreshAfterSec`; no entitlement, or one older than that, clamps to `auto`.
A change rebuilds the encoder at the new bitrate mid-session. Downscaling is separable area
averaging to the exact ladder size.

**Latency.** Capture and encode are separate threads with a one-frame slot between them; a new
frame replaces one the encoder has not reached, so a slow encoder drops frames rather than
queueing them. A frame openh264's rate control skips is offered again until it goes out or a
newer one replaces it, so the screen's last state is never lost to a skip. RTP timestamps
follow capture time (`RtpClock`), not a fixed per-frame duration. `RC_MEDIA_STATS=1` logs, each
second: which encoder is live, frames sent, skipped and dropped, encode time, and frame age at
encode and at send.

**Encode envelope.** Media Foundation hardware encode where the PC has it (WINDOWS-HOST.md,
*Media Foundation hardware encode*), otherwise openh264 configured for screen content with
bitrate rate control; `RC_ENCODER=software` forces openh264. When
the mean encode time over 30 frames exceeds the 33 ms budget, the encode size steps down one
ladder rung (sharp → auto → smooth size, bitrate unchanged); it steps back up after three
windows in which the measured cost scaled to the rung above would fit 80% of the budget.
Measured on macOS/arm64, release, 30 synthetic desktop frames:

| source | mean encode | fits 30 fps |
|---|---|---|
| 3840x2160 | 46.6 ms | no (21 fps ceiling) |
| 2560x1440 | 20.4 ms | yes |
| 1920x1080 | 14.0 ms | yes |
| 1280x720 | 9.9 ms | yes |

A Windows CPU moves every row, which is why the runtime measurement decides and the constant
is only a starting point.

**Keyframes.** Forced on the first frame of a session, on a resolution/DPI change, when
capture returns from unavailable, and on an RTCP PLI or FIR from the peer. Nothing read the
sender's RTCP before, so a decoder that lost reference frames stayed broken for the session.

**Advertised level.** `profile-level-id=42e032` — constrained baseline, level 5.0 — because
level 3.1 caps at 1280x720 and this host sends up to 2560x1440. RFC 6184 §8.2.2 exempts the
level from symmetric use.

## 4. Still needs a real Windows machine

- Every line of `capture_windows.rs` and `inject_windows.rs` at runtime: DXGI duplication,
  dirty rects, the `LastPresentTime == 0` cursor-move skip, DPI scale, the secure-desktop
  check, and `SendInput` actually moving the pointer and typing.
- Clicks landing on the right monitor on a multi-monitor PC, and on a scaled display.
- Held modifiers, repeat, drag and non-ASCII text against real Windows applications.
- Whether software encode keeps up on the target PC, and therefore whether the Media
  Foundation hardware path is needed before this ships.
- UIPI: whether `SendInput` reaches elevated windows with the `requireAdministrator`
  manifest, and what the refusal path logs when it does not.

## 5. Not built

**Media Foundation hardware encode.** The encoder seam (`VideoEncoder`, `EncoderFactory`)
exists and the software path is behind it, so this is a self-contained later change. It is not
written, deliberately: a hardware MFT encoder is several hundred lines of COM that cannot be
exercised at all from macOS — not even smoke-tested — and this host's one previous contact
with real Windows was a crash. The measured cap and step-down are what keep the software path
from being the catastrophe in the meantime.

**Bitrate adaptation.** The encoder's target bitrate is the permitted mode's ceiling. Nothing
feeds a bandwidth estimate back into it, so unlike libwebrtc on the Mac it does not move
between the mode's floor and ceiling under congestion.

---

## 6. Connecting: what a real session still needs

**A mid-session TURN adoption this host cannot do.** §2.18 pushes the session's relay
credentials when metering starts — which is the host's own first `sdp`, so its peer connection
already exists and has already gathered. libwebrtc lets the Mac adopt them with
`setConfiguration`; webrtc-rs 0.11 does not have it at all (`set_configuration` is commented
out in `peer_connection/mod.rs`, and it would only update a stored field anyway, since the
gatherer is built with the connection). So:

- The credentials are kept for the session and used by the *next* connection in it — a resume,
  or a rebuilt peer — and dropped when the session ends, as §2.5 requires.
- Meanwhile the media path relies on the **controller's** relay candidate. One side's relay is
  enough for the ordinary NAT cases, including symmetric NAT on this side, because this host
  sends to the relay's public address and the relay forwards.
- It is **not** enough when UDP is blocked outbound on the Windows side, which is what TURN/TCP
  from the host would cover. `RC_ICE_POLICY=relay` cannot help on a first attempt either: it
  needs credentials at construction time.

Fixing it properly means either a webrtc-rs version with `set_configuration` and a rebuildable
gatherer, or holding the peer connection somewhere it can be handed out mutably. Neither is a
protocol change.

**Still unexercised, and needs a real Windows machine:** DPAPI (`CryptProtectData`), the
user-only DACL (`SetNamedSecurityInfoW`), the `HKCU` `skipperdesk://` registration and the
two-process hand-off through it, `MachineGuid` as the `hardwareId`, and `cmd /C start` opening
the browser.

**Still unexercised, and needs a real backend:** every HTTP call in `api.rs`. The whole account
leg — challenge, token, refresh, entitlement, sign-out — is compile-checked and unit-tested on
its pure parts (nonce shape, URL building, callback validation, response decoding) and has
never spoken to rc-api.

**`platform=windows` needs no change.** The production page reads the parameter, validates it
against `/^[a-z][a-z0-9]{1,15}$/`, and defaults to `macos` only when it is absent — so
`windows` is accepted today. The value the device record actually gets comes from the token
request body, which also says `windows`. Two things worth knowing and not changed here: the
page's copy is Mac-worded throughout ("That Mac is signed in to another account"), and
`GET /v1/app/releases/latest` still allowlists `macos` only
(`server/internal/apisrv/releases.go`), so a Windows updater cannot use the release feed until
that slice gains `protocol.PlatformWindows`. Both are the owner's to deploy.

**The consent prompt is a console prompt.** It reads `y`/`n` from stdin; a bare Enter is not an
answer. That is the right shape for a console host but it is not a notification, so an owner
who has minimised the window will not see it and the request will time out after 30 s. A tray
icon or a toast is the real answer and is not built.
