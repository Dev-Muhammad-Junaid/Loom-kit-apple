import Loom
import LoomCloudKit

func makeCloudBackedNode(
    cloudKitManager: LoomCloudKitManager
) -> LoomNode {
    let trustProvider = LoomCloudKitTrustProvider(
        cloudKitManager: cloudKitManager,
        localTrustStore: LoomTrustStore()
    )

    return LoomNode(
        configuration: .default,
        identityManager: LoomIdentityManager.shared,
        trustProvider: trustProvider
    )
}
