@testable import Loom
import Foundation
import Testing

@Test("Replay protector rejects the same nonce twice")
func replayProtectorRejectsDuplicateNonce() async {
    let protector = LoomReplayProtector()
    let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

    let first = await protector.validate(timestampMs: timestamp, nonce: "nonce-1")
    let second = await protector.validate(timestampMs: timestamp, nonce: "nonce-1")

    #expect(first == true)
    #expect(second == false)
}
