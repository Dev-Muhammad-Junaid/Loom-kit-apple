//
//  LoomLocalNetworkDiagnostics.swift
//  Loom
//
//  Production-safe local-network configuration diagnostics (WID-333).
//
//  The existing `validateBonjourInfoPlistKeys` check fires
//  `assertionFailure` in DEBUG builds only — in production a missing
//  `NSBonjourServices` entry or `NSLocalNetworkUsageDescription` key
//  surfaces as an opaque NWBrowser/NWListener `-65555 (NoAuth)` failure
//  with no hint about the cause. This type makes the same checks (plus
//  authorization-error classification) available at runtime in all build
//  configurations, as structured findings products can log, display, or
//  attach to bug reports.
//

import Foundation
import Network

public enum LoomLocalNetworkDiagnostics {

    // MARK: - Findings

    public struct Finding: Equatable, Sendable, CustomStringConvertible {
        public enum Kind: String, Sendable {
            case missingBonjourServicesKey
            case serviceTypeNotDeclared
            case missingUsageDescription
        }

        public let kind: Kind
        /// One-line, log-friendly statement of what's wrong.
        public let summary: String
        /// What the developer should change, including the exact plist keys.
        public let remediation: String

        public var description: String { "\(summary) — \(remediation)" }
    }

    // MARK: - Evaluation

    /// Inspects the bundle's Info.plist for the keys local-network Bonjour
    /// operation requires. Empty result means the statically-verifiable
    /// configuration is correct. (The iOS multicast entitlement cannot be
    /// introspected with public API; see `guidance(for:serviceType:)` which
    /// covers it when an authorization failure is actually observed.)
    public static func evaluate(serviceType: String, bundle: Bundle = .main) -> [Finding] {
        evaluate(serviceType: serviceType, infoDictionary: bundle.infoDictionary)
    }

    /// Testable core — same checks against an arbitrary Info dictionary.
    public static func evaluate(serviceType: String, infoDictionary: [String: Any]?) -> [Finding] {
        var findings: [Finding] = []

        if let services = infoDictionary?["NSBonjourServices"] as? [String] {
            if !services.contains(serviceType) {
                findings.append(Finding(
                    kind: .serviceTypeNotDeclared,
                    summary: "Info.plist declares NSBonjourServices but not \"\(serviceType)\" (declared: \(services.joined(separator: ", ")))",
                    remediation: "Add \"\(serviceType)\" to the NSBonjourServices array; without it the system denies Bonjour for this service type with -65555 (NoAuth)"
                ))
            }
        } else {
            findings.append(Finding(
                kind: .missingBonjourServicesKey,
                summary: "Info.plist is missing NSBonjourServices",
                remediation: "Add NSBonjourServices (array of String) including \"\(serviceType)\"; without it Bonjour discovery/advertising fails with -65555 (NoAuth)"
            ))
        }

        if infoDictionary?["NSLocalNetworkUsageDescription"] == nil {
            findings.append(Finding(
                kind: .missingUsageDescription,
                summary: "Info.plist is missing NSLocalNetworkUsageDescription",
                remediation: "Add NSLocalNetworkUsageDescription with user-facing copy; without it the local-network permission prompt can't be shown and Bonjour fails with -65555 (NoAuth)"
            ))
        }

        return findings
    }

    // MARK: - Authorization-error classification

    /// `true` when `error` is the local-network authorization denial
    /// (`kDNSServiceErr_NoAuth`, -65555) that misconfiguration or a
    /// user-denied permission prompt produces.
    public static func isAuthorizationDenial(_ error: Error) -> Bool {
        if let nwError = error as? NWError, case let .dns(code) = nwError {
            return code == Self.dnsServiceErrNoAuth
        }
        let nsError = error as NSError
        return Int32(exactly: nsError.code) == Self.dnsServiceErrNoAuth
            && (nsError.domain == "NWErrorDomain" || nsError.domain == "Network.NWError")
    }

    /// Human-actionable guidance for an observed failure. Combines the
    /// statically-verifiable findings with the cases we can't introspect
    /// (user denied the prompt; iOS multicast entitlement), so production
    /// logs always carry a concrete next step instead of a bare -65555.
    public static func guidance(for error: Error, serviceType: String, bundle: Bundle = .main) -> String? {
        guard isAuthorizationDenial(error) else { return nil }

        let findings = evaluate(serviceType: serviceType, bundle: bundle)
        if !findings.isEmpty {
            return "Local network authorization denied (-65555). Configuration problems found: "
                + findings.map(\.description).joined(separator: " | ")
        }
        return "Local network authorization denied (-65555) but Info.plist looks correct. "
            + "Likely causes: the user denied the Local Network permission prompt "
            + "(Settings > Privacy & Security > Local Network), or — on iOS when using "
            + "multicast/broadcast beyond Bonjour — the app lacks the "
            + "com.apple.developer.networking.multicast entitlement."
    }

    /// Logs every configuration finding through the Loom logger at error
    /// level (unconditional, so it appears in production logs/Console.app).
    /// Returns the findings so callers can also surface them in UI.
    @discardableResult
    public static func reportIfMisconfigured(serviceType: String, bundle: Bundle = .main) -> [Finding] {
        let findings = evaluate(serviceType: serviceType, bundle: bundle)
        for finding in findings {
            LoomLogger.error(.discovery, "Local network misconfiguration: \(finding.description)")
        }
        return findings
    }

    private static let dnsServiceErrNoAuth: Int32 = -65555
}
