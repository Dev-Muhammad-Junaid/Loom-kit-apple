import Foundation
import Loom

enum HandshakeError: Error {
    case invalidKeyID
    case invalidSignature
    case replayRejected
}

actor HostHandshakeValidator {
    private let replayProtector = LoomReplayProtector()

    func validate(_ hello: HelloEnvelope) async throws -> LoomPeerIdentity {
        let derivedKeyID = LoomIdentityManager.keyID(for: hello.identity.publicKey)
        guard derivedKeyID == hello.identity.keyID else {
            throw HandshakeError.invalidKeyID
        }

        let payload = CanonicalHelloPayload(
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            deviceType: hello.deviceType,
            protocolVersion: hello.protocolVersion,
            advertisement: hello.advertisement,
            supportedFeatures: hello.supportedFeatures,
            iCloudUserID: hello.iCloudUserID,
            keyID: hello.identity.keyID,
            publicKey: hello.identity.publicKey,
            timestampMs: hello.identity.timestampMs,
            nonce: hello.identity.nonce
        )

        let payloadData = try makeCanonicalHelloPayload(from: payload)
        guard LoomIdentityManager.verify(
            signature: hello.identity.signature,
            payload: payloadData,
            publicKey: hello.identity.publicKey
        ) else {
            throw HandshakeError.invalidSignature
        }

        let replayAccepted = await replayProtector.validate(
            timestampMs: hello.identity.timestampMs,
            nonce: hello.identity.nonce
        )
        guard replayAccepted else {
            throw HandshakeError.replayRejected
        }

        return LoomPeerIdentity(
            deviceID: hello.deviceID,
            name: hello.deviceName,
            deviceType: hello.deviceType,
            iCloudUserID: hello.iCloudUserID,
            identityKeyID: hello.identity.keyID,
            identityPublicKey: hello.identity.publicKey,
            isIdentityAuthenticated: true,
            endpoint: "session-endpoint"
        )
    }
}
