import Foundation

public enum DevelopmentHook: CaseIterable {
    case identityDirectory
    case devFileIdentity
    case dumpFrame
    case inputSelfTest
    case captureSource
    case syntheticSize
    case pasteboardName
    case settingsSuite
    case autoLink
    case autoConnect
    case logFile
    case deviceLabel
    case handshakeTimeout
    case requestTimeout
    case heartbeatInterval
    case renewInterval
    case backoffMinimum
    case backoffMaximum
    case iceRestartDelay
    case iceFailureGrace
    case icePolicy
}

public enum DevelopmentHooks {

    public static let diagnosticsRequested = ProcessInfo.processInfo.environment["RC_DEBUG"] == "1"

#if DEBUG || SKIPPER_TEST_HOOKS
    public static let areCompiledIn = true

    public static func value(_ hook: DevelopmentHook) -> String? {
        environmentValue(named: variableName(hook))
    }

    public static func value(_ hook: DevelopmentHook, in environment: [String: String]) -> String? {
        guard let raw = environment[variableName(hook)], !raw.isEmpty else { return nil }
        return raw
    }

    public static func environment(for hooks: [DevelopmentHook]) -> [String: String] {
        var values: [String: String] = [:]
        for hook in hooks {
            if let raw = value(hook) { values[variableName(hook)] = raw }
        }
        return values
    }

    @inline(never)
    public static func environmentValue(named name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name], !raw.isEmpty else { return nil }
        return raw
    }

    public static func variableName(_ hook: DevelopmentHook) -> String {
        switch hook {
        case .identityDirectory: return "RC_IDENTITY_DIR"
        case .devFileIdentity: return "SKIPPER_DEV_FILE_IDENTITY"
        case .dumpFrame: return "RC_DUMP_FRAME"
        case .inputSelfTest: return "RC_INPUT_SELFTEST"
        case .captureSource: return "RC_CAPTURE_SOURCE"
        case .syntheticSize: return "RC_SYNTHETIC_SIZE"
        case .pasteboardName: return "RC_PASTEBOARD_NAME"
        case .settingsSuite: return "RC_SETTINGS_SUITE"
        case .autoLink: return "RC_AUTOLINK"
        case .autoConnect: return "RC_AUTOCONNECT"
        case .logFile: return "RC_LOG_FILE"
        case .deviceLabel: return "RC_DEVICE_LABEL"
        case .handshakeTimeout: return "RC_HANDSHAKE_TIMEOUT"
        case .requestTimeout: return "RC_REQUEST_TIMEOUT"
        case .heartbeatInterval: return "RC_HEARTBEAT_SEC"
        case .renewInterval: return "RC_RENEW_SEC"
        case .backoffMinimum: return "RC_BACKOFF_MIN"
        case .backoffMaximum: return "RC_BACKOFF_MAX"
        case .iceRestartDelay: return "RC_ICE_RESTART_DELAY"
        case .iceFailureGrace: return "RC_ICE_FAILURE_GRACE"
        case .icePolicy: return "RC_ICE_POLICY"
        }
    }
#else
    public static let areCompiledIn = false

    public static func value(_ hook: DevelopmentHook) -> String? { nil }

    public static func value(_ hook: DevelopmentHook, in environment: [String: String]) -> String? { nil }

    public static func environment(for hooks: [DevelopmentHook]) -> [String: String] { [:] }
#endif

    public static func isOn(_ hook: DevelopmentHook) -> Bool { value(hook) == "1" }
}
