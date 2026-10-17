# Windows host — feasibility and design considerations

Goal: control a **Windows PC from the existing Mac controller**, reusing the deployed
`rc-signal` + coturn stack unchanged. Host role only (Windows is controlled; it does not
control).

> **PARKED (2026-09-16).** The user ran the bundle on a Windows PC and it kept crashing. It has never
> been debugged on real Windows, and Windows is not the current goal. Everything below is the
> state as of 2026-09-03. Resume only with a Windows machine to test on.
>
> **Partly superseded (2026-10-17).** Capture, input and the session lifecycle were reworked;
> see `CAPTURE-INPUT-LIFECYCLE.md`, which is the later document where the two disagree. The
> analysis below still stands as analysis.

**Status (historical): in progress.** See §10 for the phase log. The design below is now the plan of
record, not a survey; where building it has already contradicted the analysis, §10 says so.

---

## 1. Server: zero changes required

Verified by reading `server/`, `protocol/protocol.go` and `protocol/PROTOCOL.md`:

- `register` / `hello` carry **no platform field**. The server stores a pubkey, a 9-digit
  `deviceId`, an Argon2id verifier and a free-text `label`. It has no concept of macOS.
- The server **never sees** the `ctrl` or `hi` data channels (PROTOCOL.md preamble). Every
  Mac-specific payload is peer-to-peer.
- coturn issues REST credentials against a shared secret; STUN/TURN is OS-agnostic.

The Windows host registers itself like any other device and gets its own Device ID and its
own access code. **Nothing on the t2.medium gets touched.**

Two things it must embed, from `RCConfig`:

| | |
|---|---|
| Signaling URL | `wss://54.246.73.81:8443/ws` |
| Cert pin (SHA-256, DER, base64) | `E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk=` |

Pinning replaces CA validation — the cert is self-signed and its SAN is bound to the IP.
In Go/Rust that is `InsecureSkipVerify` + a `VerifyPeerCertificate` hook comparing the
SHA-256 of the leaf DER. **Do not** skip verification without the pin check.

One capacity note: coturn is at `user-quota=6 / total-quota=12`. A third device is well
inside that.

---

## 2. What is actually macOS-coupled in the wire protocol

Only two things. Both are host-side reinterpretation — **the Mac controller does not change.**

### 2.1 `key_down.keycode` is a macOS virtual keycode (`kVK_*`)

PROTOCOL.md §5 pins this. The Windows host needs a `kVK_* → VK_*` table (~110 entries,
mechanical).

**Do not build the whole input path on that table.** `key_down` also carries an optional
`chars:string`. For printable input, inject via `SendInput` with `KEYEVENTF_UNICODE` and
ignore the keycode entirely — that sidesteps every keyboard-layout mismatch. Use the
keycode table only for non-printing keys and shortcut chords.

**Modifier collision — needs an explicit decision.** The `mods` bitmask is
`1 shift, 2 control, 4 option, 8 command, 16 capslock, 32 fn`. On Windows:

| Mac | Windows | Why |
|---|---|---|
| Command (8) | **Ctrl** | Otherwise ⌘C does not copy. Mapping to Win would be useless. |
| Control (2) | **Ctrl** | Collapses with the above. Acceptable — a Mac user reaches for ⌘. |
| Option (4) | Alt | |
| Shift (1) | Shift | |
| fn (32) | *dropped* | No analogue. |
| — | Win key | Unreachable from a Mac keyboard except via the gesture palette. |

The Cmd/Ctrl collapse means ⌃-chords that differ from ⌘-chords are indistinguishable on
Windows. In practice that only bites in terminals (⌃C vs ⌘C). If it matters, route ⌃
through the gesture palette rather than un-collapsing.

### 2.2 `gesture.name` is a macOS-flavoured enum

The names stay on the wire; the host reinterprets. All nine map:

| Wire name | Windows |
|---|---|
| `mission_control` | Task View — `Win+Tab` |
| `app_expose` | `Win+Tab` (no true analogue) |
| `show_desktop` | `Win+D` |
| `launchpad` | Start menu — `Win` |
| `spotlight` | Search — `Win+S` |
| `app_switcher` | `Alt+Tab` |
| `screenshot_region` | `Win+Shift+S` |
| `force_quit` | Task Manager — `Ctrl+Shift+Esc` |
| `lock_screen` | `Win+L` |

### 2.3 The one protocol change I would make

The Mac's gesture palette labels say "Mission Control", "Spotlight". Against a Windows host
they should say "Task View", "Search". That needs the controller to know the host's OS.

Add an **optional** `os:string` to `display_info` (§5). PROTOCOL.md §0 already mandates
"receivers must ignore unknown object members", so this is purely additive — **no version
bump, no server change, old builds keep working.** Absent field ⇒ assume macOS.

### 2.4 Two conventions that will silently be wrong if not handled

- **Scroll sign.** §5: positive `dy` = content moves up (macOS natural). Windows
  `WM_MOUSEWHEEL` is the opposite. The host must invert.
- **Scroll units.** The Mac sends *pixel-precise* deltas. Windows is notch-based
  (`WHEEL_DELTA` = 120). Truncating small trackpad deltas to zero makes fine scrolling dead.
  Accumulate the fractional remainder across events and emit residual-carrying deltas.

Coordinates are already normalised `[0,1]`, which maps directly onto `SendInput`'s
`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK` 0–65535 space. That part is free.

---

## 3. The hard part: UAC, UIPI and the secure desktop

This is the **single biggest architectural difference from macOS**, and it has no equivalent
in anything we have built so far.

1. **UIPI.** A non-elevated process's `SendInput` is *silently ignored* by elevated windows.
   Control an app running as admin and the mouse just does nothing, with no error.
2. **Secure desktop.** When a UAC prompt appears, Windows switches desktops. Both
   Windows.Graphics.Capture and DXGI Desktop Duplication go black. The prompt is
   unclickable and invisible.
3. **Lock screen / logged out.** Same problem, permanently.

Options, in ascending cost:

| | Approach | Gets you | Costs |
|---|---|---|---|
| **a** | Plain user-level app | Normal desktop only | Free. UAC prompts brick the session. |
| **b** | `requireAdministrator` manifest | Beats UIPI; can attach to `WinSta0\Winlogon` | One manifest line + a UAC prompt at launch. **Recommended for v1.** |
| **c** | Service in session 0 spawning a per-session agent via `CreateProcessAsUser`, re-spawning onto the secure desktop | Everything, incl. lock screen | This is how AnyDesk works. Substantial — an installer, service lifecycle, desktop switching. |

Take (b). It removes the failure mode you would hit first (clicking anything elevated) for
almost no work. Defer (c) until "I need to get past the lock screen" is a real requirement.

**The upside:** Windows has **no TCC**. No Screen Recording grant, no Accessibility grant,
no code-signature-bound permissions, none of the three debugging sessions we lost to stale
grants. Windows Firewall will offer a prompt on first run — you can **decline it**, the host
only makes outbound connections.

---

## 4. Stack choice

The decision hinges on one fact that is easy to get wrong:

> **Upstream libwebrtc has no hardware H.264 encoder on Windows.** It uses OpenH264
> (software) for encode. Encoding 1920×1200@30 in software is exactly the 93% CPU
> catastrophe we already fixed once on the Mac.

So a custom `VideoEncoderFactory` wrapping Media Foundation / NVENC / AMF is **unavoidable
on every path**. That removes libwebrtc's main advantage and makes the deciding factor
*which stack has the least painful Win32/COM interop.*

**Recommendation: Rust — `webrtc-rs` + the `windows` crate.**

- The `windows` crate gives generated, type-safe COM bindings for Desktop Duplication,
  Media Foundation and `SendInput`. cgo-based COM in Go is materially worse; C++ means
  writing the signaling client, the pinning and the state machine in C++.
- `webrtc-rs` is a port of Pion and interops with libwebrtc in the field.
- Single static `.exe`, no runtime.

Fallback trigger, stated up front: if H.264 **rate control** against the Mac's decoder
proves unstable (congestion response, PLI handling, keyframe cadence), swap only the media
layer for prebuilt libwebrtc M125 — matching the Mac's `stasel/WebRTC` 125.0.0 — behind a
thin C shim, and keep signaling/input/capture in Rust.

### Capture: prefer DXGI Desktop Duplication over WGC

`IDXGIOutputDuplication` gives **native dirty rects** — the same signal
`ScreenCaptureSource.swift` uses for idle throttling, so the efficiency budget in PLAN.md §5
ports directly. It also draws no yellow capture border (WGC does, and only Win11 lets you
turn it off). Both die on the secure desktop equally.

### SDP compatibility

`VideoCodecPreference.swift:122` reasons that "the only peers in this product are Apple
Silicon Macs running this same binary" and unconditionally raises the advertised
`profile-level-id` level to 5.2. That is safe for the Mac's *own* line (it claims decode
capability, and Apple Silicon can). **The risk is the Windows host reading that and
encoding beyond what its MFT supports.** The Windows host should advertise its own honest
`42e01f` (constrained baseline, level 3.1), `packetization-mode=1`, and clamp its encoder
to its real capability regardless of what the peer advertises.

---

## 5. Reuse: what ports and what must be rewritten

| Layer | Windows host |
|---|---|
| Wire types | **`protocol/protocol.go` already has the full `ctrl` + `hi` types.** Port or transliterate — it is 516 lines and already normative. |
| Argon2id verifier, P-256 identity, Crockford access codes | Standard crates (`argon2`, `p256`, `base32`). Well-specified in §2.3. |
| Cert pinning | ~20 lines. |
| **Session state machine** | **Highest-risk rewrite.** `SessionStateMachine.swift` is where flutter tolerance, resume, and the stale-session fix live, and it has the deepest test coverage. |
| Capture / encode / input / clipboard / keep-awake | Fully rewritten — all OS-specific. |

**On the state machine — do this, not a blind reimplementation.** Extract the existing Swift
tests into a **JSON test-vector file** (`input event → expected [SessionAction]`) and run it
from *both* the Swift and Rust suites. That is the only way to get falsifiable parity rather
than two implementations that each pass their own tests and disagree in the field. It also
retro-fits real coverage onto the Swift side.

Keep-awake is the one easy port: `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED
| ES_DISPLAY_REQUIRED)` is a direct analogue of `StayAwake.swift`'s `IOPMAssertion`. Note it
**cannot wake a sleeping machine** — same limitation as macOS. Waking needs Wake-on-LAN from
a device on the same LAN, which is out of scope.

---

## 6. What the Mac side needs (small, but not zero)

1. **`AppSettings.savedPeerDeviceID` is a single `String`.** With two hosts (boss's Mac +
   Windows PC) you would retype the Device ID every time you switch. Needs a small peer
   *list* — a `[Peer]` Codable in defaults plus a picker.
2. `AppRole.displayName` says "Control Another Mac" — cosmetic relabel.
3. Gesture palette labels keyed off the new `display_info.os`.
4. **Strict 1:1 still holds.** One session at a time, so controlling Windows means
   disconnecting from the other Mac first. That is by design, not a bug.

Transport, signaling, crypto and capture on the Mac need no changes.

---

## 7. Distribution

No Gatekeeper, no notarization, no `xattr -cr`. Instead: **SmartScreen** shows "Windows
protected your PC" for an unsigned `.exe` → *More info* → *Run anyway*. Comparable friction,
but per-download rather than per-install.

The Apple Developer account does **not** help here — Authenticode needs a separate
code-signing certificate. Azure Trusted Signing (~$10/mo) is the cheap route; an EV cert
gets instant SmartScreen reputation, an OV cert accrues it over time. Not required for two
machines.

---

## 8. Rough sizing

Assumes option (b) elevation, Rust, no service model.

| | LOC |
|---|---|
| Signaling client + pinning + identity + access codes | ~900 |
| Session state machine (ported, vector-tested) | ~700 |
| WebRTC peer session, two data channels, video track | ~500 |
| Desktop Duplication capture + dirty-rect idle throttle | ~600 |
| Media Foundation H.264 encoder + rate control | ~800 ← **the risk concentrates here** |
| `SendInput` injector, keycode table, gestures, scroll accumulator | ~700 |
| Clipboard, keep-awake, tray UI, config | ~500 |
| **Total** | **≈4,700** |

Comparable to the ~10,500 Swift lines, which is consistent: the Windows side has no
controller UI, no video *rendering*, and no permissions system.

## 9. Verdict

Feasible, and the server genuinely does not get touched. The work is a real client build,
not a port — roughly half the Mac codebase. The two things that will actually hurt are the
**Media Foundation encoder + rate control** (where our one prior catastrophe lives) and
**UAC/UIPI**, which has no macOS analogue and should be met with the `requireAdministrator`
manifest rather than a service on day one.


---

## 10. Phase log

Code lives in `apps/windows/`, part of the root Cargo workspace. Run `cargo test --workspace` from the repo root for the host-testable
suites and `cargo check --target x86_64-pc-windows-msvc` for the Windows-only code.

### The verification approach

The single most useful thing established up front: **`cargo check --target
x86_64-pc-windows-msvc` type-checks real Win32 COM code from macOS.** A probe exercising
`IDXGIOutputDuplication`, `D3D11CreateDevice`, `MFStartup`, `SendInput` and
`SetThreadExecutionState` compiles clean here. `cargo check` does not link, so no MSVC
toolchain is needed. That means the Windows-only layers are written against a real compiler
rather than blind, and only their *runtime* behaviour waits on a Windows machine.

Everything that can be wrong in a way a compiler cannot catch is deliberately pushed into
platform-neutral crates that run their tests on any machine.

### W1 — wire protocol · **done**

`crates/rc-proto`: the full contract from PROTOCOL.md — envelope, all 26 signaling payloads,
all 15 `ctrl` types, the `hi` channel. `#![forbid(unsafe_code)]`, no OS dependency, no async
runtime.

**Cross-implementation parity is enforced, not asserted.** `protocol/vectors/gen.go` emits
70 frames from the *Go* types — the encoding the deployed `rc-signal` actually speaks and
the Swift client already interoperates with. `core/crates/rc-proto/tests/vectors.rs` decodes
every one into the Rust type, re-encodes it, and requires semantic equality. A renamed
field, a lost `omitempty`, a narrowed integer or a misspelled `type` fails there rather than
against a live server.

Round-tripping rather than merely decoding matters: a decode-only test passes while silently
dropping every field the Rust struct forgot to declare.

Two findings from actually running it:

- **The vectors caught a real bug on their first run.** Go encodes a nil slice as `null`,
  and `iceServers` has no `omitempty` — so a server with no TURN configured really does send
  `"iceServers": null`, which `#[serde(default)]` alone rejects (it covers an absent key, not
  an explicit null). This would have failed against the live server.
- Number equality needed care. Go writes `float64(2)` as `2`, serde writes `2.0`. Comparing
  through `f64` would fix that but would also make 9007199254740993 compare equal to
  ...992, hiding a genuine `seq` precision bug. Integers compare as integers, floats as floats.

Proven non-vacuous by mutation: renaming `memKiB`, dropping `chars`' `omitempty`, and
narrowing `seq` to `i32` each fail the suite; reverting restores it.

### W2 — input translation · **done**

`crates/rc-input`: the whole macOS→Windows semantic bridge, with **no `windows` dependency**
so its tests run here. 24 tests, all six attempted mutations caught.

- **Keycodes.** Full `kVK_*` → `VK_*` table carrying the `KEYEVENTF_EXTENDEDKEY` flag, which
  is not optional: without it the arrow cluster collides with the numpad when Num Lock is
  off and Right-Alt behaves as Left-Alt. A coverage test asserts every assigned code in
  `0x00..=0x7E` either maps or appears on an explicit intentionally-unmapped list, so a gap
  is a decision rather than an oversight.
- **`chars` over keycodes.** `should_inject_as_text` gates it: printable text with no chord
  modifier is injected as Unicode, sidestepping keyboard layout entirely. Anything with
  Command/Control/Option is a shortcut and takes the keycode path — injecting "c" instead of
  Ctrl+C is precisely the bug the gate exists to prevent.
- **Modifiers.** Command→Control by default, behind a named `CommandPolicy` rather than
  buried in a match arm. Two things the analysis in §2.1 did not anticipate, both found while
  writing it:
  - **⌘ and ⌃ together must deduplicate.** Both map to Control; emitting it twice leaves a
    stuck key, because a chord is released in reverse and a duplicate press is released once.
  - **Caps Lock must never be pressed.** macOS reports it as a *state*, Windows treats
    `VK_CAPITAL` as a *toggle*. Honouring the bit would flip the host's caps state on every
    keystroke and leave it stuck on. The shift bit already carries the intent.
- **Scroll.** Sign inversion (§2.4) plus a remainder-carrying accumulator. The failure it
  prevents is concrete: 60 events of half a pixel each, every one truncating to zero, so a
  slow trackpad drag scrolls nothing at all. A property test asserts emitted units plus
  banked remainder always equals the exact conversion, so no travel leaks.
- **Gestures.** All nine chords, and a test that the *only* chord collision is the documented
  Mission Control / App Exposé pair.
- **Coordinates.** Normalised `[0,1]` → `SendInput`'s 0–65535 absolute space maps directly,
  clamped and NaN-safe.

### Protocol change made

`display_info.os` (§2.3) is now in **PROTOCOL.md, the Go mirror, and the Rust types**, with
two vectors covering present-and-absent. Purely additive; the deployed server never parses
`ctrl` messages, so **no redeploy is needed** and the Mac build is unaffected. `server/`
still builds clean against the updated `protocol` package — verified.

### W3 — session state machine · **done**

`crates/rc-session`: a faithful port of `SessionStateMachine.swift` — the file carrying the
field-paid-for fixes (stale-session dead end, busy-retry-once, flutter rules, the
45-second failure grace). Same shape: no I/O, no timers, every method returns the actions
the owner must perform; time is Unix milliseconds.

**Held equal to the Swift machine by execution, not review.**
`protocol/vectors/session-scenarios.json` (37 scenarios, 218 steps, generated by
`gen_session_scenarios.py`) is run by BOTH suites:

- Swift: `StateMachineScenarioTests.swift`, registered in the app's suite (now 262/262).
  This run is what makes the vector file trustworthy — it pins the file to the proven
  implementation.
- Rust: `crates/rc-session/tests/scenarios.rs`.

Mutation results on the Rust port: host-as-offerer, stale-cleanup firing on closed
sessions, an off-by-one on the failure grace, the dropped 1-second rate-limit floor, and
input-reset spam on up-to-up ICE transitions were all caught. One mutation — removing the
busy-retry-once guard — **survived** the first vector set: no scenario exercised the guard
through a signaling flap, which is exactly the infinite bye/connect/busy loop it exists to
prevent. A `the_busy_retry_guard_survives_a_signaling_flap` scenario was added; the
mutation is now caught, and both languages pass the updated file.

### The toolchain decision, revised

The analysis in §4 assumed the `-msvc` target. In practice `ring` (pulled in by rustls and
webrtc-rs) needs the Windows CRT headers to build its C under `-msvc` cross-compilation, and
those ship only with the Windows SDK. The fix was **`x86_64-pc-windows-gnu` + mingw-w64**
(`brew install mingw-w64`), which carries its own headers. This turned out strictly better
than planned: the gnu toolchain doesn't just type-check, it **links a real
`rc-host.exe` from this Mac** (283 MB debug). The `windows` crate supports the gnu ABI via
its prebuilt import libraries, so the whole Win32 surface is available.

The other revision: **openh264** (software H.264, builds and cross-compiles cleanly, real
Annex-B verified) is the baseline encoder rather than a Media-Foundation-first design. It
works on every platform this binary targets, which is what lets the interop harness run on
macOS. Media Foundation hardware encode remains the Windows-only optimisation behind the
same `FrameSource`/encoder seam — and the openh264 path is exactly why the CPU trap from
§4 must be watched: it is software encode.

### W4 — signaling client · **done**

`crates/rc-signal-client`: pinned WSS, challenge auth, request/reply correlation, typed
pushes. `crates/rc-identity`: P-256 keypair, Crockford access codes, Argon2id verifiers, the
identity file (same schema as the Mac's `identity.json`).

Both are verified against the **real Go server**, not mocks:
- `rc-identity/tests/server_compat.rs` runs the material through `auth.VerifyDeviceSig` and
  `auth.VerifyCode` — the production verifiers — via a new `server/cmd/rustcompat`, asserting
  the negative direction too (tampered sig rejected, wrong code rejected).
- `rc-signal-client/tests/live_server.rs` boots an actual `rc-signal` binary and drives two
  Rust clients through register → hello → watch/presence → connect → bad-code rejection →
  sdp/ice relay → renew → bye. Finding: the server pushes ambient `challenge` frames and a
  `peer_state{attached}` the first draft didn't model — both now asserted.
- The pin is proven load-bearing: a one-bit-wrong pin fails the TLS handshake.
- `examples/live-probe.rs` did a zero-footprint pinned handshake against the **production**
  server — passed.

### W5 — WebRTC transport · **done (loopback-proven)**

`crates/rc-transport`: the **answerer** seat (the Mac controller offers). Receives the
in-band `ctrl`/`hi` channels, attaches an H.264 sample track to the offered m-line, relays
ICE, exposes one `TransportEvent` stream. `tests/loopback.rs` stands up a Mac-shaped offerer
(recvonly video, ordered `ctrl`, `maxRetransmits:0` `hi`) against the real `PeerSession` and
drives a full negotiation over loopback — ICE, DTLS, SCTP and SRTP all execute for real:
channels open, `ctrl`/`hi` frames flow both ways, and H.264 RTP is delivered to the peer's
track. What loopback can't prove is Google-libwebrtc interop; that is the synthetic-host run
against the actual Mac app (below).

### W6/W7 — capture, encode, injection · **done bar the Windows-only capture backend**

`crates/rc-host` is the runtime, generic over an `Injector` and a `FrameSource`:
- **Injection** is fully built and cross-compiles: `InputDispatcher` turns `ctrl`/`hi`
  messages into ordered `InputOp`s (11 dispatch tests — chord order, the `hi` seq gate,
  drag-without-button, scroll accumulation), and `WindowsInjector` (cfg(windows)) performs
  them via `SendInput`. `RecordingInjector` makes the dispatch logic testable everywhere.
- **Encode** is built (openh264) and the frame pump wires it to the track.
- **Keep-awake** is `SetThreadExecutionState`, the direct analogue of `StayAwake.swift`.
- **Capture**: `SyntheticSource` (a moving gradient) works now; DXGI Desktop Duplication is
  the one remaining Windows-only backend behind the `FrameSource` trait.

**End-to-end against production:** `rc-host --synthetic` — the real runtime with a synthetic
screen — connected to the **live server**, registered (device `892992974`), and came online
as a host waiting for a controller. Crypto, signaling and pinning all validated against the
deployed box. (This left one throwaway device record on the server; harmless, no session,
`gptc` untouched.)

### W6 capture + W8 packaging · **done (blind; needs a Windows run to confirm)**

Since the plan was "bundle now, test on a real PC later", the Windows-only pieces were
written against the cross-compiler and packaged:

- **DXGI Desktop Duplication capture** (`capture_windows.rs`): the real screen source —
  `AcquireNextFrame` with a 15 ms coalescing timeout, staging-texture copy, BGRA→RGB. It
  fails *safe*: `WAIT_TIMEOUT` (idle screen) and `ACCESS_LOST` (resolution change / UAC
  desktop switch) rebuild the duplication object rather than erroring, and a hard failure
  falls back to the test pattern rather than refusing to come online. Cross-compiles clean;
  the linked `.exe` imports `d3d11.dll`/`dxgi.dll`, confirming the path is really in there.
  Its *runtime* behaviour (dirty rects, the secure-desktop black frame) can only be seen on
  Windows.
- **UAC elevation** (`requireAdministrator` manifest + `build.rs` windres embed): verified
  present in the shipped `.exe` (the `requireadministrator` string survives strip). This is
  the UIPI fix from §3.
- **Runtime selection** (`main.rs`): real host uses `DxgiCaptureSource` + `WindowsInjector`;
  `--synthetic` and non-Windows builds use the portable path. A launch banner prints the
  Device ID + access code the way the Mac host window does.

**Bundle:** `apps/windows/dist/RemoteControl-WindowsHost.zip` — a stripped 16 MB `RemoteControl-Host.exe`
plus a `READ ME FIRST.txt` (SmartScreen "Run anyway", the UAC yes, where the code shows).
Release build, openh264 + webrtc-rs, server unchanged.

### Remaining (needs a Windows machine, or is packaging)

- **DXGI Desktop Duplication capture backend** — the code slots behind `FrameSource`;
  its runtime behaviour (dirty rects, the secure-desktop black-frame) can only be seen on
  Windows.
- **Runtime validation of `SendInput` and keep-awake** — they compile and link; they must
  be *run* on Windows.
- **libwebrtc interop** — point the synthetic host at the real Mac controller and confirm
  the Mac decodes the openh264 stream and the host applies the Mac's input. Loopback proves
  the Rust-to-Rust path; this proves Rust-to-libwebrtc.
- **W8**: `requireAdministrator` manifest (the UIPI fix from §3), a tray UI, and packaging.

### What is verifiable-from-macOS is done and green

`cargo test --workspace` (repo root) → 45 tests across 7 crates (all still green after the capture/packaging work). `cargo build --target
x86_64-pc-windows-gnu -p rc-host` → a linked `rc-host.exe`. The wire, the session logic, the
input translation, the crypto and the signaling are all held to the real server and the real
Mac state machine by executable cross-checks, not by inspection.

---

## 11. Private beta ZIP (unsigned)

A portable x64 ZIP for handing a build to a friend's PC. **It is unsigned and private**: there is
no installer, no Authenticode certificate, and it must not be linked from the public website.
Windows will warn about it; `README.txt` inside the ZIP tells the tester how to unblock it.

```
./scripts/package-windows.sh
```

Run on the Mac (needs `rustup target add x86_64-pc-windows-gnu` and `brew install mingw-w64`). It
builds `rc-host` for `x86_64-pc-windows-gnu`, checks the result is an x64 PE, copies the mingw
runtime DLLs the executable actually imports (found by reading its import table, transitively),
adds `THIRD-PARTY-NOTICES.txt` and `README.txt` (sources in `apps/windows/package/`), and writes
`dist/SkipperDesk-win-x64-<version>.zip` with its SHA-256. It fails if the executable or a
required DLL is missing. The build asks for administrator rights on launch (UAC), as in section 3.

Share the ZIP privately (a direct message or a private link), send the SHA-256 alongside it, and
tell the tester to unblock the ZIP before extracting. `infra/web/deploy.sh` leaves `*.zip` under
`assets/` alone, but nothing uploads this ZIP for you. Signing and an installer come later.
