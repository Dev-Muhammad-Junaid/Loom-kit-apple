import Loom

func connectToPeer(_ peer: LoomPeer) async {
    do {
        try await attemptConnection(to: peer)
    } catch {
        LoomDiagnostics.report(
            error: error,
            category: .transport,
            message: "Failed to connect to \(peer.name)"
        )
    }
}

func performBootstrapRequest() async throws {
    try await LoomDiagnostics.run(category: .bootstrap, message: "Bootstrap control request failed") {
        try await controlClient.requestStatus(
            endpoint: endpoint,
            controlPort: controlPort,
            controlAuthSecret: secret,
            timeout: .seconds(3)
        )
    }
}
