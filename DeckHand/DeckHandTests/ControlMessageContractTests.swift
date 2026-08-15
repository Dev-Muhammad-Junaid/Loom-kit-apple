//
//  ControlMessageContractTests.swift
//  DeckHandTests
//
//  Contract tests for the iOS ↔ Mac wire format (WID-400). The
//  `ControlMessage` envelope is the most fragile contract in the app —
//  both sides hand-roll Codable, so a key rename or a missed case breaks
//  the remote silently. These tests lock the format:
//
//    1. Round-trip stability: encode → decode → re-encode must produce
//       byte-identical canonical JSON for every case. This catches
//       asymmetric encode/decode key usage without requiring Equatable
//       on the envelope.
//    2. Back-compat decode rules: optional fields added after 1.0
//       (`phase` on mouseScroll, `mode` on requestScreenshot) must keep
//       their documented defaults when absent.
//    3. Hostile input: unknown `type` must throw, not crash or misroute.
//

import XCTest

final class ControlMessageContractTests: XCTestCase {

    /// Canonical encoder — sorted keys make encoded bytes comparable.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    /// One representative value per `ControlMessage` case. Update this
    /// list whenever a case is added — `testAllCasesCovered` pins the
    /// expected count so a new case can't ship untested.
    private var allMessages: [ControlMessage] {
        [
            .mouseDelta(dx: 1.5, dy: -2.25),
            .mouseScroll(dx: 0.5, dy: 12, phase: .begin),
            .mouseScroll(dx: 0, dy: 0, phase: .momentumEnd),
            .mouseClick(button: .left),
            .mouseDoubleClick(button: .right),
            .keyboardShortcut(keys: ["cmd", "shift", "p"]),
            .launchApp(bundleID: "com.apple.Safari"),
            .macroButton(id: "locate_cursor"),
            .authorizationStatus(status: "granted"),
            .requestScreenshot(requestID: "req-1", mode: .fullScreen),
            .requestScreenshot(requestID: "req-2", mode: .region(x: 0.1, y: 0.2, width: 0.5, height: 0.25)),
            .requestScreenshot(requestID: "req-3", mode: .window(windowID: 4242)),
            .mediaCommand(action: "playpause"),
            .screenshotData(requestID: "req-1", data: Data([0xFF, 0xD8, 0xFF])),
            .screenshotError(requestID: "req-1", message: "TCC denied"),
            .activeAppUpdate(name: "Safari", bundleID: "com.apple.Safari"),
            .activeAppUpdate(name: "Mystery", bundleID: nil),
            .requestWindowList(requestID: "wl-1"),
            .windowListResponse(requestID: "wl-1", windows: [
                WindowInfo(windowID: 7, title: "Inbox", appName: "Mail",
                           bundleID: "com.apple.mail", appIconData: nil),
                WindowInfo(windowID: 9, title: "", appName: "Ghost",
                           bundleID: nil, appIconData: Data([0x01])),
            ]),
            .requestAppList,
            .appListResponse(apps: [
                InstalledAppInfo(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", iconData: nil),
            ]),
            .appShortcut(bundleID: "com.todesktop.230313mzl4w4u92", keys: ["cmd", "k"]),
            .requestAppMenuShortcuts(bundleID: "com.apple.Safari"),
            .appMenuShortcutsResponse(bundleID: "com.apple.Safari", shortcuts: [
                AppShortcutBinding(id: "imported.com.apple.Safari.File>New Tab",
                                   bundleID: "com.apple.Safari",
                                   displayName: "File › New Tab",
                                   keys: ["cmd", "t"],
                                   sfSymbol: "plus.square.on.square",
                                   isCurated: false,
                                   category: "File"),
            ]),
            .runningAppsUpdate(bundleIDs: ["com.apple.Safari", "com.apple.mail"]),
            .uiContextUpdate(snapshot: .none),
            .uiContextUpdate(snapshot: .dialog(DialogContext(
                revision: "00deadbeef00cafe",
                title: "Unsaved Changes",
                message: "Do you want to save?",
                buttons: [
                    DialogButton(id: "00deadbeef00cafe|0|Don't Save", title: "Don't Save", isDefault: false, isCancel: false),
                    DialogButton(id: "00deadbeef00cafe|1|Cancel", title: "Cancel", isDefault: false, isCancel: true),
                    DialogButton(id: "00deadbeef00cafe|2|Save", title: "Save", isDefault: true, isCancel: false),
                ]
            ))),
            .uiContextUpdate(snapshot: .textField(TextFieldContext(kind: .numeric))),
            .triggerContextAction(id: "00deadbeef00cafe|2|Save"),
            .startMirror(fps: 20, maxWidth: 480),
            .stopMirror,
            .mirrorFrame(seq: 42, data: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            .requestAuthorizationStatus,
            .ping(seq: 7),
            .pong(seq: 7),
            .hostCapabilities(accessibility: true, screenRecording: false),
        ]
    }

    // MARK: - 1. Round-trip stability

    func testRoundTripIsCanonicallyStable() throws {
        for (index, message) in allMessages.enumerated() {
            let first = try encoder.encode(message)
            let decoded = try decoder.decode(ControlMessage.self, from: first)
            let second = try encoder.encode(decoded)
            XCTAssertEqual(
                first, second,
                "Case #\(index) lost information in round-trip. " +
                "First: \(String(data: first, encoding: .utf8) ?? "?") " +
                "Second: \(String(data: second, encoding: .utf8) ?? "?")"
            )
        }
    }

    /// Pins the number of `MessageType` cases. If you add a case to
    /// `ControlMessage`, add a fixture above and bump this count —
    /// otherwise the new case ships with zero coverage.
    func testAllCasesCovered() throws {
        let types = Set(try allMessages.map { message -> String in
            let data = try encoder.encode(message)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(obj["type"] as? String)
        })
        XCTAssertEqual(types.count, 30, "Expected fixtures for all 30 message types, got \(types.sorted())")
    }

    // MARK: - 2. Back-compat decode rules

    func testMouseScrollWithoutPhaseDefaultsToChanged() throws {
        let legacy = Data(#"{"type":"mouseScroll","dx":1,"dy":2}"#.utf8)
        let decoded = try decoder.decode(ControlMessage.self, from: legacy)
        guard case let .mouseScroll(dx, dy, phase) = decoded else {
            return XCTFail("Decoded wrong case: \(decoded)")
        }
        XCTAssertEqual(dx, 1)
        XCTAssertEqual(dy, 2)
        XCTAssertEqual(phase, .changed, "Legacy unphased scroll must default to .changed")
    }

    func testRequestScreenshotWithoutModeDefaultsToFullScreen() throws {
        let legacy = Data(#"{"type":"requestScreenshot","requestID":"abc"}"#.utf8)
        let decoded = try decoder.decode(ControlMessage.self, from: legacy)
        guard case let .requestScreenshot(requestID, mode) = decoded else {
            return XCTFail("Decoded wrong case: \(decoded)")
        }
        XCTAssertEqual(requestID, "abc")
        XCTAssertEqual(mode, .fullScreen, "Legacy requests without mode must default to .fullScreen")
    }

    func testActiveAppUpdateWithNilBundleIDOmitsKey() throws {
        let data = try encoder.encode(ControlMessage.activeAppUpdate(name: "X", bundleID: nil))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(obj["bundleID"], "nil bundleID must be omitted (encodeIfPresent), not encoded as null")
    }

    // MARK: - 3. Hostile / malformed input

    func testUnknownTypeThrows() {
        let unknown = Data(#"{"type":"selfDestruct","id":"now"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(ControlMessage.self, from: unknown))
    }

    func testMissingRequiredFieldThrows() {
        let missing = Data(#"{"type":"mouseDelta","dx":1}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(ControlMessage.self, from: missing))
    }

    func testEmptyPayloadThrows() {
        XCTAssertThrowsError(try decoder.decode(ControlMessage.self, from: Data("{}".utf8)))
    }
}

// MARK: - UIContextSnapshot-specific contract

final class UIContextSnapshotContractTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    /// Equality must be structural: two snapshots built from the same
    /// dialog content are equal, which is exactly what powers the Mac's
    /// rebroadcast dedupe (WID-395).
    func testStructurallyEqualDialogsCompareEqual() {
        func make() -> UIContextSnapshot {
            .dialog(DialogContext(
                revision: "abc123",
                title: "T",
                message: "M",
                buttons: [DialogButton(id: "abc123|0|OK", title: "OK", isDefault: true, isCancel: false)]
            ))
        }
        XCTAssertEqual(make(), make())
    }

    func testDifferentRevisionBreaksEquality() {
        let a = UIContextSnapshot.dialog(DialogContext(revision: "r1", title: nil, message: nil, buttons: []))
        let b = UIContextSnapshot.dialog(DialogContext(revision: "r2", title: nil, message: nil, buttons: []))
        XCTAssertNotEqual(a, b)
    }

    func testTextFieldKindsRoundTrip() throws {
        for kind in [TextFieldContext.Kind.text, .numeric, .secure] {
            let snapshot = UIContextSnapshot.textField(TextFieldContext(kind: kind))
            let data = try encoder.encode(snapshot)
            let decoded = try decoder.decode(UIContextSnapshot.self, from: data)
            XCTAssertEqual(decoded, snapshot)
        }
    }

    func testDialogRoundTripPreservesButtonOrder() throws {
        let buttons = (0..<5).map {
            DialogButton(id: "rev|\($0)|B\($0)", title: "B\($0)", isDefault: $0 == 4, isCancel: $0 == 0)
        }
        let snapshot = UIContextSnapshot.dialog(
            DialogContext(revision: "rev", title: "Order", message: nil, buttons: buttons)
        )
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(UIContextSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot, "Button order is part of the contract — iPad renders in array order")
    }
}
