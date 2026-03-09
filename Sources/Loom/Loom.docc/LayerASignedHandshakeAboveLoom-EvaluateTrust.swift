import Loom

@MainActor
func evaluateHandshakeTrust(
    peerIdentity: LoomPeerIdentity,
    trustProvider: (any LoomTrustProvider)?
) async -> LoomTrustDecision {
    guard let trustProvider else { return .requiresApproval }
    return await trustProvider.evaluateTrust(for: peerIdentity)
}
