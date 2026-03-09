import Loom

@MainActor
final class MyClientServiceWithDiagnostics {
    private var diagnosticsContextToken: LoomDiagnosticsContextProviderToken?
    private(set) var availablePeerCount = 0
    private(set) var isAwaitingApproval = false
    private(set) var connectionState = "disconnected"

    func startDiagnosticsContext() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextToken = await LoomDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run {
                    [
                        "client.connectionState": .string(self.connectionState),
                        "client.availablePeerCount": .int(self.availablePeerCount),
                        "client.awaitingApproval": .bool(self.isAwaitingApproval),
                    ]
                }
            }
        }
    }
}
