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
   the controller shows the sentence "Wrong access code" and does not connect.
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

11. **⌘Space via "Send shortcuts".** From the controller's "Send shortcuts"
    menu, send ⌘Space. Expected: Spotlight (or the host's configured ⌘Space
    action) opens on the host.
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
before running the launcher). Attach the relevant excerpt as evidence for any
item above where the UI alone doesn't show what happened (lockout in #5,
reconnect/backoff timing in #15-16, entitlement refusal in #17).

The host backend's own logs (`rc-api`, `rc-signal`) live under
`${RC_DEV_DATA:-$TMPDIR/skipperdesk-dev-backend}` while `scripts/dev-tunnel.sh`
is running; `cloudflared`'s own log is in the same directory as
`cloudflared.log`.
