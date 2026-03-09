@testable import Loom
import Foundation
import Testing

@MainActor
@Test("Locally trusted devices auto-approve")
func trustedDevicesAutoApprove() async throws {
    let store = LoomTrustStore(storageKey: "tests.trust.store")
    let deviceID = UUID()
    store.addTrustedDevice(
        LoomTrustedDevice(
            id: deviceID,
            name: "Known Mac",
            deviceType: .mac,
            trustedAt: Date()
        )
    )

    let provider = MyTrustProvider(trustStore: store, currentUserID: nil)
    let peer = LoomPeerIdentity(
        deviceID: deviceID,
        name: "Known Mac",
        deviceType: .mac,
        iCloudUserID: nil,
        identityKeyID: "key-1",
        identityPublicKey: Data(),
        isIdentityAuthenticated: true,
        endpoint: "127.0.0.1"
    )

    let decision = await provider.evaluateTrust(for: peer)
    #expect(decision == .trusted)
}
