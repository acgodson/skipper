import Foundation

public enum DevelopmentHook: CaseIterable {
    case identityDirectory
    case dumpFrame
    case inputSelfTest
    case captureSource
    case syntheticSize
    case pasteboardName
    case settingsSuite
    case autoLink
    case autoConnect
    case logFile
}

public enum DevelopmentHooks {

#if DEBUG || SKIPPER_TEST_HOOKS
    public static let areCompiledIn = true

    public static func value(_ hook: DevelopmentHook) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[variableName(hook)], !raw.isEmpty else { return nil }
        return raw
    }

    public static func variableName(_ hook: DevelopmentHook) -> String {
        switch hook {
        case .identityDirectory: return "RC_IDENTITY_DIR"
        case .dumpFrame: return "RC_DUMP_FRAME"
        case .inputSelfTest: return "RC_INPUT_SELFTEST"
        case .captureSource: return "RC_CAPTURE_SOURCE"
        case .syntheticSize: return "RC_SYNTHETIC_SIZE"
        case .pasteboardName: return "RC_PASTEBOARD_NAME"
        case .settingsSuite: return "RC_SETTINGS_SUITE"
        case .autoLink: return "RC_AUTOLINK"
        case .autoConnect: return "RC_AUTOCONNECT"
        case .logFile: return "RC_LOG_FILE"
        }
    }
#else
    public static let areCompiledIn = false

    public static func value(_ hook: DevelopmentHook) -> String? { nil }
#endif

    public static func isOn(_ hook: DevelopmentHook) -> Bool { value(hook) == "1" }
}
