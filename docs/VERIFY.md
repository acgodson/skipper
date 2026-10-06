# Two-Mac verification (Phase 1-2 acceptance)

Per `docs/DECISIONS.md`, a phase only counts once it has been observed working
between two real Macs. This is that checklist. Everything else (unit tests,
`swift run rc-tests`, the shared protocol vectors, `scripts/smoke-signal.sh`)
has already passed locally — this is the part a script cannot fake.

## Setup

**Host Mac** (runs the backend, will also usually host the session):

```sh
./scripts/dev-tunnel.sh
```

Leave it running. It prints a `https://<random>.trycloudflare.com` URL, writes
it to `dist/tunnel-url.txt`, and verifies `/healthz` and a WebSocket upgrade on
`/ws` succeed through the tunnel before handing control back.

Build and package once:

```sh
./scripts/make-verify-bundle.sh
```

This produces `dist/verify-bundle/` (the dmg, `launch-with-backend.sh`, and a
`README.txt`) — copy that whole folder to the **second Mac** (AirDrop, USB, or
`scp`; not a browser download, which adds a quarantine flag). Follow its
`README.txt` to install, then on either Mac launch pointed at the tunnel:

```sh
./scripts/launch-with-backend.sh https://<random>.trycloudflare.com
```

Add `--debug` to set `RC_DEBUG=1` and write a log file (path printed on
launch — see **Logs** below).

Re-run `./scripts/dev-tunnel.sh` any time the tunnel needs restarting; the URL
changes every run, so re-launch both apps with the new one.

## Checklist

Each item: the exact expected observation, and what to capture as evidence.

1. **Host sign-in.** On the host Mac, start the browser sign-in flow from the
   app. Expected: the flow completes in the browser and the app reflects it
   without further action.
   Evidence: screenshot of the browser's final "linked" page, and of the app
   immediately after.

2. **Host shows "Online" and the plan line.** After sign-in, the host's own
   window shows connection state "Online" and a line naming the current plan.
   Evidence: screenshot of the host window.

3. **Controller connects with Device ID + code.** On the controller Mac,
   enter the host's Device ID and access code with no prior sign-in. Expected:
   session establishes and the host's screen appears.
   Evidence: screenshot of the controller mid-session, and the host's Device
   ID visible in the same screenshot or a paired one.

4. **Wrong code refused.** Enter an intentionally wrong access code. Expected:
   the controller shows the sentence "Wrong access code. Check it on the other
   Mac." and does not connect.
   Evidence: screenshot of that message.

5. **Five wrong codes lock out.** Repeat #4 five times in a row (same host,
   same controller identity). Expected: after the fifth attempt, the host
   refuses further attempts (lockout), not just another "wrong code" message.
   Evidence: screenshot of the lockout state, and the host's log line marking
   the lockout.

6. **Reconnect with remembered code needs no typing.** After a prior
   successful connect, close and reopen the session from the same controller.
   Expected: no code prompt — it reconnects directly.
   Evidence: screen recording or two screenshots (closing, then reconnected)
   showing no code entry step.

7. **Refresh code -> controller asked again.** On the host, press "Refresh
   Access Code" (or "Refresh code"). Expected: the previously-remembered
   controller is now asked for a code again on its next connect.
   Evidence: screenshot of the host after refreshing (new code shown), and of
   the controller being prompted again.

8. **Trusted controller list, per-row Remove.** On the host, open the trusted
   controllers list; the controller from #3/#6 appears as a row. Click
   "Remove" on that row. Expected: the row disappears immediately, and that
   controller's remembered code stops working (falls back to #4's flow).
   Evidence: screenshot before and after Remove.

9. **Drag a window by its title bar.** From the controller, drag a host
   window by its title bar. Expected: the window actually moves on the host
   (not just a click-through).
   Evidence: two screenshots of the host desktop, window in different
   positions.

10. **Scroll a long page.** From the controller, scroll a long web page or
    document on the host. Expected: smooth, pixel-accurate scrolling, not
    single large jumps.
    Evidence: short screen recording.

11. **⌘Space via "Send shortcuts".** Turn on the controller's "Send shortcuts
    to <Mac>" toggle and press ⌘Space. Expected: Spotlight (or the host's
    configured ⌘Space action) opens on the host.
    Evidence: screenshot of Spotlight open on the host, taken from the
    controller's view.

12. **Gesture palette -> Mission Control.** From the controller's gesture
    palette, trigger Mission Control. Expected: Mission Control activates on
    the host.
    Evidence: screenshot of Mission Control's window-tiled view on the host.

13. **Clipboard both ways.** Copy text on the host, paste on the controller;
    then copy text on the controller, paste on the host. Expected: both
    directions work.
    Evidence: screenshot of each paste showing the expected text.

14. **Cursor changes to I-beam over text.** From the controller, hover the
    cursor over an editable text field on the host. Expected: the controller's
    rendered cursor shows as an I-beam, not the default arrow.
    Evidence: zoomed screenshot of the cursor over the text field.

15. **Pull the network for 20s -> "Reconnecting..." -> recovers, no code.**
    Disconnect the controller's (or host's) network for ~20 seconds, then
    restore it. Expected: the UI shows "Reconnecting..." during the outage and
    the session resumes afterward without any code prompt.
    Evidence: screenshots at disconnect, during "Reconnecting...", and after
    recovery.

16. **2-minute outage closes the session cleanly.** Repeat #15 but hold the
    outage for 2 minutes (past `iceFailureGrace`/backoff limits). Expected:
    the session closes cleanly on both ends — no crash, no stuck modifier keys
    on the host (test by typing Shift+A afterward locally on the host; it
    should type "A", not stay in a shifted/stuck state).
    Evidence: screenshot of the closed-session state on both Macs, and of the
    stuck-modifier check.

17. **Sign out on host -> controller refused.** Sign the host out of its
    account. Expected: a controller trying to connect afterward sees the
    sentence "That Mac isn't signed in to SkipperDesk yet." (entitlement refusal), not
    a generic error.
    Evidence: screenshot of that message.

18. **Footer reads "Kept in Secure Enclave".** *(Developer ID build only —
    an ad-hoc or locally-signed build falls back to a Keychain-held software
    key and will not show this; see `scripts/build.sh`'s signing section.)*
    On a Developer ID-signed host, the app's footer/identity area indicates
    the device key lives in the Secure Enclave.
    Evidence: screenshot of the footer text, plus the build's signing
    identity (`codesign -d -r- dist/SkipperDesk.app`).

19. **Relaunch/reboot keeps the same Device ID.** Quit and relaunch the app
    (and, separately, reboot the Mac). Expected: the Device ID shown is
    identical before and after.
    Evidence: two screenshots of the Device ID, before and after.

## Logs

Launch either side with `--debug` for diagnostics:

```sh
./scripts/launch-with-backend.sh <url> --debug
```

This sets `RC_DEBUG=1` and `RC_LOG_FILE` and prints the log path on launch
(default `$TMPDIR/skipperdesk-verify.log`; override with `RC_LOG_FILE=<path>`
before running the launcher). **A log file is only written by a
`scripts/build.sh --test-hooks` build**: `RC_LOG_FILE` is read through
`DevelopmentHooks`, which is compiled out of a release build (`RCLog.swift`),
so a release or notarised app launched with `--debug` leaves the file empty.

Attach the relevant excerpt as evidence for any item above where the UI alone
doesn't show what happened (lockout in #5, reconnect/backoff timing in #15-16,
entitlement refusal in #17).

The host backend's own logs (`rc-api`, `rc-signal`) live under
`${RC_DEV_DATA:-$TMPDIR/skipperdesk-dev-backend}` while `scripts/dev-tunnel.sh`
is running; `cloudflared`'s own log is in the same directory as
`cloudflared.log`.

## One-Mac verification run (2026-10-05)

Two real app instances on one Mac, against the real local backend
(`scripts/dev-backend.sh`, `SKIPPER_API_BASE_URL=http://127.0.0.1:18080`).
No tunnel, nothing against AWS.

* **HOST** — `scripts/build.sh --test-hooks`, signed with the Developer ID
  (`3UB3KZP9WH`, same designated requirement as the installed app), copied to a
  scratch bundle and launched with `RC_IDENTITY_DIR` / `RC_SETTINGS_SUITE` /
  `RC_PASTEBOARD_NAME` so it is genuinely a second identity. Device ID
  `736 789 140`, signed in through the real `/link` page (dev IdP), entitlement
  `trial`.
* **CONTROLLER** — the installed, notarised `/Applications/SkipperDesk.app`,
  no hooks, its own real identity (`567 397 415`).

The host is the hooks build because **both** bundles share a designated
requirement, so TCC treats them as the same app: whichever one hosts, it sees
the same grants. Screen Recording is granted (`screenRecordingGranted=true`,
real capture at 1920x1200 @2.0x); **Accessibility was not granted to
`app.skipperdesk.desktop` on this Mac at all** — `scripts/verify-input.sh`
refused for that reason, and the installed build showed the same "Accessibility
is off" banner. That is what blocked items 9-12 and 14 on that date. The grant
was added on 2026-10-06 and those five items were then driven through the GUI;
the rows below carry the result of that run, and **GUI input run (2026-10-06)**
below records what it took and what one machine still cannot show.

| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | Host sign-in | PASS | `/link` page: "Signed in as verify-onemac@example.com."; host log `account: accepted the skipperdesk://link callback` → `account: linked device 736789140` → `account: entitlement status=trial tier=base` |
| 2 | "Online" + plan line | PASS | Host hero reads **Online**; Account card reads **Trial · ends in 6 days**, "This Mac appears in your account as Verify Host" |
| 3 | Controller connects with Device ID + code | PASS | Controller window shows live video of the host; host log `capture started 1920x1200 @2.0x`, `local answer prefers H264` |
| 4 | Wrong code refused | PASS | Controller banner: "Wrong access code. Check it on the other Mac." (doc said "Wrong access code"; that is the real sentence) |
| 5 | Five wrong codes lock out | PASS (host side) | `guess-counters.json`: `failures:5`, `lockedUntilMs` set 60 s out; host log `ERROR access-code exchange failed: access-code attempts are locked out for another 30s`; a 6th attempt inside the window did **not** increment the counter. The controller is shown the same "Wrong access code" sentence on purpose — PROTOCOL.md §2.14 maps a lockout to `auth_failed`, so the checklist's "not just another wrong code message" is wrong about the controller, not about the host. |
| 6 | Reconnect with remembered code, no typing | PASS | After End Session the saved device is listed and the code is pre-filled; Connect re-opened the session with no code entry |
| 7 | Refresh code → controller asked again | PASS | New code minted, `trusted-controllers.json` deleted; the controller's remembered code then gets "Wrong access code. Check it on the other Mac." |
| 8 | Trusted list, per-row Remove | PASS (with a refresh bug) | Row `567 397 415 · Last connected 1 minute ago` present, Remove empties the card immediately. **Bug:** the row only appears after the Host screen re-appears — see below. |
| 9 | Drag a window by its title bar | **Not provable on one Mac** (not a permission problem) | The controller's press crosses correctly — a listen-only event tap recorded the host injecting `leftMouseDown` at exactly the mapped point on the target window's title bar. The rest of the gesture never arrives: the host's injected mouse-down takes the window server's implicit pointer grab away from the controller window, so the controller never sees the drag or the release and the host is left holding the button until the session's `input_reset`. One pointer cannot be in two places. OS-event level stays covered by `scripts/test-input.sh`: "the drag arrived intact: 1 down, 5 drag, 1 up". |
| 10 | Scroll a long page | **PASS** | Scrolling inside the controller's session window moved a 600-line document on the host from scroll offset 0 to 1028. Eight pixel-unit events of 160 px were injected, each with `isContinuous=1`; ten further events of 8 px moved it exactly 100 px (10 px each), i.e. pixel-accurate rather than single large jumps. Scrolling the other way returned it to 0. |
| 11 | ⌘Space via "Send shortcuts" | **PASS with the toggle off; the "on" half is only partly observable on one Mac** | Off: ⌘Space opened Spotlight on the controller's own Mac and a head-of-chain event tap recorded **nothing** injected on the host — the shortcut stayed local, which is the behaviour the toggle promises. On: the controller's capture tap swallowed the local ⌘Space (no local Spotlight) and the host injected ⌘Space, so the keystroke does reach the remote Mac. It cannot then open the host's Spotlight *on one machine*, because the controller's own capture tap is on the same Mac and re-captures the host's injected keystroke, which loops. The same host-side injection does open Spotlight when the loop is absent — see item 12's Spotlight check. The UI is a *toggle* ("Send shortcuts to <Mac>"), not a menu as this doc says. |
| 12 | Gesture palette → Mission Control | **PASS** (after the 2026-10-06 fix) | Originally FAIL: the palette opened, the click did not leak into the remote view, the host injected the documented OS events and macOS did nothing. Root cause and fix in "Fixed 2026-10-06" below — the combo was missing `secondaryFn`, which the Mission Control hotkey is registered with. `scripts/verify-input.sh` now asserts the host really enters Mission Control and App Exposé. |
| 13 | Clipboard both ways | PASS | Measured on the two real pasteboards: host `skipper.verify.host` → controller general = `HOST-TO-CONTROLLER-9f3a`; general → host = `CONTROLLER-TO-HOST-7b21`. `scripts/test-input.sh` adds the hash match and the no-echo-loop checks. |
| 14 | Cursor becomes an I-beam over text | **Not provable on one Mac** (not a permission problem) | macOS only applies a window's cursor rects while that window's application is active: measured on this Mac, TextEdit in front gives the I-beam (9x18, hot spot 4,9) and the identical hover with TextEdit in the background gives the arrow (17x23, hot spot 4,4). On one Mac the controller must be the active application to receive the driving input, so the host's pointer is always over a background window and the host never has an I-beam to report. The controller's own drawn cursor is also unphotographable in a steady state: the host warps the real pointer out of the controller's view, which hides the cursor layer. Still not covered by any script. |
| 15 | 20 s outage → "Reconnecting…" → recovers, no code | PARTIAL | A 22 s backend outage (`SIGSTOP` on `rc-api` and `rc-signal`) left the session **live** and asked for no code — correct, because the media path is peer-to-peer and was never cut. "Reconnecting…" needs the *media* path cut, which on one Mac means loopback ICE and therefore `pfctl`/sudo. Wire equivalent: `scripts/test-transport.sh` (f) — controller WebSocket killed mid-session, session RESUMED, "the access code was NOT requested again", "the peer connection was NEVER torn down". |
| 16 | 2-minute outage closes cleanly | N/A — same reason as 15 | `scripts/test-transport.sh` (h): clean `bye` on both ends, "the host is back to a closed session with no stuck state"; stuck modifiers covered by its `input_reset` checks in `test-input.sh` |
| 17 | Sign out on host → controller refused | **FAIL** | After Sign Out the host card returned to "Sign in to SkipperDesk", yet the controller's next connect was **not** refused — the session opened and reached the consent prompt ("Waiting for the other Mac to accept…"). See the bug list. |
| 18 | Footer reads "Kept in Secure Enclave" | PASS | `/Applications/SkipperDesk.app` (Developer ID, notarised) footer reads **Kept in Secure Enclave**. The hooks host reads "Kept in file (dev)" because `RC_IDENTITY_DIR` forces a dev file identity — expected, not a defect. |
| 19 | Relaunch keeps the Device ID | PASS (relaunch half) | `736 789 140` before and after quit+relaunch. The reboot half was not run — the user's Mac was not rebooted. `scripts/test-transport.sh` (n) separately proves the ID survives a wipe of the backend database. |

Also exercised, beyond the numbered list: host consent **allow** (session opened),
**decline** ("The other Mac declined the connection."), and **no answer**
(auto-declined after 30 s, same sentence on the controller).

Supporting suites, all green against this same backend:
`scripts/test-transport.sh` 84/84, `scripts/test-input.sh` 18/18,
`scripts/test-media.sh` 22/22 (27.1 fps, 383 kbps, VideoToolbox).

### Product bugs found

1. **Signing out does not stop remote sessions.** The sign-out sheet promises
   "This Mac stops accepting remote sessions until you sign in again", and
   item 17 expects the entitlement refusal. `AccountLinker.unlink()`
   (`apps/macos/Sources/RemoteControlCore/Account/AccountLinker.swift:246`)
   only revokes the device token, `authRevoke`
   (`server/internal/apisrv/auth.go:329`) only marks that token hash revoked,
   and `internalEntitlement`
   (`server/internal/apisrv/entitlement.go:71`) decides from the *device
   record*, which is still linked to the account and still on trial. The
   suite's entitlement test only covers a host that **never** signed in, so
   this path is untested.
2. **Trusted controllers list does not refresh live.** `HostView`'s
   `.onAppear { model.reloadTrustedControllers() }`
   (`apps/macos/Sources/RemoteControl/HostView.swift:33`) is the only reload,
   so a controller that proves the code while the Host screen is already on
   screen leaves the card reading "No Mac has proved this Mac's access code
   yet" until the view re-appears.
3. **The trusted-controller "short key" identifies nothing.**
   `TrustedControllerEntry.shortKey`
   (`apps/macos/Sources/RemoteControl/UIState.swift:24`) is the first 10
   characters of the base64 SPKI, which for P-256 is the fixed DER prefix
   `MFkwEwYHKoZIzj0` for *every* controller. The app already renders a real
   fingerprint (`AA20 3851 43BE 7ADC`) in the consent prompt.
4. **Misleading update log line.** `UpdateChecker`
   (`apps/macos/Sources/RemoteControlCore/Update/UpdateChecker.swift:123`)
   always logs "The running app has no Developer ID Team ID." when updates are
   off, including for a `--test-hooks` build that *is* Developer ID signed and
   is disabled because `DevelopmentHooks.areCompiledIn` is true.
5. **Cosmetic:** the Account card shows the raw `acct_…` id as the account
   name when the IdP returns no label.

### All five fixed (2026-10-05)

1. Sign out now unlinks this device: `DELETE /v1/devices/{deviceId}` accepts a
   device token for **its own** id (API.md §3.6), marks the device unlinked so
   `internalEntitlement` answers `unlinked`, revokes every token for it, and
   asks rc-signal to close the live session over `POST
   /internal/sessions/close`. The trial stays on the device record, so signing
   back in grants no second one. The app ends the local session first, through
   the same `AfterSessionEnds` path Refresh Code uses, and the Host screen
   hides the code as it returns to signed-out. Covered by
   `TestDeviceTokenSignOutUnlinksOnlyItself`, the `Account/sign out` suite and
   `scripts/test-transport.sh` step (o).
2. The trusted-controllers card now follows `SecretStore.changes`, so a
   controller that proves the code appears while the Host screen is on screen.
   No polling, and no `.onAppear` reload.
3. The row shows the same `Fingerprint AA20 3851 43BE 7ADC` sentence as the
   consent prompt, from the one `DevicePublicKey.fingerprintLine`.
4. Updates-off names the reason that applies (`UpdateDisabledReason`), so a
   `--test-hooks` build logs the hooks, not a missing Team ID.
5. The device-token grant carries `accountEmail`; the Account card and the
   menu-bar panel show that address, or "Signed in", never an account id.

Checked against a second local backend (`scripts/dev-backend.sh` on
`127.0.0.1:18090`, nothing against AWS): `./scripts/ci-local.sh` PREFLIGHT
PASSED, `scripts/test-transport.sh` **89/89** (the five new step (o)
assertions included), `scripts/test-input.sh` 18/18, `scripts/test-media.sh`
22/22 (27.2 fps, 391 kbps). Then on a `scripts/build.sh --test-hooks` bundle
run with `RC_IDENTITY_DIR`, as the host, with a headless `rc-node` controller:

* The Account card read **verify-ui@example.com**, never the `acct_…` id.
* The Trusted controllers card went from "No Mac has proved this Mac's access
  code yet" to `986 651 994 · Last connected 15 seconds ago ·
  Fingerprint 939B 1E0E 6E24 45A5` **while the Host screen stayed on screen**.
* The consent prompt for the same controller read `Fingerprint 939B 1E0E 6E24
  45A5` — the row and the prompt agree, letter for letter.
* The app log reads `update: Updates are disabled in development builds. This
  build has the test hooks compiled in.`
* Sign Out returned the screen to "Sign in to SkipperDesk" with the access code
  hidden, logged `account: unlinked device 715875943`, and the backend then
  answered `entitlement/unlinked` for that device.

Observed again on one Mac against the same local backend, with a signed
`--test-hooks` host (Device ID `328 540 994`, signed in as
`verify-gui@example.com`) and a headless `rc-node` controller
(`868 465 246`):

* Item 17 now **PASSES**. With the session live, Sign Out ended it first
  (controller: `bye{user_ended}`), then `account: unlinked device 328540994`;
  the Host screen returned to "Sign in to SkipperDesk" with the access code
  hidden, and the controller's next connect was refused
  `entitlement{unlinked}` — "That Mac isn't signed in to SkipperDesk yet."
* Item 8's refresh bug is gone: the Trusted controllers card went from "No Mac
  has proved this Mac's access code yet" to
  `868 465 246 · Last connected 9 seconds ago` without the Host screen ever
  re-appearing.
* That row reads `Fingerprint A5A7 A838 FEC2 5C12`, the same four groups the
  consent prompt had just shown for the same Mac.
* The Account card read `verify-gui@example.com`; no `acct_…` id anywhere.
* The hooks build logs "Updates are disabled in development builds. This build
  has the test hooks compiled in." — no Team ID is blamed.

`scripts/test-transport.sh` 89/89 (including the new sign-out step o),
`scripts/test-input.sh` 18/18, `scripts/test-media.sh` 22/22,
`scripts/ci-local.sh` green.

### Doc and script problems fixed or noted

* `scripts/test-input.sh` and `scripts/test-media.sh` could not run against
  `scripts/dev-backend.sh` at all: their host never signed in, so rc-api
  refused every session with `entitlement/unlinked`. Both now sign the host in
  with `rc-node --dev-sign-in` when the backend answers `/v1/health`, the way
  `scripts/test-transport.sh` already did. Fixed in this run.
* `--debug` promises a log file a **release** build never writes: `RC_LOG_FILE`
  is read through `DevelopmentHooks`, which is compiled out of release builds
  (`RCLog.swift:8`). The controller side of this run produced an empty log for
  that reason. The **Logs** section above applies only to a `--test-hooks`
  build.
* Item 11 says "Send shortcuts menu"; the control is a toggle button.
* Item 5's expectation that the controller sees something other than a wrong
  code message contradicts PROTOCOL.md §2.14.

### Fixed 2026-10-06 — Control-modified gestures did not take effect

**Symptom.** Mission Control (Control+Up) and App Exposé (Control+Down) from the
gesture palette reached the host and were injected as the documented OS events,
the window server accepted them, and macOS did nothing. Spotlight (⌘Space)
through the identical path worked.

**Root cause.** Not the modifier, and not the device-dependent left/right bit.
Arrow keys on an Apple keyboard raise `kCGEventFlagMaskSecondaryFn`, so the
system hotkeys for Mission Control and App Exposé are registered as
**Control+fn+Arrow** (NSEvent mask `0x840000`), not Control+Arrow. Our combos
declared `[.control]` only, so the key-down carried `0x40000` and never matched
the registered hotkey.

**Evidence.** A listen-only `CGEventTap` compared our posted events with what
`System Events` posts for the same shortcut:

```
System Events:  flagsChanged flags=0x40001        keyDown kc=126 flags=0xa40001
ours (before):  flagsChanged flags=0x40000        keyDown kc=126 flags=0x40000
```

`0xa40001` = control + left-control device bit + **secondaryFn (0x800000)** +
numericPad (0x200000). Replaying our sequence with only the device bit added did
nothing; adding `secondaryFn` to the arrow key-down opened Mission Control every
time, with or without the device bit and with or without the numericPad bit.

**Fix.** `GestureCatalog` declares Mission Control and App Exposé as
`[.control, .function]`, the shortcut macOS actually registers. No change to the
sink, the wire, or the shared core.

**Regression guard.** `scripts/verify-input.sh` now requires
`mission_control_takes_effect`, `mission_control_left_cleanly`,
`app_expose_takes_effect` and `app_expose_left_cleanly`. The self-test reads the
Dock's on-screen window count before and after the gesture (2 -> 4 for Mission
Control, 2 -> 3 for App Exposé, back to 2 after it is dismissed), so it asserts
what macOS *did*, not what we posted. Reverting the catalog change makes both
`*_takes_effect` checks fail. `scripts/test-input.sh` counts OS events and by
design cannot see this.

### Open bug, found 2026-10-06 — Force Quit needs a different posting tap

**Force Quit (⌘⌥Esc) does not take effect either, for an unrelated reason.**
`System Events` opens the dialog; our sequence does not, at any delay, with or
without the device-dependent bits, from any `CGEventSource` state
(`nil`, `.hidSystemState`, `.combinedSessionState`, `.privateState`). The one
thing that changes the outcome is the posting tap:

| tap | Force Quit | Mission Control |
|---|---|---|
| `.cghidEventTap` (what `CGEventSink` uses) | no | **yes** |
| `.cgSessionEventTap` | no | no |
| `.cgAnnotatedSessionEventTap` | **yes** | no |

So the two gestures want opposite taps, and `loginwindow`-owned shortcuts appear
to ignore HID-posted synthetic events. **Lock Screen (⌃⌘Q) is the other
`loginwindow` shortcut and is likely to be in the same position; it was not
tested by consequence because a pass would lock the machine.** Fixing this means
giving the sink a per-gesture posting tap, which is a bigger change than the
`secondaryFn` fix above and is deliberately not in it.

### GUI input run (2026-10-06)

Accessibility granted to `/Applications/SkipperDesk.app` (`app.skipperdesk.desktop`),
Screen Recording already granted. Same shape as the run above but the roles are
swapped, because the host is the side that injects input and captures the screen
and only the installed bundle holds the grants:

* **HOST** — `/Applications/SkipperDesk.app`, launched by
  `scripts/launch-with-backend.sh http://127.0.0.1:18080`. Device ID
  `567 397 415`, signed in through the real `/link` dev page as
  `verify-gui@example.com`. **Unattended access was already on** and was left
  on, so no run was gated on a consent prompt.
* **CONTROLLER** — `scripts/build.sh --test-hooks` signed with the Developer ID
  (`3UB3KZP9WH`), run from `dist/` with its own `RC_IDENTITY_DIR` /
  `RC_SETTINGS_SUITE` / `RC_PASTEBOARD_NAME`, so a second identity
  (`378 080 437`). Session window 720x572 at 5,25; the host streamed
  1920x1200 @2x.

The controller's session window was driven with real CGEvents, with the
frontmost application, its pid and the topmost window at the click point all
checked before every click and keystroke, and the target was a purpose-built
floating panel rather than any of the user's own windows. Pointer mapping was
calibrated against the host rather than assumed, and came out exactly linear:
controller view (547,208) landed on host screen (1084,154), the target's title
bar, to the pixel.

What one machine cannot show, in each case for a reason that has nothing to do
with permissions:

* **Pointer grab (item 9).** Posting a mouse-down over the controller's view
  makes the host inject a mouse-down somewhere else on the same screen. That
  second down takes the window server's implicit grab, so every later drag and
  the release go to the dragged window instead of the controller, and the host
  keeps the button held until `teardownPeerConnection` runs `input_reset`.
* **Active-application cursor (item 14).** macOS applies cursor rects only for
  the active application, and on one Mac that has to be the controller.
* **Keyboard capture (item 11, toggle on).** The controller's capture tap and
  the host's injector are on the same Mac, so the host's injected ⌘Space is
  immediately re-captured and forwarded again, unbounded.

### Still needs two machines

* Cross-network NAT traversal, and the TURN relay path (no coturn locally).
* Items 15 and 16 as written — a real network cut of the **media** path, which
  on one Mac would mean `pfctl`/sudo.
* Items 9 and 14, and the "on" half of item 11. Accessibility is granted now and
  items 10 and 12 were driven through the GUI, but these three turn on there
  being **two** pointers, two keyboards and two active applications. One Mac has
  one of each: the host's injected mouse-down takes the pointer grab away from
  the controller window (9), the host's pointer is always over a background
  window so macOS never shows an I-beam (14), and the controller's capture tap
  re-captures the host's injected keystrokes (11). See **GUI input run
  (2026-10-06)**.
* Item 19's reboot half.
* Item 17 across two machines. It now passes on one Mac, against the real
  backend, with the fix above.
