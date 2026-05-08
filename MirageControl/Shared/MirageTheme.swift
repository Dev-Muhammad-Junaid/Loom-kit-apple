//
//  MirageTheme.swift
//  MirageControl – Shared
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Hex

extension Color {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (with or without `#`).
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var i: UInt64 = 0
        Scanner(string: h).scanHexInt64(&i)
        let a, r, g, b: UInt64
        switch h.count {
        case 3:  (a, r, g, b) = (255, (i >> 8) * 17, (i >> 4 & 0xF) * 17, (i & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, i >> 16, i >> 8 & 0xFF, i & 0xFF)
        case 8:  (a, r, g, b) = (i >> 24, i >> 16 & 0xFF, i >> 8 & 0xFF, i & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Mirage design tokens

enum MirageTheme {

    // MARK: Brand (SF Symbol accents, ripples, Mac header)

    static let violet = Color(hex: "6C63FF")
    static let violetSoft = Color(hex: "A78BFA")
    static let indigo = Color(hex: "818CF8")
    static let emerald = Color(hex: "10B981")
    static let mint = Color(hex: "34D399")
    static let sky = Color(hex: "38BDF8")
    /// Connected / live / approved status — use everywhere instead of `Color.green`.
    static let success = Color(hex: "22C55E")
    /// Cautionary / pending status — use instead of bare `Color.orange`
    /// (host-disconnected overlay, "requesting access" indicators, etc.).
    static let warning = Color(hex: "F59E0B")
    /// Negative / blocked status — use instead of bare `Color.red`
    /// (denied overlay, reject buttons, destructive accents).
    static let danger = Color(hex: "EF4444")

    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let hero: CGFloat = 28
    }

    // MARK: Surfaces (iOS shell + shared semantics)

    static func canvasBackground(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(hex: "0A0A0F")
        case .light:
            #if os(iOS)
            return Color(UIColor.systemGroupedBackground)
            #elseif os(macOS)
            return Color(nsColor: .windowBackgroundColor)
            #else
            return Color(white: 0.95)
            #endif
        @unknown default:
            return Color(hex: "0A0A0F")
        }
    }

    static func cardFill(_ scheme: ColorScheme, pressed: Bool = false) -> Color {
        switch scheme {
        case .dark:
            return .white.opacity(pressed ? 0.12 : 0.07)
        case .light:
            #if os(iOS)
            return Color(UIColor.systemBackground).opacity(pressed ? 0.9 : 1.0)
            #elseif os(macOS)
            return Color(nsColor: .controlBackgroundColor)
            #else
            return Color(white: 1)
            #endif
        @unknown default:
            return .white.opacity(0.07)
        }
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white.opacity(0.1)
        case .light: return Color.primary.opacity(0.08)
        @unknown default: return .white.opacity(0.1)
        }
    }

    static func navDivider(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white.opacity(0.07)
        case .light: return Color.primary.opacity(0.08)
        @unknown default: return .white.opacity(0.07)
        }
    }

    static func tabContainerFill(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white.opacity(0.06)
        case .light:
            #if os(iOS)
            return Color(UIColor.systemFill)
            #elseif os(macOS)
            return Color(nsColor: .controlBackgroundColor).opacity(0.65)
            #else
            return Color(white: 0.9)
            #endif
        @unknown default:
            return .white.opacity(0.06)
        }
    }

    static func tabContainerBorder(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white.opacity(0.09)
        case .light: return Color.primary.opacity(0.06)
        @unknown default: return .white.opacity(0.09)
        }
    }

    /// Search field on the Apps grid — same fill as the control tab strip container.
    static func searchFieldFill(_ scheme: ColorScheme) -> Color {
        tabContainerFill(scheme)
    }

    static func tabPillSelectedFill(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white.opacity(0.14)
        case .light:
            #if os(iOS)
            return Color(UIColor.systemBackground)
            #elseif os(macOS)
            return Color(nsColor: .controlBackgroundColor)
            #else
            return Color(white: 1)
            #endif
        @unknown default:
            return .white.opacity(0.14)
        }
    }

    static func trackpadSurfaceFill(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white.opacity(0.06)
        case .light:
            #if os(iOS)
            return Color(UIColor.systemBackground)
            #elseif os(macOS)
            return Color(nsColor: .textBackgroundColor)
            #else
            return Color(white: 1)
            #endif
        @unknown default:
            return .white.opacity(0.06)
        }
    }

    static func subtleWellFill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(0.07)
    }

    // MARK: Authorization overlay

    /// Backdrop scrim behind the auth dialog. Card chrome and button chrome
    /// come from native materials / button styles — only the scrim opacity
    /// is opinionated.
    static func authScrim(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .black.opacity(0.45)
        case .light: return .black.opacity(0.22)
        @unknown default: return .black.opacity(0.45)
        }
    }

    // MARK: Error banner

    static func errorBannerFill(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return Color.red.opacity(0.38)
        case .light: return Color.red.opacity(0.14)
        @unknown default: return Color.red.opacity(0.38)
        }
    }

    static func errorBannerLabel(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return .white
        case .light: return Color(red: 0.55, green: 0.1, blue: 0.12)
        @unknown default: return .white
        }
    }

    // MARK: Mac menu bar

    static var headerGradientColors: [Color] {
        [violet, violetSoft]
    }

    // MARK: Hero sunset gradient (device picker / first-run hero background)

    /// Soft cherry-blossom-sunset palette used as the hero background on the
    /// device picker. 9 stops arranged in a 3×3 mesh: lavender top, pink
    /// middle, deep violet bottom. Pair with `MeshGradient` (iOS 18+) or fall
    /// back to a 3-stop `LinearGradient` using the first/middle/last colors.
    static let heroSunsetColors: [Color] = [
        // top — lavender / pale pink sky
        Color(red: 0.86, green: 0.80, blue: 0.92),
        Color(red: 0.90, green: 0.83, blue: 0.94),
        Color(red: 0.88, green: 0.81, blue: 0.93),
        // middle — pink blossom haze
        Color(red: 0.93, green: 0.70, blue: 0.82),
        Color(red: 0.90, green: 0.62, blue: 0.78),
        Color(red: 0.86, green: 0.58, blue: 0.78),
        // bottom — deep violet
        Color(red: 0.56, green: 0.28, blue: 0.72),
        Color(red: 0.50, green: 0.22, blue: 0.70),
        Color(red: 0.60, green: 0.32, blue: 0.78)
    ]

    /// Drop-in hero background view. Uses native `MeshGradient` on iOS 18+
    /// for the dreamy multi-point blend, falls back to a vertical
    /// `LinearGradient` (top→middle→bottom of `heroSunsetColors`) on iOS 17.
    @ViewBuilder
    static func heroSunsetBackground() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: heroSunsetColors
            )
        } else {
            LinearGradient(
                colors: [heroSunsetColors[1], heroSunsetColors[4], heroSunsetColors[7]],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: Status icons (auth overlay, pending dialog)

    /// Shared sizing for hierarchical SF Symbol icons in dialog states.
    enum StatusIcon {
        static let size: CGFloat = 52

        /// Color pair (primary, secondary) for hierarchical SF Symbol
        /// rendering, keyed by the connection status string used by
        /// `AuthorizationOverlay` and friends.
        static func colors(for status: String) -> (primary: Color, secondary: Color) {
            switch status {
            case "pending":
                return (MirageTheme.violet,  MirageTheme.violet.opacity(0.45))
            case "host_disconnected":
                return (MirageTheme.warning, MirageTheme.warning.opacity(0.5))
            case "denied":
                return (MirageTheme.danger,  MirageTheme.danger.opacity(0.45))
            default:
                return (Color.secondary,     Color.secondary.opacity(0.5))
            }
        }
    }

    /// Shadow color for floating dialog cards (auth overlay, modal sheets).
    static func dialogCardShadow(_ scheme: ColorScheme) -> Color {
        .black.opacity(scheme == .dark ? 0.35 : 0.12)
    }

    // MARK: Floating Action Buttons (Apps page keyboard / numeric toggles)

    /// Design tokens for the circular floating-action toggle buttons that
    /// surface the keyboard / numeric edit rows on the Apps page. Geometry,
    /// shadow, and animation come from the native `Button` styles
    /// (`.glass` / `.glassProminent` on iOS 26+, `.bordered` /
    /// `.borderedProminent` on iOS 17). Only the active tint is opinionated.
    enum FAB {
        /// Keyboard FAB matches brand violet.
        static let keyboardTint: Color = MirageTheme.violet
        /// Numeric FAB uses a complementary teal so the two toggles read
        /// distinctly against the same surface.
        static let numericTint:  Color = Color(hex: "0D9488")
    }

    // MARK: Typography (rounded matches picker / control chrome)

    enum TypeStyle {
        static let titleRounded = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let bodyRounded = Font.system(size: 15, weight: .regular, design: .rounded)
        static let captionRounded = Font.system(size: 13, weight: .regular, design: .rounded)
        static let buttonRounded = Font.system(size: 15, weight: .semibold, design: .rounded)
        /// Progress / empty-state titles (peer search, initializing, apps loading).
        static let loadingTitle = Font.system(size: 15, weight: .medium, design: .rounded)
    }
}
