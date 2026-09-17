import SwiftUI
import AppKit

public enum SkipperColor {

    public static let canvas = dynamic(light: 0xF3F5F6, dark: 0x16191B)
    public static let surface = dynamic(light: 0xFFFFFF, dark: 0x212528)
    public static let surfaceMuted = dynamic(light: 0xEAEEF0, dark: 0x282D31)
    public static let border = dynamic(light: 0xDBE1E4, dark: 0x33393E)
    public static let borderStrong = dynamic(light: 0xBFC8CD, dark: 0x474F55)

    public static let textPrimary = dynamic(light: 0x131719, dark: 0xF1F4F5)
    public static let textSecondary = dynamic(light: 0x57626A, dark: 0xA4AEB5)
    public static let textTertiary = dynamic(light: 0x838D95, dark: 0x79838B)

    public static let accent = dynamic(light: 0x0E6F7A, dark: 0x45B4C0)
    public static let accentPressed = dynamic(light: 0x0A555E, dark: 0x67C7D1)
    public static let accentSoft = dynamic(light: 0xDDEFF1, dark: 0x123238)
    public static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x06191C)

    public static let positive = dynamic(light: 0x1C8A52, dark: 0x53C78C)
    public static let positiveSoft = dynamic(light: 0xDFF1E7, dark: 0x13301F)
    public static let attention = dynamic(light: 0xA76500, dark: 0xE2A951)
    public static let attentionSoft = dynamic(light: 0xFAECD8, dark: 0x352612)
    public static let critical = dynamic(light: 0xB02A22, dark: 0xF08078)
    public static let criticalSoft = dynamic(light: 0xFAE3E1, dark: 0x3A1917)
    public static let neutralSoft = dynamic(light: 0xE6EAEC, dark: 0x2B3034)

    public static let scrim = Color.black.opacity(0.62)
    public static let stage = dynamic(light: 0x0B0D0E, dark: 0x0B0D0E)
    public static let onStage = Color.white

    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

public enum SkipperTone: String, CaseIterable, Sendable {
    case neutral
    case accent
    case positive
    case attention
    case critical

    public var foreground: Color {
        switch self {
        case .neutral: return SkipperColor.textSecondary
        case .accent: return SkipperColor.accent
        case .positive: return SkipperColor.positive
        case .attention: return SkipperColor.attention
        case .critical: return SkipperColor.critical
        }
    }

    public var background: Color {
        switch self {
        case .neutral: return SkipperColor.neutralSoft
        case .accent: return SkipperColor.accentSoft
        case .positive: return SkipperColor.positiveSoft
        case .attention: return SkipperColor.attentionSoft
        case .critical: return SkipperColor.criticalSoft
        }
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
