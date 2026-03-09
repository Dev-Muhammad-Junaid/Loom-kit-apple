@testable import Loom
import Foundation
import Testing

@Suite("Runtime Observability", .serialized)
struct RuntimeObservabilityTests {
    @Test("Diagnostics fan out to all sinks")
    func diagnosticsFanOut() async {
        await LoomDiagnostics.removeAllSinks()

        let sinkOne = TestSink()
        let sinkTwo = TestSink()
        _ = await LoomDiagnostics.addSink(sinkOne)
        _ = await LoomDiagnostics.addSink(sinkTwo)

        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "fanout",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
    }
}

private actor TestSink: LoomDiagnosticsSink {
    private var logs: [LoomDiagnosticsLogEvent] = []

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }
}
