import Loom

func snapshotDiagnosticsContext() async {
    let snapshot = await LoomDiagnostics.snapshotContext()
    print(snapshot)
}
