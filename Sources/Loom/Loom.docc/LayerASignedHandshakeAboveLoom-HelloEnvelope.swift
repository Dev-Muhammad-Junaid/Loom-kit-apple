import Foundation
import Loom

struct HelloEnvelope: Codable {
    struct Identity: Codable {
        let keyID: String
        let publicKey: Data
        let timestampMs: Int64
        let nonce: String
        let signature: Data
    }

    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
    let protocolVersion: Int
    let advertisement: LoomPeerAdvertisement
    let supportedFeatures: [String]
    let iCloudUserID: String?
    let identity: Identity
}

struct CanonicalHelloPayload: Codable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
    let protocolVersion: Int
    let advertisement: LoomPeerAdvertisement
    let supportedFeatures: [String]
    let iCloudUserID: String?
    let keyID: String
    let publicKey: Data
    let timestampMs: Int64
    let nonce: String
}

func makeCanonicalHelloPayload(
    from hello: CanonicalHelloPayload
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(hello)
}
