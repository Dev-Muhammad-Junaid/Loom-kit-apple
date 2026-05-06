//
//  CaptureMode.swift
//  MirageControl – Shared
//
//  What the iPad is asking the Mac to capture. The default-tap path stays
//  on `.fullScreen`; `.region` and `.window` flow from the long-press /
//  caret menu the user added to the screenshot button.
//

import Foundation

/// Describes the slice of the Mac screen the iPad wants captured.
public enum CaptureMode: Codable, Hashable, Sendable {
    /// Full primary display.
    case fullScreen

    /// Cropped region in normalized 0…1 coordinates relative to the
    /// primary display, origin top-left. The Mac re-captures fresh pixels
    /// and crops on its side rather than reusing a stale full screenshot
    /// the iPad happens to have on screen.
    case region(x: Float, y: Float, width: Float, height: Float)

    /// Single window identified by its `CGWindowID`. The iPad obtains the
    /// ID from `windowListResponse`; stale IDs (window closed since the
    /// list was fetched) surface as `screenshotError`.
    case window(windowID: UInt32)

    private enum CodingKeys: String, CodingKey {
        case kind, x, y, width, height, windowID
    }

    private enum Kind: String, Codable {
        case fullScreen, region, window
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .fullScreen:
            self = .fullScreen
        case .region:
            self = .region(
                x: try c.decode(Float.self, forKey: .x),
                y: try c.decode(Float.self, forKey: .y),
                width: try c.decode(Float.self, forKey: .width),
                height: try c.decode(Float.self, forKey: .height)
            )
        case .window:
            self = .window(windowID: try c.decode(UInt32.self, forKey: .windowID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullScreen:
            try c.encode(Kind.fullScreen, forKey: .kind)
        case let .region(x, y, width, height):
            try c.encode(Kind.region, forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
        case let .window(windowID):
            try c.encode(Kind.window, forKey: .kind)
            try c.encode(windowID, forKey: .windowID)
        }
    }
}

/// Lightweight window descriptor for the iPad's window-capture picker.
public struct WindowInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: UInt32 { windowID }
    /// Native `CGWindowID`. Stable for the lifetime of the window.
    public let windowID: UInt32
    public let title: String
    public let appName: String
    public let bundleID: String?
    /// 48×48 JPEG icon of the owning app. Skipped when we can't read the
    /// app bundle (e.g. system-owned windows).
    public let appIconData: Data?

    public init(
        windowID: UInt32,
        title: String,
        appName: String,
        bundleID: String?,
        appIconData: Data?
    ) {
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.bundleID = bundleID
        self.appIconData = appIconData
    }
}
