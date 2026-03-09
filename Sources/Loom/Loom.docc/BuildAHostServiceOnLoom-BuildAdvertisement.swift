import Loom

extension MyHostService {
    private func makeAdvertisement() throws -> LoomPeerAdvertisement {
        let identity = try LoomIdentityManager.shared.currentIdentity()

        return LoomPeerAdvertisement(
            deviceID: deviceID,
            identityKeyID: identity.keyID,
            deviceType: .mac,
            modelIdentifier: currentHardwareModelIdentifier(),
            metadata: [
                "myapp.protocol": "1",
                "myapp.role": "host",
                "myapp.max-streams": "4",
            ]
        )
    }
}
