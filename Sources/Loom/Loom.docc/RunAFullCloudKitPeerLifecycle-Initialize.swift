import Loom
import LoomCloudKit

extension MyCloudPeerRuntime {
    func initialize() async throws {
        await cloudKitManager.initialize()
        guard cloudKitManager.isAvailable else { return }

        let identity = try LoomIdentityManager.shared.currentIdentity()
        await cloudKitManager.registerIdentity(
            keyID: identity.keyID,
            publicKey: identity.publicKey
        )

        await shareManager.setup()
    }
}
