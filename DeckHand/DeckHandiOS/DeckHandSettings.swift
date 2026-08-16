//
//  DeckHandSettings.swift
//  DeckHandiOS
//
//  User preferences for the remote. One observable store injected into the
//  view tree, persisted to `UserDefaults` on write.
//
//  Several of these knobs cost bandwidth or host CPU (mirror sharpness and
//  frame rate, input send rate, screenshot quality). They are deliberately
//  manual for now: a link-quality heuristic needs a baseline the user can
//  fall back to when it guesses wrong, so the explicit control ships first.
//

import Foundation
import SwiftUI

// MARK: - Choices

/// Frames per second the iPad asks the Mac to stream. The host clamps to 30,
/// so anything above that is wasted breath.
enum MirrorFrameRate: Int, CaseIterable, Identifiable, Codable {
    case economy = 15
    case standard = 20
    case smooth = 30

    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

/// How the mirror's stream resolution is chosen.
enum MirrorSharpness: String, CaseIterable, Identifiable, Codable {
    /// Follows the on-screen size — a corner tile streams far fewer pixels
    /// than a pinched-out mirror.
    case auto
    /// Pins the lowest tier no matter how large the mirror is drawn.
    case saver
    /// Pins the host's ceiling, for reading small text over a good link.
    case sharp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .saver: return "Battery saver"
        case .sharp: return "Sharp"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Matches the size you pinch the mirror to."
        case .saver: return "Lowest resolution. Best on a weak network."
        case .sharp: return "Highest resolution the Mac will send."
        }
    }

    /// Applies this preference to the width the mirror's size implies.
    func resolve(naturalWidth: Int) -> Int {
        switch self {
        case .auto: return naturalWidth
        case .saver: return 640
        case .sharp: return 1920
        }
    }
}

/// How often touch deltas are sent. 120 Hz matches ProMotion so no input is
/// discarded; 60 Hz halves packet volume on a congested link.
enum InputSendRate: Int, CaseIterable, Identifiable, Codable {
    case standard = 60
    case proMotion = 120

    var id: Int { rawValue }
    var label: String { "\(rawValue) Hz" }
}

enum HapticStrength: String, CaseIterable, Identifiable, Codable {
    case off
    case light
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .full: return "Full"
        }
    }

    /// Scales a requested haptic to this strength. `nil` means "don't fire".
    /// At `.light` everything collapses to the softest impact, so the app
    /// still confirms actions without thumping.
    func resolve(_ requested: GestureHaptic) -> GestureHaptic? {
        switch self {
        case .off:
            return nil
        case .light:
            return requested == .selection ? .selection : .light
        case .full:
            return requested
        }
    }
}

/// `CaptureQuality` is the wire type; these are just its labels. Region and
/// window captures already ship near-native, so this only moves full-screen.
extension CaptureQuality: Identifiable {
    public var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .native: return "Native"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "Smaller and faster over the network."
        case .high: return "Sharper text, larger transfers."
        case .native: return "Full Retina pixels. Slowest."
        }
    }
}

/// What the capture button does on a plain tap.
enum DefaultCapture: String, CaseIterable, Identifiable, Codable {
    case fullScreen
    case region
    case window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fullScreen: return "Full screen"
        case .region: return "Region"
        case .window: return "Window"
        }
    }

    var icon: String {
        switch self {
        case .fullScreen: return "rectangle.dashed"
        case .region: return "rectangle.dashed.badge.record"
        case .window: return "macwindow"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Where the mirror was last left, so it can come back the same size and in
/// the same corner instead of resetting to a small tile every session.
struct MirrorLayout: Codable, Equatable {
    var width: Double
    var offsetX: Double
    var offsetY: Double
}

// MARK: - Store

/// Single source of truth for user preferences, injected with
/// `.environmentObject`. Every property writes straight through to
/// `UserDefaults`, so there is no save step and nothing to lose on a crash.
@MainActor
final class DeckHandSettings: ObservableObject {
    private enum Key {
        static let pointerSensitivity = "settings.pointerSensitivity"
        static let inputSendRate = "settings.inputSendRate"
        static let hapticStrength = "settings.hapticStrength"
        static let naturalScrolling = "settings.naturalScrolling"
        static let mirrorFrameRate = "settings.mirrorFrameRate"
        static let mirrorSharpness = "settings.mirrorSharpness"
        static let rememberMirrorLayout = "settings.rememberMirrorLayout"
        static let mirrorLayout = "settings.mirrorLayout"
        static let screenshotQuality = "settings.screenshotQuality"
        static let defaultCapture = "settings.defaultCapture"
        static let autoSaveToPhotos = "settings.autoSaveToPhotos"
        static let appearance = "settings.appearance"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
        /// Owned by `StreamDeckGridView`; the key predates this store.
        static let hiddenApps = "hiddenBundleIDs"
    }

    private let defaults: UserDefaults

    // ── Pointer and gestures ────────────────────────────────────────
    @Published var pointerSensitivity: Float {
        didSet { defaults.set(pointerSensitivity, forKey: Key.pointerSensitivity) }
    }

    @Published var inputSendRate: InputSendRate {
        didSet { defaults.set(inputSendRate.rawValue, forKey: Key.inputSendRate) }
    }

    @Published var hapticStrength: HapticStrength {
        didSet {
            defaults.set(hapticStrength.rawValue, forKey: Key.hapticStrength)
            // Haptics fire from leaf views and gesture closures all over the
            // app, most of which have no reason to hold a settings
            // reference. Mirroring the choice onto the shared player keeps
            // one gate for every call site.
            GestureHaptic.strength = hapticStrength
        }
    }

    /// Inverts scroll direction so the content tracks the fingers. Defaults
    /// off, which preserves the direction the app has always used.
    @Published var naturalScrolling: Bool {
        didSet { defaults.set(naturalScrolling, forKey: Key.naturalScrolling) }
    }

    // ── Live mirror ─────────────────────────────────────────────────
    @Published var mirrorFrameRate: MirrorFrameRate {
        didSet { defaults.set(mirrorFrameRate.rawValue, forKey: Key.mirrorFrameRate) }
    }

    @Published var mirrorSharpness: MirrorSharpness {
        didSet { defaults.set(mirrorSharpness.rawValue, forKey: Key.mirrorSharpness) }
    }

    @Published var rememberMirrorLayout: Bool {
        didSet {
            defaults.set(rememberMirrorLayout, forKey: Key.rememberMirrorLayout)
            if !rememberMirrorLayout { mirrorLayout = nil }
        }
    }

    @Published var mirrorLayout: MirrorLayout? {
        didSet {
            if let mirrorLayout, let data = try? JSONEncoder().encode(mirrorLayout) {
                defaults.set(data, forKey: Key.mirrorLayout)
            } else {
                defaults.removeObject(forKey: Key.mirrorLayout)
            }
        }
    }

    // ── Screenshots ─────────────────────────────────────────────────
    @Published var screenshotQuality: CaptureQuality {
        didSet { defaults.set(screenshotQuality.rawValue, forKey: Key.screenshotQuality) }
    }

    @Published var defaultCapture: DefaultCapture {
        didSet { defaults.set(defaultCapture.rawValue, forKey: Key.defaultCapture) }
    }

    @Published var autoSaveToPhotos: Bool {
        didSet { defaults.set(autoSaveToPhotos, forKey: Key.autoSaveToPhotos) }
    }

    // ── Appearance ──────────────────────────────────────────────────
    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    // ── First run ───────────────────────────────────────────────────
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedSensitivity = defaults.object(forKey: Key.pointerSensitivity) as? Float
        pointerSensitivity = storedSensitivity ?? TrackpadSensitivity.defaultValue

        inputSendRate = InputSendRate(rawValue: defaults.integer(forKey: Key.inputSendRate))
            ?? .proMotion
        hapticStrength = (defaults.string(forKey: Key.hapticStrength)
            .flatMap(HapticStrength.init(rawValue:))) ?? .full
        naturalScrolling = defaults.bool(forKey: Key.naturalScrolling)

        mirrorFrameRate = MirrorFrameRate(rawValue: defaults.integer(forKey: Key.mirrorFrameRate))
            ?? .standard
        mirrorSharpness = (defaults.string(forKey: Key.mirrorSharpness)
            .flatMap(MirrorSharpness.init(rawValue:))) ?? .auto
        // Defaults to on: the mirror is pinchable to nearly full screen now,
        // and redoing that every session is the friction this removes.
        rememberMirrorLayout = defaults.object(forKey: Key.rememberMirrorLayout) as? Bool ?? true
        mirrorLayout = defaults.data(forKey: Key.mirrorLayout)
            .flatMap { try? JSONDecoder().decode(MirrorLayout.self, from: $0) }

        screenshotQuality = (defaults.string(forKey: Key.screenshotQuality)
            .flatMap(CaptureQuality.init(rawValue:))) ?? .standard
        defaultCapture = (defaults.string(forKey: Key.defaultCapture)
            .flatMap(DefaultCapture.init(rawValue:))) ?? .fullScreen
        autoSaveToPhotos = defaults.bool(forKey: Key.autoSaveToPhotos)

        appearance = (defaults.string(forKey: Key.appearance)
            .flatMap(AppearanceMode.init(rawValue:))) ?? .system

        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)

        GestureHaptic.strength = hapticStrength
    }

    /// Stream width to ask the host for, given the width the mirror's current
    /// on-screen size implies.
    func mirrorStreamWidth(naturalWidth: Int) -> Int {
        mirrorSharpness.resolve(naturalWidth: naturalWidth)
    }

    // MARK: - Hidden apps

    /// Bundle IDs hidden from the Apps grid. Owned by `StreamDeckGridView`
    /// via `@AppStorage`; read here under the same key and format so hiding
    /// isn't a one-way door — the grid offers no way back.
    var hiddenAppBundleIDs: Set<String> {
        guard let data = defaults.data(forKey: Key.hiddenApps),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return decoded
    }

    func unhideAllApps() {
        defaults.set(try? JSONEncoder().encode(Set<String>()), forKey: Key.hiddenApps)
        objectWillChange.send()
    }
}
