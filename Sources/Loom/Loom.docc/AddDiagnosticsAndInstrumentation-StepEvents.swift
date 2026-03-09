import Loom

enum RuntimeSteps {
    static let discoveryStarted: LoomStepEvent = "myapp.discovery.started"
    static let connectionRequested: LoomStepEvent = "myapp.connection.requested"
    static let handshakeVerified: LoomStepEvent = "myapp.handshake.verified"
}

func recordRuntimeSteps() {
    LoomInstrumentation.record(RuntimeSteps.discoveryStarted)
    LoomInstrumentation.record(RuntimeSteps.connectionRequested)
    LoomInstrumentation.record(RuntimeSteps.handshakeVerified)
}
