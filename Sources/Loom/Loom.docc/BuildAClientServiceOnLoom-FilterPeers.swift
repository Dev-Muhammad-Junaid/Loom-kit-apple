import Loom

extension MyClientService {
    private static func isCompatible(peer: LoomPeer) -> Bool {
        let metadata = peer.advertisement.metadata
        return metadata["myapp.protocol"] == "1"
            && metadata["myapp.role"] == "host"
            && peer.advertisement.identityKeyID != nil
    }
}
