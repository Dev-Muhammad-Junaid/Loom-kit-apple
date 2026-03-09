import Loom
import LoomCloudKit

extension MyCloudPeerRuntime {
    func publishPeer(
        deviceID: UUID,
        name: String,
        advertisement: LoomPeerAdvertisement,
        remoteAccessEnabled: Bool,
        bootstrapMetadata: LoomBootstrapMetadata?
    ) async throws {
        let identity = try LoomIdentityManager.shared.currentIdentity()

        try await shareManager.registerPeer(
            deviceID: deviceID,
            name: name,
            advertisement: advertisement,
            identityPublicKey: identity.publicKey,
            remoteAccessEnabled: remoteAccessEnabled,
            bootstrapMetadata: bootstrapMetadata
        )
    }
}
