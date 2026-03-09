import Loom
import LoomCloudKit

@MainActor
final class MyCloudPeerRuntime {
    let configuration = LoomCloudKitConfiguration(
        containerIdentifier: "iCloud.com.example.myapp",
        deviceRecordType: "MyAppDevice",
        peerRecordType: "MyAppPeer",
        peerZoneName: "MyAppPeerZone",
        participantIdentityRecordType: "MyAppParticipantIdentity",
        shareTitle: "MyApp Device Access",
        deviceIDKey: "com.example.myapp.deviceID"
    )

    lazy var cloudKitManager = LoomCloudKitManager(configuration: configuration)
    lazy var shareManager = LoomCloudKitShareManager(cloudKitManager: cloudKitManager)
    lazy var peerProvider = LoomCloudKitPeerProvider(cloudKitManager: cloudKitManager)
}
