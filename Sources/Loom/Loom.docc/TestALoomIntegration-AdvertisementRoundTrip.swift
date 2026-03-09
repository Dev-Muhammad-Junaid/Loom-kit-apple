@testable import Loom
import Testing

@Suite("Peer Advertisement")
struct PeerAdvertisementTests {
    @Test("TXT record round-trip preserves product metadata")
    func txtRoundTripPreservesMetadata() {
        let original = LoomPeerAdvertisement(
            deviceID: UUID(),
            identityKeyID: "abc123",
            deviceType: .mac,
            metadata: [
                "myapp.protocol": "1",
                "myapp.role": "host",
            ]
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: original.toTXTRecord())

        #expect(decoded.deviceID == original.deviceID)
        #expect(decoded.identityKeyID == original.identityKeyID)
        #expect(decoded.metadata["myapp.protocol"] == "1")
        #expect(decoded.metadata["myapp.role"] == "host")
    }
}
