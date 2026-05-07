//
//  MirageLog.swift
//  MirageControl – Shared
//
//  Thin wrapper over Apple's unified `Logger` so MirageControl messages
//  flow into Console.app and the Xcode debug console under a stable
//  subsystem. We intentionally do NOT route through `LoomLogger` for app
//  messages: that path is category-gated by Loom's `LOOM_LOG` env var and
//  silently drops anything outside its default-enabled set, which makes
//  it the wrong tool for app-level startup / lifecycle traces.
//
//  Loom-internal messages still flow through `LoomLogger` independently,
//  under the `com.loom` subsystem (or whatever `LoomLogger.configure(...)`
//  was called with).
//

import Foundation
import os

enum MirageLog {
    static let subsystem: String = "com.miragecontrol"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let trust = Logger(subsystem: subsystem, category: "trust")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let context = Logger(subsystem: subsystem, category: "context")
    static let screenshot = Logger(subsystem: subsystem, category: "screenshot")
    static let appList = Logger(subsystem: subsystem, category: "applist")
}
