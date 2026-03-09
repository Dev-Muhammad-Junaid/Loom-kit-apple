import Loom

extension MyHostService {
    func refreshAdvertisement() async throws {
        let advertisement = try makeAdvertisement()
        await node.updateAdvertisement(advertisement)
    }
}
