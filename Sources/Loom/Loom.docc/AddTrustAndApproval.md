# Add Trust and Approval

Loom gives you the trust boundary, but your app still decides the policy.

The core rule is straightforward:

1. authenticate the peer identity in your handshake
2. build a ``LoomPeerIdentity``
3. ask a ``LoomTrustProvider`` what to do
4. fall back to product-owned approval UX if needed

`MirageKit` follows exactly that shape. Its host verifies the connecting peer's key identifier, signature, and replay window before it asks the trust provider for a decision.

## Authenticate before you evaluate trust

Do not feed unverified identity data into your trust provider.

The provider should receive a `LoomPeerIdentity` that already reflects whether the peer identity was authenticated. `MirageKit` constructs that value only after its hello message has passed signature and replay checks.

```swift
let peerIdentity = LoomPeerIdentity(
    deviceID: deviceInfo.id,
    name: deviceInfo.name,
    deviceType: deviceInfo.deviceType,
    iCloudUserID: deviceInfo.iCloudUserID,
    identityKeyID: deviceInfo.identityKeyID,
    identityPublicKey: deviceInfo.identityPublicKey,
    isIdentityAuthenticated: deviceInfo.isIdentityAuthenticated,
    endpoint: deviceInfo.endpoint
)
```

That keeps policy code honest. If the handshake is not authenticated, the provider can immediately deny or require manual approval.

## Start with a local trust store

``LoomTrustStore`` is the simplest persistence layer for "always trust this device" behavior.

```swift
import Loom

@MainActor
final class MyTrustProvider: LoomTrustProvider {
    private let trustStore: LoomTrustStore
    private let currentUserID: String?

    init(trustStore: LoomTrustStore, currentUserID: String?) {
        self.trustStore = trustStore
        self.currentUserID = currentUserID
    }

    func evaluateTrust(for peer: LoomPeerIdentity) async -> LoomTrustDecision {
        guard peer.isIdentityAuthenticated else { return .denied }
        if trustStore.isTrusted(deviceID: peer.deviceID) { return .trusted }
        if let currentUserID, peer.iCloudUserID == currentUserID { return .trusted }
        return .requiresApproval
    }

    func grantTrust(to peer: LoomPeerIdentity) async throws {
        trustStore.addTrustedDevice(
            LoomTrustedDevice(
                id: peer.deviceID,
                name: peer.name,
                deviceType: peer.deviceType,
                trustedAt: Date()
            )
        )
    }

    func revokeTrust(for deviceID: UUID) async throws {
        guard let device = trustStore.trustedDevices.first(where: { $0.id == deviceID }) else { return }
        trustStore.revokeTrust(for: device)
    }
}
```

That layered approach is already enough for many apps:

- deny unauthenticated peers
- auto-trust known devices
- require approval for everything else

## Separate trust policy from approval UX

``LoomTrustDecision`` gives you the policy result. Your app still decides how to present it.

`MirageKit` makes this explicit:

- `.trusted` auto-accepts the connection
- `.denied` rejects the connection
- `.requiresApproval` or `.unavailable` falls back to app-owned approval UI

That is a good pattern because it keeps the provider small and testable while leaving your product free to implement blocking prompts, banners, or out-of-band approval flows.

## Use `evaluateTrustOutcome` when caller UX matters

``LoomTrustProvider/evaluateTrustOutcome(for:)`` lets a provider distinguish between different kinds of auto-trust.

For example:

- same-account iCloud auto-trust may want a one-time notice
- locally persisted manual trust usually should not

That is why ``LoomTrustEvaluation`` carries both the decision and the `shouldShowAutoTrustNotice` flag.

## If you need CloudKit-backed trust

Use `LoomCloudKitTrustProvider` when you want:

- same-account auto-trust
- friend/share-participant auto-trust
- local trusted-device fallback

It still expects authenticated identities and still works best when your product owns the approval UX for the unresolved cases.

For the broader CloudKit integration pattern, continue with <doc:SharePeersWithCloudKit>.
