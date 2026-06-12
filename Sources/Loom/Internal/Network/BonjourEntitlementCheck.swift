//
//  BonjourEntitlementCheck.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/17/26.
//

import Foundation

/// Validates that the host app's Info.plist contains the required keys for
/// Bonjour discovery and advertising to work. Fires `assertionFailure` in
/// debug builds so developers see a clear message instead of the opaque
/// NWBrowser `-65555 (NoAuth)` error.
///
/// Skips the assertion when running inside a test runner (XCTest or Swift Testing)
/// to avoid crashing the test process for tests that exercise Bonjour codepaths.
func validateBonjourInfoPlistKeys(serviceType: String) {
    // Non-bundled executables (CLI tools, daemons) have no Info.plist and
    // macOS doesn't require these keys for them — only bundled apps do.
    guard Bundle.main.bundleIdentifier != nil else { return }

    // Production-safe path (WID-333): log structured findings through the
    // package logger in every build configuration, so a misconfigured
    // release build explains itself in Console.app instead of failing with
    // an opaque -65555. The DEBUG assertions below stay for loud,
    // can't-miss feedback during development.
    if !isRunningInTestContext {
        LoomLocalNetworkDiagnostics.reportIfMisconfigured(serviceType: serviceType)
    }

    #if DEBUG
    guard !isRunningInTestContext else { return }

    let info = Bundle.main.infoDictionary

    if let services = info?["NSBonjourServices"] as? [String] {
        if !services.contains(serviceType) {
            assertionFailure(
                """
                Loom: Your app's Info.plist declares NSBonjourServices but does \
                not include "\(serviceType)". Add it to the array so the system \
                authorizes Bonjour operations for this service type.

                <key>NSBonjourServices</key>
                <array>
                    <string>\(serviceType)</string>
                </array>
                """
            )
        }
    } else {
        assertionFailure(
            """
            Loom: Your app's Info.plist is missing NSBonjourServices. Without \
            this key the system denies Bonjour discovery and advertising with \
            error -65555 (NoAuth).

            Add the following to your Info.plist:

            <key>NSBonjourServices</key>
            <array>
                <string>\(serviceType)</string>
            </array>
            """
        )
    }

    if info?["NSLocalNetworkUsageDescription"] == nil {
        assertionFailure(
            """
            Loom: Your app's Info.plist is missing NSLocalNetworkUsageDescription. \
            Without this key the system cannot present the local network permission \
            prompt and Bonjour operations will fail with error -65555 (NoAuth).

            Add a user-facing description, for example:

            <key>NSLocalNetworkUsageDescription</key>
            <string>This app uses the local network to discover and connect to nearby devices.</string>
            """
        )
    }
    #endif
}

private let isRunningInTestContext: Bool = {
    NSClassFromString("XCTestCase") != nil
        || NSClassFromString("XCTest") != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.arguments.contains(where: { $0.contains("xctest") || $0.contains(".xctest") })
        || Bundle.main.bundlePath.hasSuffix(".xctest")
        || ProcessInfo.processInfo.processName == "xctest"
}()
