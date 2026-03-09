import Loom

extension MyHostService {
    func stop() async {
        await node.stopAdvertising()
        state = .idle
    }
}
