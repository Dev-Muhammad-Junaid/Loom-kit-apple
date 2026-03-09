import Loom

@MainActor
final class MyRuntimeObservability {
    private var diagnosticsToken: LoomDiagnosticsSinkToken?
    private var instrumentationToken: LoomInstrumentationSinkToken?

    func start() async {
        diagnosticsToken = await LoomDiagnostics.addSink(DiagnosticsRecorder())
        instrumentationToken = await LoomInstrumentation.addSink(StepRecorder())
    }

    func stop() async {
        if let diagnosticsToken {
            await LoomDiagnostics.removeSink(diagnosticsToken)
        }
        if let instrumentationToken {
            await LoomInstrumentation.removeSink(instrumentationToken)
        }
    }
}
