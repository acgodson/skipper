# SkipperDesk — Lock screen and login window access (design)

Status: **design only, nothing implemented.** Researched 2026-10-06 against macOS 14/15
documentation and Apple Developer Forums. Items marked *unverified* could not be confirmed from
Apple documentation and must be settled by a prototype before any of this is scheduled.

Goal: a host Mac that is locked, or sitting at the login window, can be seen and (later)
controlled, the way AnyDesk and TeamViewer do it. Today SkipperDesk sees nothing in that state.

Read with `docs/SCOPE.md` §5 (security model), `docs/SECURITY.md` ("Who lets a controller in")
and `docs/DESIGN.md`.

---

## 1. Why it does not work today

SkipperDesk is one app in the logged-in user's GUI session (`Aqua`). When the Mac locks or
logs out, macOS switches the display to a *different* GUI session owned by `loginwindow`
(session type `LoginWindow`, running as uid 0). The Aqua session keeps running but is no longer
the session on screen.

| Thing | In the user's Aqua session while locked | Why |
|---|---|---|
| `SCShareableContent` / `SCStream` | Enumerates and streams the **Aqua** session's displays only. It cannot see the `LoginWindow` session's framebuffer. Content is typically blanked or frozen | ScreenCaptureKit is scoped to the WindowServer session the process is attached to |
| `CGDisplayStream` (deprecated) | Same scoping; additionally reported as returning `nil` at the login window | Deprecated in macOS 14; not a way out |
| `CGEventPost(.cghidEventTap, …)` | Events are posted into the caller's session and do not reach `loginwindow` | Session-scoped; see §1.2 |
| `CGWindowListCreateImage` | Removed as a capture path on macOS 14+ (`ScreenCaptureKit` only) | — |
| TCC Screen Recording grant | Belongs to the **user**'s TCC database (`~/Library/Application Support/com.apple.TCC/TCC.db`). No logged-in user ⇒ no user TCC database to consult | TCC is per-user for these services |
| TCC Accessibility / `kTCCServicePostEvent` | System database (`/Library/…/TCC.db`), but the grant is still evaluated against a process in a session | — |

### 1.2 SecureEventInput — the real blocker for input

The login window and the lock screen's password field hold **SecureEventInput**. While it is
held, the WindowServer discards synthetic events from `CGEventPost` and `IOHIDPostEvent`
regardless of the poster's uid or TCC grants. This is not a permissions problem and no TCC grant
removes it. Apple's own `screensharingd` gets past it with the **private** entitlement
`com.apple.private.hid.client.event-dispatch`, which third parties cannot obtain.

So the two halves of the problem have very different difficulty:

| Half | Difficulty |
|---|---|
| **See** the lock screen / login window | Solved architecture, macOS 14.4+ |
| **Type** at the lock screen / login window | No supported third-party API. Needs a virtual HID driver (§2.4) or a `screensharingd` proxy (§2.5). Both are *unverified* for us |

---

## 2. Architecture

### 2.1 Shape

```
   loginwindow GUI session (uid 0)        user Aqua session (uid 501)
   ┌──────────────────────────────┐       ┌──────────────────────────────┐
   │ skipper-session-agent        │       │ skipper-session-agent        │
   │  ScreenCaptureKit · input    │       │  (same binary, Aqua instance)│
   └──────────────┬───────────────┘       └──────────────┬───────────────┘
                  │  XPC (mach service, mutual CS check) │
                  └──────────────┬───────────────────────┘
                  ┌──────────────▼───────────────┐   ┌────────────────────┐
                  │ skipper-daemon (root, no GUI)│   │ SkipperDesk.app    │
                  │ identity · SPAKE2 · WebRTC · │◄──┤ UI only            │
                  │ signaling · policy           │   └────────────────────┘
                  └──────────────────────────────┘
```

Apple DTS states this split explicitly: the daemon does network and state, the **agent** does
every GUI task, because a daemon in session 0 has no graphical context and ScreenCaptureKit
cannot initialise there ([forum 814152](https://developer.apple.com/forums/thread/814152)).

### 2.2 launchd configuration

| Component | Installed at | Key settings |
|---|---|---|
| `skipper-daemon` | `/Library/LaunchDaemons/app.skipperdesk.daemon.plist` | `RunAtLoad`, `KeepAlive`, `MachServices` |
| `skipper-session-agent` | `/Library/LaunchAgents/app.skipperdesk.agent.plist` | `LimitLoadToSessionType = ["Aqua", "LoginWindow"]` — one instance per GUI session |

**`SMAppService` cannot be used for the agent.** `SMAppService.agent(plistName:)` with
`LimitLoadToSessionType = LoginWindow` reports *Enabled* but never runs, and Apple DTS confirms
the API "wasn't designed to do this"
([forum 726864](https://developer.apple.com/forums/thread/726864)). The agent must be a classic
`/Library/LaunchAgents` plist installed by a privileged installer. `SMAppService.daemon` *is*
usable for `skipper-daemon` (`LimitLoadToSessionType` is ignored for daemons anyway) and keeps
install/uninstall inside the app bundle — preferred for that half.

### 2.3 Capture at the login window

| Question | Answer |
|---|---|
| API | ScreenCaptureKit, from the **LoginWindow-session agent** (uid 0) |
| Minimum OS | **macOS 14.4.** Earlier builds carry the bug (r. 121253782) that broke SCK in the pre-login context |
| `CGDisplayStream` | No. Deprecated and reported `nil` at the login window |
| Screen Recording consent for that agent | *Unverified.* There is no logged-in user to prompt, and Apple does not let MDM **grant** Screen Recording (only deny, or let a standard user approve). Working theory: the grant is made once by the admin in the normal Aqua session against the agent's code signature, and the system TCC record then covers the LoginWindow instance. **Prototype P1 settles this** |
| `com.apple.developer.persistent-content-capture` | The VNC entitlement that stops macOS 15's weekly/post-reboot screen-recording re-prompts. It is a **managed capability**: applied for and granted by Apple, undocumented request path. Without it, unattended capture is re-prompted periodically, which defeats the feature. Treat obtaining it as a scheduling risk |

### 2.4 Input at the login window — preferred path: virtual HID

A DriverKit `HIDDriverKit` virtual keyboard/mouse produces events at the HID layer, where a real
keyboard produces them, so SecureEventInput does not apply. This is what we believe AnyDesk and
TeamViewer rely on.

| Item | Detail |
|---|---|
| Entitlements | `com.apple.developer.driverkit`, `.driverkit.family.hid.device`, `.driverkit.family.hid.eventservice`, `.driverkit.transport.hid`, and `.driverkit.userclient-access` |
| Availability | All of these are **managed capabilities requiring individual Apple approval**. We do not have them |
| Client privilege | The reference implementation (`pqrs-org/Karabiner-DriverKit-VirtualHIDDevice`) only accepts commands from root — which matches `skipper-daemon` |
| Conflict with §scope | A DriverKit extension is a **system extension**. `check-isolation.sh` currently *fails* on any system-extension entitlement (§3.6) |
| Status | *Unverified* that a virtual HID device actually drives the login window password field. **Prototype P2** |

### 2.5 Input fallback — proxy to `screensharingd`

Connect from the LoginWindow agent to the local `screensharingd` as an RFB client and let it
inject, since it holds the private HID entitlement. Observed working in the wild
(`stanelie/meshcentral-mac-agent`).

Rejected as a shipping design: it requires the owner to enable macOS Screen Sharing, depends on
TCC grants held by `com.apple.screensharing.agent`, speaks legacy type-2 DES RFB auth, and
would make SkipperDesk store an ARD password — a second credential outside our SPAKE2 model.
Record it as a known alternative, do not build it.

### 2.6 Where identity, code and the session live

**One Device ID, one access code, the same SPAKE2 and consent rules at the lock screen.** The
only way to guarantee that is to move the security-critical half down into the daemon.

| Asset | Owner | Note |
|---|---|---|
| Device identity (P-256) | `skipper-daemon` | Moves out of the user Keychain into a **System Keychain** item, or a Secure Enclave key created by the daemon. The Device ID must not change — see §7 Q3 |
| Access code, SPAKE2 exchange, key schedule | `skipper-daemon`, via the existing Rust core (`rc-identity`, `rc-session`) | Unchanged logic; new host process. No second implementation |
| Trusted controllers, guess counters, lockouts | `skipper-daemon`, in `/Library/Application Support/SkipperDesk` (root-owned, 0700) | Currently per-user files; they move, they do not get duplicated |
| Signaling WebSocket, WebRTC peer connection | `skipper-daemon` for the whole session lifetime | The daemon owns the session always, not only while locked. This avoids a hand-over of crypto state at lock time (§4.3) |
| Capture, input, clipboard | `skipper-session-agent` (whichever session is on screen) | Frames flow agent → daemon over XPC; input flows daemon → agent |
| UI, sign-in, settings | `SkipperDesk.app` | Pure client of the daemon |

Consequence: the app becomes a front end. That is a larger refactor than the lock-screen feature
itself and is the main reason this is not a small change.

### 2.7 Local authentication between the halves

`NSXPCConnection` both ways, each side verifying the other's code signature. Exact requirement
strings, matching `app.skipperdesk.desktop` and the Team ID already used by `scripts/build.sh`:

| Checker | Checks | Requirement string |
|---|---|---|
| Daemon → connecting agent or app | `SecCodeCheckValidity` on `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit: auditToken)` | `anchor apple generic and certificate leaf[subject.OU] = "<TEAM_ID>" and (identifier = "app.skipperdesk.desktop" or identifier = "app.skipperdesk.agent") and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists` |
| Agent/app → daemon | `xpc_connection_set_peer_code_signing_requirement` (macOS 13+) on the client connection | `anchor apple generic and certificate leaf[subject.OU] = "<TEAM_ID>" and identifier = "app.skipperdesk.daemon" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists` |

Notes: the last two certificate clauses are the Developer ID CA and Developer ID Application
leaf OIDs — they stop a self-signed build from impersonating either half. Audit tokens are the
only safe peer identifier (`processIdentifier` is PID-reuse racy). Both requirements must also
be pinned by a **designated requirement** in the built binaries, and asserted by `ci-local.sh`.

---

## 3. Security analysis

A root component that can see and type at the login window is the most dangerous thing
SkipperDesk would ship. It must be designed as if it will be attacked.

### 3.1 What an attacker who controls the daemon gains

| Gain | Severity |
|---|---|
| Watch the owner type their login password at the lock screen | Critical — full account compromise, FileVault unlock, Keychain |
| Type as root at the login window (if §2.4 ships) | Critical — unattended persistence |
| Full disk read as root | Critical |
| Persistence across logout, reboot and user switching | Critical — worse than today's app, which dies with the session |
| Survives the owner deleting the app, unless uninstall runs | High |

Today the worst case is "another process running as the same user" (`docs/SECURITY.md`). This
raises the ceiling to "root, before anyone logs in". Nothing in the current threat model covers
it; `SECURITY.md` must gain its own section before a line of this is written.

### 3.2 Rules the daemon must enforce

1. **No proven session, no capture and no input.** The daemon starts no `SCStream` and accepts
   no input until a SPAKE2 exchange has completed *in this process*, against the current access
   code, and the backend has returned a valid entitlement. Idle state is zero capture.
2. **Unattended access must be explicitly on.** Consent cannot be asked when nobody is logged
   in: there is no user session to draw a prompt in, and a prompt on the login window would be
   indistinguishable from a phishing overlay. **Policy: at the lock screen and login window, a
   session is refused outright unless the owner enabled Unattended access beforehand, in the
   logged-in session, with an admin authorisation.** Never a silent default, never an implicit
   grant, never "allow just this once" from the lock screen. This extends the existing rule in
   `SECURITY.md` rather than replacing it.
3. **Existing limits apply unchanged**: one controller per host, code-guess lockouts, the
   host-wide guess budget, the trusted-controllers list being informational only.
4. **Separate opt-in for input.** Seeing the lock screen and typing at it are two settings. The
   first milestone (§6) ships only the first.
5. **Keystrokes at the password field are not special-cased.** The daemon has no notion of which
   field is focused, does not inspect, filter, buffer, transform or log keystrokes, and logs no
   key codes at any log level in a release build. There is no "password mode". This must be
   stated publicly on the security page in those words, and asserted by a test that greps the
   release binary and the log output for key-code emission.
6. **Audit, not content.** The daemon appends an immutable local record of every lock-screen
   session (time, controller device ID, duration) to a root-owned log the user can read. No
   frames, no keys, no clipboard.

### 3.3 Revocation

| Action | Effect on the daemon |
|---|---|
| **Refresh Code** | Daemon mints the new code, clears trusted controllers and per-controller counters, and tears down any session — including a lock-screen one — in the same operation. Because the daemon *is* the code's owner, there is no window where the app and daemon disagree |
| **Sign out** | Daemon drops the account link, stops the signaling connection, disables unattended access, and refuses every connect. (Note: `docs/VERIFY.md` item 17 records that sign-out does **not** currently refuse a controller. That bug must be fixed before the daemon exists, or it becomes a root-level bug) |
| **Turn Unattended access off** | Takes effect immediately in the daemon; a lock-screen session in progress is ended |
| **Uninstall** | `SMAppService.daemon.unregister()` plus removal of the LaunchAgent plist, the binaries, and `/Library/Application Support/SkipperDesk`. Must also be reachable from a standalone uninstaller for a user who deleted the app first |

### 3.4 Update and rollback

| Requirement | Detail |
|---|---|
| Signature | Daemon and agent are signed with the same Developer ID + hardened runtime as the app, and verified by `codesign --verify --deep --strict` in `package-dmg.sh` |
| Update path | The daemon updates itself from the existing signed-update channel (`docs/SECURITY.md` "Updates"); it must verify the signature *before* replacing itself, and must not accept an update pointed at by anything the controller sends |
| Downgrade | Version must be monotonic — a signed older build must be refused, or a revoked-key build can be re-installed |
| Rollback | A failed daemon start must leave the previous binary in place and fall back to app-only operation, not to a Mac with no daemon and no app |
| Version skew | App, agent and daemon carry a protocol version; mismatched halves refuse to talk and the UI says to re-run the installer |

### 3.5 Honest statement of residual risk

Even done correctly, this feature means: a component with root, able to record the screen while
the password is typed, exists on the user's Mac whenever the feature is enabled. The mitigations
are design (no capture without a proven session), transparency (open source, published audit
log, explicit no-special-casing statement) and scope (off by default, admin authorisation). They
do not make the risk zero and the security page must say so.

### 3.6 Release gates

| Gate | Extension needed |
|---|---|
| `scripts/check-isolation.sh` | Must take the daemon and agent binaries as targets too, run the same forbidden-API grep and entitlement checks on them, and assert the hardened runtime. **Its current blanket failure on system-extension entitlements must become a narrow allow-list of exactly the DriverKit HID entitlements, with a comment naming each** — a blanket exception would gut the gate |
| New gate `scripts/check-privileged.sh` | Assert: designated requirements of all three binaries; both XPC requirement strings present in the binaries; no `get-task-allow`, no `disable-library-validation`; daemon refuses an unsigned peer; daemon does not emit key codes |
| `scripts/ci-local.sh` | Runs both, and fails the build if the daemon's entitlements change without a matching doc update |
| `scripts/verify-lockscreen.sh` | New, following the `verify-*.sh` pattern: real two-Mac, lock, observe, unlock |
| Phase exit | Unchanged rule: observed working between two real Macs, including a real reboot-to-login-window |

---

## 4. User experience

### 4.1 Turning it on

| Step | What the owner sees |
|---|---|
| 1 | Host screen, below Unattended access: **"Show this Mac's lock screen"**, off |
| 2 | Turning it on explains, in one short paragraph, that a background component with system access is installed, that it can see the screen while the password is typed, and that SkipperDesk does not treat the password field specially |
| 3 | macOS authorisation prompt (admin password / Touch ID) to install the privileged component |
| 4 | macOS Login Items & Extensions prompt to allow the background item |
| 5 | Screen Recording grant for the agent, in System Settings, with a button that opens the right pane |
| 6 | The toggle reads **On** only once the daemon has reported it can actually capture — never on hope |
| 7 | Input at the lock screen is a **second, separate** toggle, available only after §6 Phase L2 |

Per `UI: no infrastructure narration` — no mention of XPC, launchd, sessions or TCC database
names. "A background component" and "system access" is the register.

### 4.2 What the host shows

At the lock screen the host draws nothing of its own (it cannot reliably put a window over the
login window, and anything it could would look like a phishing overlay). Instead:

- The **menu bar / Host screen on unlock** shows that a lock-screen session took place, when,
  and from which controller.
- The local audit log (§3.2.6) is readable from the Host screen.
- *Unverified:* whether a small session indicator can be shown at the login window at all. Do
  not promise one.

### 4.3 Locking mid-session

Because the daemon owns the session end to end (§2.6), locking is a **source change, not a
reconnect**:

| Moment | Controller sees |
|---|---|
| Host locks | A brief "The other Mac locked" line over the last frame; the WebRTC session, SPAKE2-derived keys and clipboard channel are untouched |
| Capture resumes from the LoginWindow agent | The lock screen, live |
| If Unattended access or the lock-screen setting is off | Session **ends** with "This Mac is locked and lock-screen access is off", not a frozen frame |
| Someone unlocks the host | Source switches back to the Aqua agent; no code is requested again |

### 4.4 What we cannot do

A Mac in true system sleep is not running the OS and cannot be woken by SkipperDesk. Neither a
daemon nor a driver changes that. The honest sentence for the UI and the website: *"If the Mac
is asleep, nothing on it is running and we cannot wake it — use Wake on LAN on the local
network, or keep the Mac awake."* Never imply otherwise. (`StayAwake` already covers the
keep-awake half.)

---

## 5. Packaging

| Question | Answer |
|---|---|
| Where do the binaries live | Inside the notarized bundle: `Contents/Library/LaunchDaemons/app.skipperdesk.daemon.plist`, `Contents/MacOS/skipper-daemon`, `Contents/MacOS/skipper-session-agent`, plus a copy of the agent plist |
| Install | `SMAppService.daemon(plistName:).register()` installs the daemon (shows the Login Items prompt). The **LoginWindow agent cannot** be installed that way (§2.2): the daemon, once running as root, copies the agent plist to `/Library/LaunchAgents` and `bootstraps` it |
| Uninstall | Reverse of the above, plus the data directory, reachable from the app and from a standalone uninstaller |
| Notarization | Unchanged — the whole bundle is signed and notarized as one; `package-dmg.sh` gains daemon/agent signature and hardened-runtime assertions |
| Is our Developer ID + provisioning profile enough? | **For capture-only (Phase L1): expected yes** — Developer ID Application, hardened runtime, the existing `keychain-access-groups` profile. *Unverified* whether a System Keychain item for the daemon needs anything further |
| New entitlements needed | `com.apple.developer.persistent-content-capture` (managed, Apple approval) to avoid the macOS 15 re-prompt; the five DriverKit entitlements (managed, Apple approval) for Phase L2. **Both applications should be filed before either phase is scheduled, because neither is in our control** |
| First-run authorisation | Admin authorisation (install) → Login Items approval → Screen Recording grant. Three prompts; the UI must walk them one at a time and say what each is for |

---

## 6. Phasing

Same form as `docs/SCOPE.md` §11. These slot in after Phase 4, and do not block Phase 5.

| # | Milestone | Deliverable / falsifiable exit check |
|---|---|---|
| L0 | **Prototypes** (§7) | P1, P2, P3 each answered yes/no in writing, with the command and output recorded in `docs/VERIFY.md`. If P1 is "no", the whole feature stops here |
| L1 | **See the lock screen, read-only** | Daemon + dual-session agent; identity, SPAKE2, counters and WebRTC moved into the daemon; capture only, input hard-disabled in the daemon. **Check:** Mac A connects to Mac B; B is locked with ⌃⌘Q; A keeps the same session and sees B's live lock screen (a clock ticking proves it is live, not a still); B is rebooted to the login window and A reconnects with the same Device ID and access code and sees it. With the setting off, the same attempt is refused with the documented sentence. `check-isolation.sh` and `check-privileged.sh` pass on all three binaries |
| L2 | **Control the lock screen** | Virtual HID path, second opt-in, input enabled. **Check:** from Mac A, type Mac B's login password at B's login window and reach the desktop; the session continues across the unlock without re-asking for the code; with the input toggle off, keystrokes are dropped by the **daemon** (proved by the daemon's own counter, not by their having no visible effect) |
| L3 | **Hardening and disclosure** | `verify-lockscreen.sh`; `SECURITY.md` section; public security-page text including the no-special-casing statement; uninstaller; update/rollback proven by installing an older signed build and seeing it refused. **Check:** a third-party reviewer can reproduce every claim from the repo |

L1 is useful on its own: "my Mac is locked, I can see it is at the lock screen and nothing is
wrong" is most of why the user asked, and it needs no Apple-granted entitlement beyond the
capture one.

---

## 7. Open questions, risks and what to prototype first

| # | Prototype | Question it settles |
|---|---|---|
| **P1** | Minimal signed daemon + `LimitLoadToSessionType = [Aqua, LoginWindow]` agent on a real macOS 14.4+ and 15 Mac; agent writes one PNG per second from `SCStream` | Does ScreenCaptureKit really produce frames at the login window for us, and **how is the Screen Recording grant obtained for the LoginWindow instance without MDM**? This is the gating unknown; run it first and run it on both Apple silicon and Intel |
| **P2** | `pqrs-org/Karabiner-DriverKit-VirtualHIDDevice` installed by hand; attempt to type into the login window password field from a root client | Does a virtual HID device actually bypass SecureEventInput at the login window? If no, Phase L2 has no supported path and should be dropped rather than bodged |
| **P3** | Two-process XPC with both code-signing requirements enforced, run from the LoginWindow session | Do the §2.7 requirement strings work from a uid-0 session, and does `xpc_connection_set_peer_code_signing_requirement` behave there? |

| Risk | Why it matters |
|---|---|
| `com.apple.developer.persistent-content-capture` is a managed capability with no documented request path | Without it, macOS 15 re-prompts for Screen Recording weekly and after every reboot, which makes unattended capture unusable. **Out of our control** |
| DriverKit HID entitlements are individually granted by Apple | L2 may be un-shippable. Do not promise lock-screen *control* publicly until the entitlement is in hand |
| Moving identity into the daemon risks changing the Device ID | The Device ID is user-visible and is the trial key (`SCOPE.md` §6). A migration that mints a new one is a product bug, not a detail. Design the migration before the move |
| The app becomes a front end to a daemon | Larger refactor than the feature. The `SECURITY.md` "what another process as the same user can do" analysis must be redone |
| `SECURITY.md` promises no third-party dependency of this weight | A DriverKit extension is a new, large dependency and a system extension; name it in the PR and in the dependency list, per `CLAUDE.md` |
| `docs/VERIFY.md` item 17 (sign-out does not refuse a controller) | Today a UI bug. With a root daemon it becomes a root-level authorisation bug. Fix before L1 |

### Unverified, not guessed

Everything above marked *unverified* is unverified: login-window TCC grant mechanics without
MDM, virtual HID versus SecureEventInput, any session indicator at the login window, System
Keychain/Secure Enclave access from a daemon, and whether the existing provisioning profile
covers the daemon's keychain access. None of it is assumed in the phase exit checks — each is a
prototype in L0.

Sources: Apple Developer Forums
[814152](https://developer.apple.com/forums/thread/814152),
[726864](https://developer.apple.com/forums/thread/726864),
[724740](https://developer.apple.com/forums/thread/724740);
`stanelie/meshcentral-mac-agent`; `pqrs-org/Karabiner-DriverKit-VirtualHIDDevice`.
