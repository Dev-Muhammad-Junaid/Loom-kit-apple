import Loom

extension MyClientService {
    func startBrowsing() {
        discovery.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            self.peers = peers.filter(Self.isCompatible(peer:))
        }

        discovery.startDiscovery()
        connectionState = .browsing
    }
}
