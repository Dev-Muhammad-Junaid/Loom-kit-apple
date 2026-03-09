import Foundation
import Loom

@MainActor
func makeSignedHello(
    deviceID: UUID,
    deviceName: String,
    deviceType: DeviceType,
    advertisement: LoomPeerAdvertisement,
    supportedFeatures: [String],
    iCloudUserID: String?
) throws -> HelloEnvelope {
    let identity = try LoomIdentityManager.shared.currentIdentity()
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    let nonce = UUID().uuidString.lowercased()

    let payload = CanonicalHelloPayload(
        deviceID: deviceID,
        deviceName: deviceName,
        deviceType: deviceType,
        protocolVersion: Int(Loom.protocolVersion),
        advertisement: advertisement,
        supportedFeatures: supportedFeatures,
        iCloudUserID: iCloudUserID,
        keyID: identity.keyID,
        publicKey: identity.publicKey,
        timestampMs: timestampMs,
        nonce: nonce
    )

    let payloadData = try makeCanonicalHelloPayload(from: payload)
    let signature = try LoomIdentityManager.shared.sign(payloadData)

    return HelloEnvelope(
        deviceID: deviceID,
        deviceName: deviceName,
        deviceType: deviceType,
        protocolVersion: Int(Loom.protocolVersion),
        advertisement: advertisement,
        supportedFeatures: supportedFeatures,
        iCloudUserID: iCloudUserID,
        identity: .init(
            keyID: identity.keyID,
            publicKey: identity.publicKey,
            timestampMs: timestampMs,
            nonce: nonce,
            signature: signature
        )
    )
}
