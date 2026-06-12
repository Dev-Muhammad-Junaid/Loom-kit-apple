//
//  LoomLocalNetworkDiagnosticsTests.swift
//  LoomTests
//
//  WID-333: production-safe local-network configuration diagnostics.
//

import XCTest
@testable import Loom

final class LoomLocalNetworkDiagnosticsTests: XCTestCase {

    private let serviceType = "_loomtest._tcp"

    func testFullyConfiguredBundleYieldsNoFindings() {
        let info: [String: Any] = [
            "NSBonjourServices": ["_loomtest._tcp", "_other._udp"],
            "NSLocalNetworkUsageDescription": "Finds nearby devices.",
        ]
        XCTAssertTrue(
            LoomLocalNetworkDiagnostics.evaluate(serviceType: serviceType, infoDictionary: info).isEmpty
        )
    }

    func testMissingEverythingYieldsBothFindings() {
        let findings = LoomLocalNetworkDiagnostics.evaluate(serviceType: serviceType, infoDictionary: [:])
        XCTAssertEqual(
            Set(findings.map(\.kind)),
            [.missingBonjourServicesKey, .missingUsageDescription]
        )
    }

    func testUndeclaredServiceTypeIsFlagged() {
        let info: [String: Any] = [
            "NSBonjourServices": ["_somethingelse._tcp"],
            "NSLocalNetworkUsageDescription": "x",
        ]
        let findings = LoomLocalNetworkDiagnostics.evaluate(serviceType: serviceType, infoDictionary: info)
        XCTAssertEqual(findings.map(\.kind), [.serviceTypeNotDeclared])
        XCTAssertTrue(findings[0].remediation.contains(serviceType))
    }

    func testNilInfoDictionaryYieldsFindings() {
        let findings = LoomLocalNetworkDiagnostics.evaluate(serviceType: serviceType, infoDictionary: nil)
        XCTAssertEqual(findings.count, 2)
    }

    func testNoAuthNSErrorIsClassifiedAsAuthorizationDenial() {
        let error = NSError(domain: "NWErrorDomain", code: -65555)
        XCTAssertTrue(LoomLocalNetworkDiagnostics.isAuthorizationDenial(error))
    }

    func testUnrelatedErrorIsNotClassified() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 54)
        XCTAssertFalse(LoomLocalNetworkDiagnostics.isAuthorizationDenial(error))
        XCTAssertNil(
            LoomLocalNetworkDiagnostics.guidance(for: error, serviceType: serviceType)
        )
    }

    func testGuidanceMentionsFindingsWhenMisconfigured() {
        // Bundle.main in a test runner won't declare our service type, so
        // guidance should fold the configuration findings in.
        let error = NSError(domain: "NWErrorDomain", code: -65555)
        let guidance = LoomLocalNetworkDiagnostics.guidance(for: error, serviceType: serviceType)
        XCTAssertNotNil(guidance)
        XCTAssertTrue(guidance!.contains("-65555"))
    }
}
