import SwiftUI

public enum SkipperSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum SkipperRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 14
    public static let pill: CGFloat = 999
}

public enum SkipperElevation {
    case none
    case low
    case high

    var radius: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 6
        case .high: return 24
        }
    }

    var y: CGFloat {
        switch self {
        case .none: return 0
        case .low: return 2
        case .high: return 10
        }
    }

    var opacity: Double {
        switch self {
        case .none: return 0
        case .low: return 0.10
        case .high: return 0.24
        }
    }
}

public enum SkipperMotion {
    public static let quick = Animation.easeOut(duration: 0.12)
    public static let standard = Animation.easeInOut(duration: 0.20)
    public static let gentle = Animation.easeInOut(duration: 0.32)
    public static let toolbarReveal = Animation.easeOut(duration: 0.20)
    public static let toolbarHideDelaySeconds: Double = 2.0
}

public enum SkipperLayout {
    public static let windowWidth: CGFloat = 920
    public static let windowHeight: CGFloat = 600
    public static let minWindowWidth: CGFloat = 720
    public static let minWindowHeight: CGFloat = 520
    public static let contentMaxWidth: CGFloat = 720
}

extension View {
    public func skipperElevation(_ elevation: SkipperElevation) -> some View {
        shadow(
            color: Color.black.opacity(elevation.opacity),
            radius: elevation.radius,
            x: 0,
            y: elevation.y
        )
    }
}
