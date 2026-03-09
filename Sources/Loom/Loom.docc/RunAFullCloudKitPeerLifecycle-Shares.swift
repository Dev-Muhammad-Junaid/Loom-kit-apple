import CloudKit
import LoomCloudKit

func createAndAcceptShares(
    shareManager: LoomCloudKitShareManager,
    cloudKitManager: LoomCloudKitManager,
    metadata: CKShare.Metadata
) async throws {
    let share = try await shareManager.createShare()
    print("Created share:", share.recordID.recordName)

    try await shareManager.acceptShare(metadata)
    await cloudKitManager.refreshShareParticipants()
}
