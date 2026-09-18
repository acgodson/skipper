# SkipperDesk — Security (public draft)

This is the factual security page for skipperdesk.app. No marketing language; every
claim below traces to `docs/SCOPE.md` §5, `docs/DECISIONS.md` ("Protocol v2", "second
review / protocol v4"), and `protocol/PROTOCOL.md`/`protocol/API.md` (the normative wire
contract, currently v4). See `SECURITY.md` at the repo root for how to report a vulnerability.

## Threat model, in plain words

SkipperDesk connects two devices you own — a host and a controller — so you can
drive one from the other. Our servers exist only to introduce the two devices and
to relay bytes neither of them can reach directly.

**What the operator (us) can see:**
- That a device with a given Device ID exists and is online.
- When a session started, when it ended, and how many bytes moved — kept for
  billing, nothing else.
- The relay server sees encrypted media/data when a session cannot connect
  peer-to-peer and falls back to a TURN relay; it cannot decrypt it.

**What the operator cannot see:**
- The access code, or the session key derived from it. Neither ever reaches the
  server in any form — the code is proved between the two devices directly with a
  PAKE exchange (below). The server does learn *whether* an attempt failed (the
  host tells it `bye{reason:"auth_failed"}` in cleartext, so a wrong guess can be
  told from a clean hang-up) — but never the code itself, correct or not, and never
  the key the guess would have produced.
- The screen, keyboard, mouse, or clipboard content of a session — end-to-end
  encrypted, and never logged or persisted server-side.
- Which SDP/ICE messages are authentic. Both sides sign their SDP with their
  device key, so even a fully compromised server cannot substitute its own key
  and man-in-the-middle the media.

**What a compromised or subpoenaed server can still do:** deny service (refuse to
relay), see connection metadata (who/when/bytes, and whether a code attempt
failed), and see TURN-relayed ciphertext it cannot open. It cannot see plaintext
of anything, and cannot silently insert itself into a session because of the
signed-SDP step above.

## Who lets a controller in

The access code proves a controller *may* connect. Every connection — including one from a
controller the host has seen before — runs the full code exchange; "trusted controllers" is
only an informational list the host keeps of who has proved a code, and controllers separately
remember a code locally so their own user isn't re-prompted for it. With **Unattended access**
off — the default on a new install — the host also asks the person at it, and only after the
code has been proved, so a stranger who does not know the code can never make a prompt appear.
No answer within 30 seconds is a decline. A controller declined twice in ten minutes is turned
away without asking again, and so is any controller once the host itself has been asked three
times in ten minutes; both counts are persisted, not reset by a relaunch. Refresh Code clears the
trusted list and every per-controller guess counter and ends any session in progress, but the
host-wide guess budget is untouched by it — it exists to bound the server's own connect rate, not
a particular controller's trust. With Unattended access on, the code alone is permission; that is
the setting for a Mac nobody is sitting at. Either way a session in progress is always shown on
the host and can be ended there.

The system notification that accompanies the prompt uses generic text, not the connecting
controller's label or Device ID. The prompt window itself does not steal focus or force its way
to the front of other windows, and its Allow button is disabled for the first 1.5 seconds so a
reflexive click can't grant access before the person has read it.

## Cryptography

| Purpose | Algorithm |
|---|---|
| Device identity | ECDSA P-256. Secure Enclave for a brand-new identity on a Mac that has one; otherwise a Keychain-held software key. A pre-existing software-key identity whose Keychain migration fails on a signed build keeps using its legacy file key for that one launch only (the app's footer says so); an unsigned build refuses such an identity instead. A file-backed key otherwise exists only in test-hook builds, never in a release |
| Access code exchange | SPAKE2 (RustCrypto `spake2` 0.4) — the server relays opaque messages and never learns the code or the session key it produces, though it does learn whether an attempt failed (see "Who lets a controller in") |
| Key derivation | HKDF-SHA256 |
| Message authentication | HMAC-SHA256 |
| Session media transport | WebRTC DTLS-SRTP, AES-GCM |
| Signaling/API transport | TLS 1.2+ from a public CA |

No hand-written primitives. All of the above come from audited libraries
(RustCrypto crates, Apple's CryptoKit and Secure Enclave APIs, Google's libwebrtc).
The Mac app's former hand-written BLAKE2b/Argon2id target (`RCCrypto`, used only by
the protocol v1 server-side code check) has been deleted; nothing in the client
implements a primitive itself.

## What is logged

Session metadata only: device IDs involved, session start/end time, and bytes
transferred, kept for billing and abuse detection. No screen content, no
keystrokes, no clipboard content, no access code, no session key — in any form,
ever.

## Isolation

SkipperDesk never touches the controlled machine's system or browser networking:
no proxy, no VPN, no DNS interception, no browser extension, no `WKWebView`/
`JavaScriptCore` in the remote-control path. This is enforced by
`scripts/check-isolation.sh`, which greps the source for forbidden APIs, inspects
the *built* binary for linked WebKit/JavaScriptCore/proxy/VPN symbols, reads the
signed entitlements (`codesign -d --entitlements -`) and fails on
`disable-library-validation`, `get-task-allow`, `allow-jit`,
`allow-unsigned-executable-memory`, DYLD-environment, networking-extension or
system-extension entitlements, requires the hardened runtime on any Team ID build,
and fails if a development hook is still present in the binary. It is a release
gate, not just a style check.

## Development hooks

A handful of environment variables exist only so scripts can drive the app:
`RC_IDENTITY_DIR`, `SKIPPER_DEV_FILE_IDENTITY`, `RC_DUMP_FRAME`, `RC_INPUT_SELFTEST`,
`RC_CAPTURE_SOURCE`, `RC_SYNTHETIC_SIZE`, `RC_PASTEBOARD_NAME`, `RC_SETTINGS_SUITE`,
`RC_AUTOLINK`, `RC_AUTOCONNECT` and `RC_LOG_FILE`. The connection tuning knobs are
development-only too: `RC_DEVICE_LABEL`, `RC_HANDSHAKE_TIMEOUT`, `RC_REQUEST_TIMEOUT`,
`RC_HEARTBEAT_SEC`, `RC_RENEW_SEC`, `RC_BACKOFF_MIN`, `RC_BACKOFF_MAX`,
`RC_ICE_RESTART_DELAY`, `RC_ICE_FAILURE_GRACE` and `RC_ICE_POLICY`. A release build uses
the constants in `RCConfig` and the Mac's own name. Every read of them goes through
`DevelopmentHooks`, whose environment reader (`DevelopmentHooks.environmentValue` and
`DevelopmentHooks.variableName`) is compiled only under `#if DEBUG || SKIPPER_TEST_HOOKS`.
A release build of SkipperDesk.app does not contain the code that reads them, so no
runtime flag, bundle check or environment value can switch them back on.

`check-isolation.sh` proves this on the artefact. Swift stores strings of 15 bytes or
fewer inside the code, where `strings` cannot find them, so the gate does not rely on
variable names. It fails when the binary's symbol table contains either reader symbol,
or when the symbol table is missing (a stripped binary cannot be checked). It reads the
stored byte of `DevelopmentHooks.areCompiledIn` from the binary and fails unless it is
0. It also still fails on any longer hook name that `strings` finds as a string of its
own, and on the `SkipperTestHooks` Info.plist marker.

The gate also checks the source. It fails if any Swift file that ships in the app
(`RemoteControl`, `RemoteControlCore`, `SkipperCore`, `SkipperDesign`) other than
`Config/Config.swift` and `Config/DevelopmentHooks.swift` reads
`ProcessInfo.processInfo.environment` or calls `getenv`, `setenv`, `unsetenv` or
`putenv`. `Config.swift` may read exactly `SKIPPER_API_BASE_URL` and
`SKIPPER_WEB_BASE_URL`, and `DevelopmentHooks.swift` may read only `RC_DEBUG` outside its
`#if DEBUG || SKIPPER_TEST_HOOKS` block. The script checks exactly the path it is given
(`check-isolation.sh path/to/SkipperDesk.app`) and fails if nothing is there. With no
path, it checks `dist/SkipperDesk.app`.

`rc-node` and `rc-tests` are built in debug by every script, so they keep the hooks. The
on-device `scripts/verify-*.sh` checks need `./scripts/build.sh --test-hooks`, which
defines `SKIPPER_TEST_HOOKS` and marks the bundle `SkipperTestHooks`. `check-isolation.sh`
refuses that bundle, and such a build never updates itself (see Updates).

Release builds read exactly three environment variables: `SKIPPER_API_BASE_URL`,
`SKIPPER_WEB_BASE_URL` and `RC_DEBUG`. `RC_DEBUG` is the only switch among them, and it
only raises log and diagnostic verbosity.

`RC_DEBUG=1` is not a hook and stays available in release, because the product rule is
"diagnostics hidden unless `RC_DEBUG`". In release it does two things only: it shows the
extra diagnostic readouts in the UI (capture size, frame rate, display scale, round-trip
time), and it turns on the app's log lines on standard error. Those lines carry state and error reasons, never
access codes, keys, tokens or SDP bodies. The log file (`RC_LOG_FILE`) is a hook and does
not exist in release.

`SKIPPER_API_BASE_URL` and `SKIPPER_WEB_BASE_URL` also stay available in release
(self-hosting and the two-Mac test need them). Both are validated by one rule (https
only, plain http only for localhost/127.0.0.1), and the app shows a permanent "Using a
development server" banner whenever either points away from the shipped backend.

## Signing

A Developer ID build runs under the hardened runtime with library validation on
and no `disable-library-validation`. `WebRTC.framework` is signed with the same
identity, but on its own — never with `codesign --deep` — so it never inherits
the app's entitlements; the embedded framework and the app binary are each signed
individually, inside-out, before the whole bundle is verified. A build signed
without an Apple-issued certificate has no Team ID, so library validation could
never admit its own framework: such local builds are signed without the hardened
runtime and are for development only.

## Where this Mac's secrets are kept

The device key, the access code, the remembered codes, the device-ID certificate,
the pinned host keys, the trusted-controller list and the guess counters all live
in a keychain. **Which** keychain is not a claim the build makes about itself; the
app finds out at startup by writing, reading back and deleting a throwaway item in
the data-protection keychain under its own access group. What that probe answers
decides everything below, and the host screen's key-storage footer says which one
is in use.

| | Data-protection keychain | Login keychain |
|---|---|---|
| When | The bundle carries an `embedded.provisionprofile` and, with it, `com.apple.application-identifier` and `keychain-access-groups` — the signed, notarized download | Any build without that profile, including every build from source |
| Who can read an item | Only code the kernel accepts as this app: the signature and the access group are checked on every call | **Any process running as the same user.** No app-identity check applies |
| Access group | `<TEAMID>.app.skipperdesk.desktop` | none — items are keyed by service and account only |

The login keychain is the Phase 2.2 threat model, unchanged from V1: SkipperDesk
protects these secrets from other *users* and from anything off this Mac, not from
malware already running as you. The data-protection keychain is strictly stronger,
and it is what the released build uses.

Both entitlements travel with the profile or not at all: macOS refuses to launch a
bundle that carries `keychain-access-groups` without a matching
`embedded.provisionprofile` (`Launchd job spawn failed`, POSIX 153), so a build
with no profile is signed without either and falls back rather than failing. The
build records its choice in the bundle's `SKIPPERSecretStorageMode`
(`dataProtection` or `login`), and `scripts/check-isolation.sh` fails a release
whose profile, entitlements and recorded mode do not agree.

The Secure Enclave path works in both modes: the private half of an Enclave key
never leaves the chip either way, and only its wrapped blob goes to whichever
keychain is in use.

On startup the app also reads the keychain it is *not* using. Anything found only
there is written across, read back and then deleted from the original. Items
adopted **from the login keychain** must survive the suspicion rules — the access
code, trusted controllers, guess counters and the device token are refused if they
predate this identity, because anything running as the user could have planted
them. Items coming the other way were written under an enforced app identity and
are adopted as they stand. The Device ID and the device key are never regenerated
by either move. A build in login mode cannot read the data-protection keychain at
all, so that direction only happens where the entitlement exists.

## Supply-chain gates

Every push and PR to `main` runs, before anything else builds:

- `scripts/verify-deps.sh` — fails the build if a lockfile is missing, if a git
  dependency isn't pinned to an exact commit, if the Swift WebRTC package isn't
  pinned to an exact version, if `go.sum` is out of sync with `go.mod`, or if the
  Go toolchain in `go.mod` differs from the one CI builds with.
- `cargo audit` and `govulncheck`, pinned to exact versions. Any finding fails
  the build. The server builds on a current, patched Go toolchain (pinned via the
  `toolchain` directive) because most Go advisories are in the standard library.
- `cargo fmt --check` and `cargo clippy -D warnings` on every crate in the shared
  core.
- The full cross-language protocol test vectors (`protocol/vectors/`).
- `scripts/sbom.sh` — generates a CycloneDX SBOM per language (Rust, Go, Swift)
  and uploads it as a CI artifact on every run.
- `scripts/check-isolation.sh` on the actual built `.app`, every PR and every push
  to `main`. It also fails the build if the bundle's entitlements, its
  `embedded.provisionprofile` and its recorded `SKIPPERSecretStorageMode` do not
  agree, or if any entitlement outside the allowed set is signed in.
- `scripts/test-provision-profile.sh` — the profile validator (team, application
  identifier, expiry) against hand-made profile plists.

`./scripts/build.sh --reproducible` pins `SOURCE_DATE_EPOCH` to the commit being
built and normalises the Swift compiler's embedded debug paths, for anyone who
wants to verify a build matches its source. The one component that cannot be
reproduced bit-for-bit is `WebRTC.framework`: it is prebuilt by the stasel/WebRTC
project from Google's libwebrtc, pinned by exact version and checksum, and not
something this repo compiles. `Package.swift` pins it with `exact:`,
`build.sh` resolves with `--force-resolved-versions`, `build-core.sh` builds with
`cargo build --locked`, and the Rust core is linked by absolute path.

## Updates

The Mac app updates itself with no third-party updater. The release feed
(`GET /v1/app/releases/latest`, `protocol/API.md` §10) arrives over TLS and says
**what** to install. It is never trusted to say that the download is **safe**. A
compromised API, CDN or DNS can point the app at any file. The app installs it
only if every check below passes:

1. **Integrity.** The announced `size` must be between 1 byte and 512 MiB. The
   download is cut off as soon as it exceeds the announced `size`, and the finished
   `.dmg` must match both `size` and `sha256`. The download URL and every redirect
   must be https. Plain http is never accepted, loopback included (only the debug
   and `--test-hooks` builds used by tests allow http to loopback, and those builds
   never update themselves).
2. **Publisher.** The `SkipperDesk.app` inside the image is copied into a fresh
   directory that the app creates with mode 0700 under
   `~/Library/Application Support/app.skipperdesk.desktop/Updates/`. The app refuses
   the directory if it, or its parent, is a symlink or belongs to another user. The
   `app.skipperdesk.desktop` parent must not be writable by group or others, and
   `Updates` and the fresh directory must not be readable or writable by anyone else. The copy
   is opened once with `SecStaticCodeCreateWithPath`, and the app keeps that code
   object. It is checked with `SecStaticCodeCheckValidity` (strict validation, all
   architectures, nested code, no symlinks that escape the bundle) against:
   `anchor apple generic and identifier "app.skipperdesk.desktop" and certificate
   1[field.1.2.840.113635.100.6.2.6] exists and certificate
   leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] =
   "<TEAMID>"`. The two `field` terms limit this to Developer ID certificates, so an
   "Apple Development" certificate from the same team does not pass. The app reads
   `TEAMID` at runtime from **its own** code signature. The feed cannot choose the
   team.
3. **Notarization.** The same code object must also satisfy `anchor apple generic and
   notarized`. This check uses the public Security.framework API.
   `SecAssessmentCreate` has no public header in the macOS SDK.
4. **No downgrade.** The bundle identifier and `CFBundleVersion` are read from the
   sealed `Info.plist` of that same code object. The identifier must be the app's own.
   The build must be strictly greater than both the running build and the build of
   the copy currently at the install location, so a newer copy the user installed
   by hand is never replaced by an older one.
5. **The announced release.** The sealed build must equal the feed's `build`
   (compared by numeric value, so `4` and `4.0` match) and the sealed
   `CFBundleShortVersionString` must equal the feed's `version` exactly. A validly
   signed older-but-still-newer build cannot be served under another release's
   announcement.

### Installing

The app never checks a path and then acts on a path that someone else can change.

1. Right before the swap, it checks the kept code object again.
2. It walks the staged bundle and refuses it if any regular file has a second hard
   link, or if any entry disappears during the walk.
3. It clones the staged bundle with `clonefile(2)` (a plain `copyfile` when the volume
   cannot clone) into a **new** 0700 directory under `Updates`. The clone has new
   inodes, so write handles or hard links held on the staged files cannot reach it.
   It opens the clone as a new code object and runs checks 2 to 4 on it again, and
   the clone's build and version must equal the staged ones.
4. It exchanges the clone and the installed app in one `renamex_np(RENAME_SWAP)`
   call. The previous app lands at the clone's old path, inside the private
   directory, and never appears next to the app in `/Applications`. Only when the two
   are on different volumes does it fall back to `FileManager.replaceItemAt`; it
   then moves the hidden backup out of the install folder into the private directory
   straight away.
5. It opens the bundle **now at the install location** and runs checks 2 to 4 on it
   again. Its build and version must equal the verified clone's.

If step 5 fails, the app rolls back, but only to a previous app it has verified:
the backup in the private directory must pass the publisher and notarization checks
and be SkipperDesk (no newer-build rule, since it is the older copy). Only then are
the two exchanged again, and the restored app is checked once more. If the backup
fails that check, or any step of the rollback fails, the app **deletes nothing**. It
leaves whatever is at the install location, keeps the backup in its private
directory, stops checking for updates for this run, and shows "SkipperDesk could not
finish updating. Reinstall from skipperdesk.app."

The review race harness (`review3/client-upd`) measured this against a process that
kept swapping the staged bundle with an unsigned one, and another that kept swapping
any `.SkipperDesk.app.previous-*` item next to the app with an attacker bundle:

| Run | Iterations | Verified installs | Refused before the swap | Unverified bundle installed | Install path deleted |
| --- | --- | --- | --- | --- | --- |
| staged-bundle swap (`race3`) | 400 | 363 | 37 | 0 | 0 |
| staged swap + backup swap (`variants rollback`) | 400 | 250 | 150 | 0 | 0 |
| held fd + hard link (`variants fdwrite`) | 50 | 0 | 50 | 0 tampered | 0 |

The previous flow left the attacker's bundle installed by rollback in 9 to 13 of 400
runs, and deleted the app folder in 141 to 168 of 400.

### What another process running as the same user can still do

The updater protects the install from tampering **in flight**. It is not a boundary
against malware that already runs as the same user:

- It **cannot** get an unverified bundle installed by swapping, hard-linking or
  writing the staged copy or the backup: the swap uses a fresh clone, and a rollback
  only restores a backup that passes the publisher check.
- It **cannot** make the updater delete the installed app.
- It **can** write to its own clone-to-be between step 3 and step 4 by finding the
  new directory, or modify `/Applications/SkipperDesk.app` after the install, or
  before any update ever runs, because the user owns those files. Nothing in the
  updater can stop that; Gatekeeper and the code signature at launch are the checks
  that apply.
- It **can** make an update fail repeatedly, which only leaves the current version
  installed or shows the reinstall message.

Verified on a notarized, stapled Developer ID build installed under `/Applications`
(macOS 14.2.1, SIP on): the U2 race fails against the current updater. Over 60
iterations each, driving real staged installs into `/Applications/SkipperDeskU2Test.app`,
a write file descriptor held open on a staged file across the swap tampered with the
installed bundle 0/60 times (the swap installs a fresh clone, so the fd points at the
discarded staging inode), and a hard link to a staged file was refused before the swap
60/60 times by the link-count check. Independently, macOS App Management blocks any
process that is not SkipperDesk from writing into the installed bundle once the app has
been registered and first launched (the `com.apple.macl` provenance is then set): a
direct write returns `EPERM` both from a process under the parent app and from an
unrelated binary launched by `launchd`, so this is a second, OS-level barrier and not a
masking artefact of the launching process holding the permission. The barrier does not
apply to a bundle placed by a command-line copy that has never been registered, and a
process running as the same user can still modify `/Applications/SkipperDesk.app`
before any update runs; the code signature and Gatekeeper at launch remain the checks
for that case.

If any check fails, the app discards the download and logs the reason. The user sees
nothing alarming. The app does not retry that build during this run. Builds are
compared by their numeric value, so `4`, `4.0` and `04` count as the same build.

The updater is off entirely, with "Updates are disabled in development builds.", in
these cases:

- The build has no Developer ID Team ID (ad-hoc or locally signed).
- The running app does not satisfy its own pinned requirement.
- The build has development hooks compiled in (debug or `--test-hooks`).

The app installs a verified update in three situations:

- When SkipperDesk quits.
- When the user chooses "Restart to Update". This only works when the session phase
  is idle, not while a session is connecting, waiting for consent, live or
  reconnecting.
- Between 03:00 and 05:00 local time, when "Install updates automatically" is on (the
  default), only if this Mac is in the host role and the session phase is idle.
  Controllers never install on this schedule.

Because the designated requirement does not change between versions, macOS keeps the
Screen Recording and Accessibility grants.

This page will be updated as Phase 4 (client security pass) and Phase 5 (backend)
land. Last updated 2026-09-17.
