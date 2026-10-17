# Windows host — capture, input and session lifecycle

What the Windows host's capture, injection and session lifecycle actually do now, and what is
still waiting on a Windows machine. `WINDOWS-HOST.md` is the historical feasibility study;
where the two disagree, this file is the later one. `protocol/PROTOCOL.md` and
`protocol/API.md` remain the contract.

Written 2026-10-17, from macOS. Nothing Windows-only in here has been *run*.

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

**Cancellation.** The pump is blocking, so `abort()` cannot stop it. It checks a stop flag
between frames and inside every sleep, and hands the frame source back on exit so the next
session can reuse it.

**Encode envelope.** openh264 configured for screen content with bitrate rate control. The
cap is 2560 on the longest edge; `Pacing` measures the real encode cost and steps the frame
rate, then the resolution, down when it does not fit 80% of the frame budget. Measured on
macOS/arm64, release, 30 synthetic desktop frames:

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

**Bitrate adaptation.** The encoder's target bitrate is fixed from config. Nothing feeds a
bandwidth estimate back into it, and the `quality` ctrl message (§5) is not handled.
