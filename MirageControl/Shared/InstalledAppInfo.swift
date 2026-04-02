//
//  InstalledAppInfo.swift
//  MirageControl – Shared
//

import Foundation

/// Lightweight descriptor of a macOS application, sent from the Mac host
/// to the iPad so it can render a dynamic app launcher with real icons.
public struct InstalledAppInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let displayName: String
    /// 64×64 JPEG icon data (~2-5 KB per app). `nil` if the icon couldn't be read.
    public let iconData: Data?

    public init(bundleID: String, displayName: String, iconData: Data?) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.iconData = iconData
    }
}
