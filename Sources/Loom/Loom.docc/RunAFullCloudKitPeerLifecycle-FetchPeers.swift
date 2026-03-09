import LoomCloudKit

extension MyCloudPeerRuntime {
    func refreshVisiblePeers() async {
        await peerProvider.fetchPeers()
        let peers = peerProvider.ownPeers + peerProvider.sharedPeers
        print("Visible peers:", peers.map(\.name))
    }
}
