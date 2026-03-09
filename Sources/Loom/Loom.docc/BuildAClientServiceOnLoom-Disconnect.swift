import Loom

extension MyClientService {
    func disconnect() {
        session?.cancel()
        session = nil
        connectionState = .disconnected
    }
}
