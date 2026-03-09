import Loom
import Network

extension MyClientService {
    func connect(to peer: LoomPeer) async {
        connectionState = .connecting(peerID: peer.id)

        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        let session = node.makeSession(connection: connection)

        session.setStateUpdateHandler { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.connectionState = .failed(error.localizedDescription)
            }
        }

        session.start(queue: .main)
        self.session = session
        connectionState = .connected(peerID: peer.id)

        Task {
            await performClientHandshake(over: session, expectedPeer: peer)
        }
    }
}
