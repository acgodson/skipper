# Windows x64 host: audit and implementation handoff

17 October 2026 · inspected local commit `8258838` · audit only, no application source changes.

## Decision for the owner

Build a **Windows 10 or 11 x64 host only**, controlled by the existing Mac app. Begin with the logged-in user's ordinary desktop. Keep one monitor, mouse/cursor, clicks, dragging, scrolling and keyboard. No Windows controller, iPad work, desktop-switching palette, file transfer or audio in this milestone. Do not promise lock-screen, UAC secure-desktop, pre-login or reboot access. Those require a separately tested privilege/session architecture.

Use a small native Windows window and tray menu, not a console and not a transplanted Mac layout. Prefer the existing Rust core with a thin Windows UI; choose the smallest maintainable native UI integration after a short build/package spike. Do not rewrite working crypto or introduce a framework migration just for appearance.

Cloud testing is possible **before publishing publicly**. Use native Windows CI for build/tests and a separate interactive Windows 11 x64 VM for desktop capture/input/installation and Mac interoperability. No cloud resources have been created. A cloud graphics driver is not coverage of all physical GPUs.

## Verified current status

The README and `apps/windows/WINDOWS-HOST.md` contain historical claims; use current code and `protocol/PROTOCOL.md` / `protocol/API.md` as authority.

| Area | Evidence in this checkout | Assessment |
| --- | --- | --- |
| Protocol | Normative contract and `core/crates/rc-proto/src/consts.rs` are v5. | Previous shorthand “Windows is v1” describes old behaviour, not the current envelope constant. |
| Host runtime | `apps/windows/crates/rc-host/src/main.rs`, `host.rs` | Existing skeleton, not release-ready. Defaults to old IP/pin, old RemoteControl console branding and unattended on. |
| Authentication | `rc-signal-client/src/lib.rs`; `host.rs` | No current REST bootstrap/account handoff integrated. Register passes empty ID certificate; authenticated peer proof, consent and dynamic TURN need integration. |
| SDP | `host.rs` builds answers with empty fp/pubkey/sig/mac and an explicit TODO. | Current authenticated peers must reject this. Never weaken Mac verification to accommodate it. |
| Reusable security | `core/crates/rc-identity` contains PAKE, SDP authentication, consent and ledger modules. | Reuse current implementations; missing Windows orchestration is the work. |
| Capture | `capture_windows.rs` | Explicit adapter passed with `D3D_DRIVER_TYPE_HARDWARE`; documented invalid combination. Output selection assumes first adapter/output; cannot assume it is the primary display. |
| Capture failure | `main.rs` | Falls back to synthetic video **with the real Windows injector**. Remove from production: no real input against a fake or unavailable screen. |
| Display geometry | `inject.rs::display_geometry()` returns `None`. | Host does not send useful display geometry through that path. Primary-screen capture vs virtual-desktop coordinates also needs reconciliation. |
| Media | `media.rs` | Software OpenH264, CPU RGB/YUV conversion. Hardware encoding isn't implemented. Smoothness is not verified. |
| Session lifecycle | `host.rs` takes the frame source once and runs an infinite `spawn_blocking` pump; teardown calls `abort()`. | Running blocking tasks need cooperative cancellation. Recover/recreate the source for subsequent sessions, await exit and stop capture when no session needs it. |
| Input | `rc-input`, `rc-host/src/inject.rs`, `inject_windows.rs` | Useful translation exists. Key-down immediately releases chord keys; held modifiers/keys need correct state. Reset does not track all pressed keys; SendInput result is ignored. |
| UI / consent | Console banner; no shipping window/tray UI found in host runtime. | Needs native host UI, explicit sharing state and consent controls. |
| Packaging | GNU cross-target config and windres manifest script; admin feature defaults on. | Not a polished installer. MSVC resource handling must be added if using native MSVC CI; missing resources must fail packaging, not warn and ship. |
| CI | `.github/workflows/ci.yml` excludes Windows crates from Rust test job; no Windows job. | Native Windows coverage is missing. |
| Release pipeline | `protocol/API.md` release feed and `scripts/publish-release.sh` are macOS-oriented; upload path is DMG-oriented. | Windows release/update/distribution needs an explicit small extension or separate beta path. No assumption that existing updater supports Windows. |
| Mac cursor | `RemoteScreenView.swift`, `RemoteSessionView.swift`, `GesturePalette.swift` | Likely overlay cursor ownership bug, described below. Not reproduced in a live two-machine session in this audit. |

Executed locally: `cargo test --offline -p rc-input -p rc-host --lib --tests`. **35 tests passed** (24 translation, 11 dispatch). This compiled the portable code on macOS; it did not execute Windows capture, injection, installer or Windows-only conditional code. No current Windows binary or crash dump was tested. No live AWS state, deployed backend version or production session health was audited.

## One prompt to give Claude

You are working in `/Users/godson/Desktop/remote-control`. Implement the plan in this document. Start by rereading current repository instructions and checking for changes since commit 8258838. Preserve unrelated changes. Treat historical Windows notes as context, not the current contract. Deliver in reviewable milestones; do not call compilation proof of remote-desktop operation.

### 1. Fix the Mac floating-control cursor first, in its own change

The user reports that the pointer disappears over the top floating session toolbar and the bottom floating action/gesture control. This is controller UI, so it must use a visible local cursor and must not forward its interactions to the remote computer.

Relevant files:
- `apps/macos/Sources/RemoteControlCore/Capture/RemoteScreenView.swift`
- `apps/macos/Sources/RemoteControl/RemoteSessionView.swift`
- `apps/macos/Sources/RemoteControl/GesturePalette.swift`
- `apps/macos/Sources/SkipperDesign/Components/SessionChrome.swift`

Current behaviour: RemoteScreenNSView hides NSCursor on enter/move and draws a CAShapeLayer cursor inside the video view. It restores the native cursor on mouse exit, focus loss or detachment. The overlaid SwiftUI toolbar only updates hover/reveal state; the palette likewise does not explicitly transfer cursor ownership. Entering an overlapping sibling control need not produce the underlying view's boundary exit, while its drawn cursor is behind the overlay or no longer updates. This is the likely cause, not a runtime-confirmed diagnosis.

Implement one balanced cursor-ownership policy: hide the native cursor only over actual interactive remote video with a usable custom cursor; show it over toolbar, palette button and expanded palette, menus/popovers, letterbox margins and other local overlays. Pass local-interaction state/exclusion geometry into the underlying NSView or use a central owner, rather than scattered unbalanced NSCursor.unhide() calls. Handle controls appearing under a stationary pointer. Do not rely solely on mouseExited or on NSCursor.arrow.set(), which does not balance a hide count. Restore on track removal, disconnect, reconnect/no picture, window deactivation/detachment and teardown; retain/remove notification observer tokens appropriately. Distinguish rendering from hit-testing. Prevent local control clicks/scrolls from reaching the remote host, and release any remotely held buttons/keys when capture ownership changes so drags do not stick. Preserve normal remote drag behaviour.

Add focused regression tests for ownership transitions and manually verify both floating controls, their menus, repeated entry/exit, fullscreen, focus loss, no-video/disconnect and stationary-pointer overlay reveal. Confirm the remote computer receives no clicks intended for local UI. Build/test the Mac app, report any live-session verification still pending, and keep this fix independent of the Windows release.

### 2. Bring the existing Windows host onto the current contract

Use `protocol/PROTOCOL.md` v5 and `protocol/API.md`, the current Mac orchestration and shared Rust identity/session code. Remove the old baked IP and certificate pin from the shipping path. Use the configured API domain and public-CA validation, current bootstrap/discovery, browser sign-in and registered `skipperdesk://` return handler, nonce binding, device credentials, device ID certificate persistence, entitlement handling, PAKE, signed/MACed SDP, consent and guess budgets, session-scoped TURN issuance/renewal and reconnect/reset rules. Check the production sign-in website already accepts `platform=windows`; make only necessary compatible changes.

Protect persisted credentials with an appropriate Windows facility (DPAPI/CNG as appropriate), user-restricted ACLs and atomic persistence. Never silently regenerate an unreadable identity, ignore failed persistence or log access codes, tokens or private keys. Keep diagnostic logging local and redacted. Preserve explicit user consent, default unattended access off, and code-refresh/trust revocation semantics. Do not claim hardware-backed keys unless actually used.

Do not downgrade the backend or disable verification. Prefer no server change for session operation; document and test any genuinely required API or distribution addition separately.

### 3. Correct capture, input and lifecycle before polishing

- Fix D3D11CreateDevice's adapter/driver combination. Microsoft requires UNKNOWN with a supplied adapter. Capture errors must be reported as unavailable, not silently replaced by test video. Synthetic source plus recording injector is explicit diagnostic mode only.
- Select the actual primary display, publish accurate dimensions/scale/platform and update on resolution/DPI changes. Translate coordinates relative to the captured monitor into the Windows virtual desktop correctly, including nonzero/negative offsets. One-monitor product scope must still work on a PC that has other monitors attached.
- Implement cooperative pump cancellation, reliable second/third connections, failure recovery and resource cleanup. No orphan encoder/capture loops after disconnect. Do not keep capturing while idle awaiting a session.
- Make keyboard/mouse state correct: left/right clicks, double-click, drag, wheel, held modifiers/keys, repeat, text, non-ASCII text, arrow/navigation keys, release/reset on all termination paths, and failure handling for SendInput. Test 100%, 150% and 200% DPI.
- Review H.264 negotiation, keyframe/PLI handling and congestion/rate control against the real Mac decoder. Prefer Media Foundation hardware encoding where available, with a bounded software fallback. Offer a conservative tested resolution/frame-rate fallback rather than burning CPU at full monitor resolution. Measure responsiveness, frame pacing, idle CPU and recovery; no unmeasured “smooth” claims.
- Clearly suspend remote input when capture is unavailable or the desktop is locked/protected. Never leave a stale picture implying the user can safely click it.

### 4. Keep cross-platform semantics simple and extensible

Use the host's declared platform and explicit supported capabilities; don't infer it from a device name or assume every controller is a Mac. The existing `display_info.os` is a starting point, not a complete capabilities protocol. Inspect current mirrors before changing it. The current keycode wire semantics are Mac-oriented: preserve that contract for existing peers and isolate translation in adapters. If new capabilities/keyboard fields are needed, document and test compatibility across Go/Rust/Swift, including old/unknown peers. Do not silently reinterpret existing numeric keycodes as Windows VK codes.

For this release hide the Mac gesture palette when controlling Windows. Show only connection status, keyboard capture, supported quality controls and Disconnect. Avoid Mac-specific troubleshooting copy for a Windows host. No need for Mission Control, desktop previews, Spotlight/Search or desktop-switching actions. The user can click Windows Start normally. Existing gesture mapping can remain internal but must not be advertised without verification.

Mac-to-Windows defaults: Command+C/V/X/A/Z maps to Windows Ctrl equivalents; Control maps to Ctrl; Option maps to Alt; deduplicate overlapping modifiers; handle Backspace/Delete/navigation and layout text correctly. Define these as a named policy with tests. Keep physical-key/chord interpretation separate from resolved text, so a later Windows controller can map its keys to Mac behaviour without replacing the transport. Do not implement that reverse controller now.

### 5. A simple Windows host experience

Use Windows title-bar behaviour, Segoe UI, native focus/tab order, standard controls, high-DPI support, light/dark and a tray menu. Retain the SkipperDesk name, compass and Harbor teal accent. One window, no controller/host role switch:

1. “Share this PC” heading and readable status.
2. Sign in when needed; account/hours summary after sign-in.
3. Device ID with Copy; masked access code with Show/Copy/Refresh.
4. Start/Stop sharing, plus an Unattended access toggle with its consequence.
5. Active-session state and Disconnect; Allow/Decline consent when required.
6. Tray actions: Open SkipperDesk, Stop sharing/Disconnect as appropriate, Quit.

Expose no crypto/networking internals in normal UI. Closing the window may leave sharing active in the tray only with a clear first-use explanation; Quit stops sharing. Launch at sign-in is optional and explicit. Do not add a service or automatic pre-login hosting for this milestone. App should remain responsive during connection/capture failures.

Prefer a normal-user process for the first beta. Ordinary desktop control is the contract. Do not inherit requireAdministrator blindly or imply it solves secure-desktop access. If elevated-application control becomes required, propose a separate reviewed privilege design; never disable UAC or tell users to turn off protection.

### 6. Windows x64 build and installation

Target Windows 11 x64 (Intel/AMD, not ARM64, not 32-bit). Use native Windows CI and `x86_64-pc-windows-msvc` if the dependency/toolchain spike succeeds; otherwise document a pinned GNU alternative and verify its runtime dependencies. Current build.rs assumes windres and only warns on missing resources: make production metadata/DPI/manifest embedding deterministic for the selected toolchain and fail packaging if absent.

Deliver one conventional versioned installer (MSI or setup EXE; choose a maintained route) with no console window, terminal commands, manual DLL downloads, Rust/.NET/WebView runtime setup or security bypass instructions for the user. Bundle legally redistributable runtime dependencies as needed, include licenses, support per-user install where feasible, register the app return URI and provide clean uninstall/upgrade. Preserve identity/settings on upgrade. Explain what uninstall removes and what account/device records it leaves.

Sign and timestamp both executable and installer with Authenticode when credentials are available. Signing is not a guarantee of zero SmartScreen warnings. Provide a reproducible unsigned internal beta artifact if signing isn't available, clearly distinguish it from a public release, and name the missing signing prerequisite.

Audit the website deployment script before uploading: its current asset preservation is DMG-oriented, so a later ordinary sync could delete a Windows installer unless exclusions/storage layout are updated. Extend the release feed/publisher per platform or use a clearly separated manual beta-download path. Do not route an EXE through the Mac DMG updater. Automatic Windows updates may be deferred for this beta, but an in-app version/update link and identity-preserving reinstall must work. Keep Mac release behaviour unchanged and don't add public download claims until the beta artifact is validated.

### 7. Verify without a physical PC

Set up two distinct lanes:

**Native Windows CI:** pinned Windows runner/toolchain; build x64, run shared vectors, input and lifecycle tests, construct installer, inspect machine architecture/signature/dependencies, upload versioned private/internal artifacts. Use explicit synthetic/recording mode for headless protocol tests. Record which tests exercise real Windows APIs. A standard runner is not evidence of interactive graphics success.

**Interactive cloud VM:** prepare a reproducible, licensed Windows 11 x64 VM with a usable virtual display/graphics driver; GPU-capable configuration when validating hardware encode. Check image licensing, graphics support, regional availability and cost before requesting paid resources. Include automatic shutdown/cleanup and restricted administrative access. Use RDP only for setup/recovery; measure SkipperDesk separately, document session/display behaviour when RDP connects or disconnects, and ensure it is capturing the intended interactive desktop. An ordinary Windows Server EC2 image is not Windows 11 client validation. A Windows ARM VM running x64 under emulation is not native x64 validation either.

Before provisioning, deliver the chosen image/size, expected cost estimate, exact setup and teardown, and tests it can/cannot cover. Never provision paid resources or publish a beta merely to obtain testing without the owner's approval. If cloud access is unavailable, finish reproducible code/build artifacts and explicitly mark interactive Windows validation blocked; don't describe the app as release-ready.

Test clean install without developer tools; sign-in/consent; Mac→Windows video and input; Windows applications such as Notepad and File Explorer; shortcuts, text and held keys; DPI/resolution changes; five consecutive connect/disconnect cycles; network interruptions; direct and TURN sessions; long idle vs active sessions; no-input-on-unavailable-screen; lock/unlock limitations; upgrade/uninstall; Mac→Mac regression; and the separate Mac floating-cursor fix. Capture logs, screenshots/recording and measured performance. Physical Intel/AMD/NVIDIA hardware validation remains a later beta gate, with that limitation stated.

### 8. Delivery

Provide small logical commits/changes, exact build/test commands and outcomes, artifact path and checksum, installation steps, remaining blockers, architecture/OS support, and a short owner-facing summary. Update the stale Windows handoff and status documents to distinguish inspected, tested-portably, Windows-CI-tested and interactively-verified. Do not ship or change production infrastructure as part of implementation without the owner's deployment instruction.

## Primary references checked for this audit

- [D3D11CreateDevice](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-d3d11createdevice): explicit adapter requires UNKNOWN driver type; current call uses HARDWARE.
- [SendInput](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-sendinput): input injection is limited by process integrity; elevation is not a blanket remote-control solution.
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners): native Windows build/test machines are available, distinct from interactive desktop acceptance testing.
- [Windows client images on Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/client-images): verify eligibility and image/licensing before choosing a VM.
- [GPU acceleration on Azure Virtual Desktop](https://learn.microsoft.com/azure/virtual-desktop/enable-gpu-acceleration): virtual graphics and encoding require a suitable VM/driver configuration; RDP acceleration alone does not validate SkipperDesk's encoder.
- [SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation): the old note claiming EV signing guarantees immediate reputation is obsolete. Do not promise warning-free installation.
