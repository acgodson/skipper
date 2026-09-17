import Foundation
import AppKit
import CoreGraphics
import RemoteControlCore

@MainActor
final class Node {

    let role: Wire.Role
    let coordinator: SessionCoordinator
    let identity: IdentityStore

    init(role: Wire.Role) throws {
        self.role = role
        self.identity = try IdentityStore()
        self.coordinator = SessionCoordinator(identity: identity, role: role)
        coordinator.onEvent = { [weak self] event in self?.report(event) }
    }

    // MARK: Output

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        object["role"] = role.rawValue
        object["t"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func report(_ event: CoordinatorEvent) {
        switch event {
        case .signalingState(let state):
            emit("signaling", ["state": describe(state)])
        case .signalingDisconnected(let reason):
            emit("signaling_down", ["reason": reason])
        case .authenticated(let hello):
            emit("hello_ok", [
                "deviceId": hello.deviceId,
                "iceServers": hello.iceServers.count,
                "turn": hello.iceServers.contains { $0.username != nil },
                "activeSessionId": hello.activeSessionId ?? "",
                "heartbeatSec": hello.heartbeatSec,
            ])
        case .presence(let deviceID, let online):
            emit("presence", ["deviceId": deviceID, "online": online])
        case .sessionGranted(let sessionID, let grantedRole):
            emit("session", ["sessionId": sessionID, "as": grantedRole.rawValue])
        case .resumed(let sessionID, let peerAttached):
            emit("resumed", ["sessionId": sessionID, "peerAttached": peerAttached, "usedAccessCode": false])
        case .silentReconnect(let reason):
            emit("silent_reconnect", ["reason": reason])
        case .phase(let phase):
            emit("phase", ["phase": describe(phase)])
        case .ice(let state):
            emit("ice", ["state": state.rawValue])
        case .dataChannel(let label, let allOpen):
            emit("datachannel", ["label": label, "allOpen": allOpen])
        case .roundTrip(let seconds):
            emit("pong", ["rttMs": Int((seconds * 1000).rounded())])
        case .connectFailed(let failure):
            var fields: [String: Any] = ["code": failure.code, "message": failure.localizedDescription]
            if case .rateLimited(let retry) = failure { fields["retryAfterSec"] = retry }
            emit("connect_error", fields)
        case .bye(let reason):
            emit("bye", ["reason": reason])
        case .accessCodeRequired(let reason):
            emit("access_code_required", ["reason": reason])
        case .iceRestartStarted(let relayOnly):
            emit("ice_restart", ["relayOnly": relayOnly])
        case .remoteDescription(let type, let restart):
            emit("remote_sdp", ["sdpType": type, "restart": restart])
        case .peerAuthFailed(let reason):
            emit("peer_auth_failed", ["reason": reason])
        case .pake(let step, let outgoing):
            emit("pake", ["step": step, "outgoing": outgoing])
        case .pakeCompleted(let peerPubkey):
            emit("pake_ok", ["peerPubkey": peerPubkey])
        case .pakeFailed(let reason, let authentication):
            emit("pake_failed", ["reason": reason, "auth": authentication])
        case .captureState(let state):
            switch state {
            case .idle: emit("capture", ["state": "idle"])
            case .starting: emit("capture", ["state": "starting"])
            case .running(let width, let height, let fps):
                emit("capture", ["state": "running", "w": width, "h": height, "fps": fps])
            case .failed(let failure):
                emit("capture", ["state": "failed",
                                 "permission": failure.isPermissionProblem,
                                 "message": failure.localizedDescription])
            }
        case .remoteVideo(let present):
            emit("remote_video", ["present": present])
        case .accessibility(let granted):
            emit("accessibility", ["granted": granted])
        case .inputApplied(let type, let events):
            emit("input_applied", ["type": type, "events": events])
        case .clipboard(let incoming, let bytes):
            emit("clipboard", ["incoming": incoming, "bytes": bytes])
        case .gesture(let name):
            emit("gesture", ["name": name])
        case .cursorShape(let shape, let outgoing):
            emit("cursor_shape", ["shape": shape.rawValue, "outgoing": outgoing])
        }
    }

    private func pointerEvent(x: Double, y: Double,
                              kind: PointerEventKind,
                              button: MouseButton = .left) -> RemotePointerEvent {
        let sample = RemotePointerSample(viewPoint: CGPoint(x: x, y: y),
                                         remotePixel: CGPoint(x: x * 1000, y: y * 1000),
                                         normalized: CGPoint(x: x, y: y),
                                         insideVideo: true)
        return RemotePointerEvent(sample: sample, kind: kind, button: button)
    }

    private func setLocalClipboard(_ text: String) {
        let pasteboard = ClipboardMonitor.environmentPasteboard()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func localClipboard() -> String {
        ClipboardMonitor.environmentPasteboard().string(forType: .string) ?? ""
    }

    private func describe(_ state: SignalingState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .authenticating: return "authenticating"
        case .authenticated: return "authenticated"
        case .waitingToRetry(let delay): return String(format: "retry_in_%.2f", delay)
        case .stopped(let why): return "stopped:\(why)"
        }
    }

    private func describe(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .closed(let reason): return "closed:\(reason)"
        }
    }

    // MARK: Commands

    func start() {
        emit("ready", [
            "deviceId": identity.deviceID,
            "accessCode": identity.accessCode,
            "registered": identity.isServerRegistered,
            "server": coordinator.signaling.config.signalingURL.absoluteString,
        ])
        coordinator.start()
    }

    func handle(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { return }
        switch command {
        case "whoami":
            emit("whoami", ["deviceId": identity.deviceID, "accessCode": identity.accessCode])

        case "watch":
            guard parts.count >= 2 else { return }
            coordinator.presence.watch(deviceID: parts[1])
            emit("watching", ["deviceId": parts[1]])

        case "connect":
            guard parts.count >= 3 else { return }
            let remember = parts.count >= 4 && parts[3] == "remember"
            Task {
                do {
                    try await coordinator.connect(deviceID: parts[1], accessCode: parts[2], remember: remember)
                } catch {
                    let failure = (error as? ConnectFailure) ?? ConnectFailure(error)
                    emit("connect_error", ["code": failure.code, "message": failure.localizedDescription])
                }
            }

        case "ping":
            do { try coordinator.sendPing() } catch { emit("error", ["message": "\(error)"]) }

        case "display":
            try? coordinator.sendDisplayInfo(width: 3024, height: 1964, scale: 2.0)

        case "quality":
            guard parts.count >= 2 else { return }
            let mode = QualityWireMode(wire: parts[1])
            coordinator.setQuality(mode)
            emit("quality_set", ["mode": mode.rawValue])

        case "video-stats":
            Task {
                let stats = await coordinator.videoStatistics()
                emit("video_stats", [
                    "framesEncoded": stats.framesEncoded,
                    "framesSent": stats.framesSent,
                    "bytesSent": stats.bytesSent,
                    "framesDecoded": stats.framesDecoded,
                    "framesReceived": stats.framesReceived,
                    "bytesReceived": stats.bytesReceived,
                    "fps": stats.framesPerSecond,
                    "w": stats.frameWidth,
                    "h": stats.frameHeight,
                    "encoder": stats.encoderImplementation,
                    "decoder": stats.decoderImplementation,
                    "codec": stats.codecMimeType,
                    "hwH264": stats.isHardwareH264,
                ])
            }

        case "codecs":
            var fields: [String: Any] = [:]
            for (key, value) in PeerSession.videoCodecReport() { fields[key] = value }
            emit("codecs", fields)

        case "move":
            guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            coordinator.input.handle(pointerEvent(x: x, y: y, kind: .move))

        case "mousedown", "mouseup", "mousedrag":
            guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            let button = parts.count >= 4 ? (MouseButton(wire: Int(parts[3]) ?? 0) ?? .left) : .left
            let kind: PointerEventKind = command == "mousedown" ? .down : (command == "mouseup" ? .up : .drag)
            coordinator.input.handle(pointerEvent(x: x, y: y, kind: kind, button: button))

        case "scroll":
            guard parts.count >= 3, let dx = Double(parts[1]), let dy = Double(parts[2]) else { return }
            let phase = ScrollPhase(wire: parts.count >= 4 ? parts[3] : "changed")
            coordinator.input.send?(.scroll(ScrollPayload(dx: dx, dy: dy, phase: phase)))

        case "key":
            guard parts.count >= 3, let keycode = UInt16(parts[2]) else { return }
            let mods = KeyModifiers(wire: parts.count >= 4 ? (Int(parts[3]) ?? 0) : 0)
            coordinator.sendKey(down: parts[1] == "down", keycode: keycode, modifiers: mods)

        case "gesture":
            guard parts.count >= 2, let name = GestureName(wire: parts[1]) else {
                emit("error", ["message": "unknown gesture"]); return
            }
            coordinator.sendGesture(name)

        case "input-reset":
            coordinator.input.reset()
            emit("input_reset_sent", [:])

        case "clipboard-set":
            let text = parts.dropFirst().joined(separator: " ")
            setLocalClipboard(text)
            emit("clipboard_local_set", ["bytes": text.utf8.count])

        case "clipboard-get":
            let text = localClipboard()
            emit("clipboard_local", ["bytes": text.utf8.count, "sha": ClipboardSyncEngine.hash(text)])

        case "input-stats":
            emit("input_stats", [
                "injected": coordinator.injectedEventCount,
                "canInject": coordinator.canInjectInput,
                "heldButtons": coordinator.injector.heldButtons.count,
                "heldKeys": coordinator.injector.heldKeycodes.count,
                "heldModifiers": coordinator.injector.heldModifierKeycodes.count,
                "idle": coordinator.injector.isIdle,
            ])

        case "drop-socket":
            coordinator.dropSignalingSocket()
            emit("socket_dropped", [:])

        case "cursor-shape":
            let observer = coordinator.cursorObserver
            let system = NSCursor.currentSystem.map { observer.classify($0).rawValue } ?? "unavailable"
            let selfRecognised = observer.recognisedShapes.filter { shape in
                observer.referenceCursor(for: shape).map { observer.classify($0) == shape } ?? false
            }
            emit("cursor_probe", [
                "system": system,
                "recognised": observer.recognisedShapes.map(\.rawValue),
                "selfRecognised": selfRecognised.map(\.rawValue),
            ])

        case "ice-restart":
            coordinator.forceICERestart()

        case "bye":
            coordinator.disconnect(reason: Wire.ByeReason.userEnded)

        case "trusted":
            let trusted = (try? identity.secrets.trustedControllers()) ?? [:]
            emit("trusted", ["count": trusted.count, "pubkeys": trusted.keys.sorted()])

        case "refresh-code":
            Task {
                do {
                    let fresh = try await identity.refreshAccessCode()
                    emit("code_refreshed", ["accessCode": fresh])
                } catch {
                    emit("error", ["message": "\(error)"])
                }
            }

        case "status":
            emit("status", [
                "phase": describe(coordinator.phase),
                "signaling": describe(coordinator.signalingState),
                "ice": coordinator.iceState.rawValue,
                "relayOnly": coordinator.isRelayOnly,
                "channels": coordinator.dataChannelsOpen,
                "sessionId": coordinator.sessionID ?? "",
                "presence": coordinator.presence.state.rawValue,
                "needsAccessCode": coordinator.needsAccessCode,
                "rttMs": coordinator.lastRoundTrip.map { Int(($0 * 1000).rounded()) } ?? -1,
                "remoteVideo": coordinator.hasRemoteVideo,
                "quality": coordinator.qualityMode.rawValue,
                "localDisplay": coordinator.localDisplay.map { "\($0.w)x\($0.h)" } ?? "",
                "remoteDisplay": coordinator.remoteDisplay.map { "\($0.w)x\($0.h)" } ?? "",
            ])

        case "quit":
            coordinator.stop()
            emit("bye_local", [:])
            exit(0)

        default:
            emit("error", ["message": "unknown command \(command)"])
        }
    }
}

@MainActor var sharedNode: Node?

@MainActor
func bootstrap() {
    let roleName = ProcessInfo.processInfo.environment["RC_ROLE"] ?? "host"
    guard let role = Wire.Role(rawValue: roleName) else {
        FileHandle.standardError.write(Data("RC_ROLE must be host or controller\n".utf8))
        exit(2)
    }
    do {
        let node = try Node(role: role)
        sharedNode = node
        node.start()
    } catch {
        FileHandle.standardError.write(Data("rc-node: \(error)\n".utf8))
        exit(1)
    }

    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            Task { @MainActor in sharedNode?.handle(trimmed) }
        }
        Task { @MainActor in
            sharedNode?.coordinator.stop()
            exit(0)
        }
    }
}

Task { @MainActor in bootstrap() }
dispatchMain()
