import Loom

extension MyHostService {
    func start() async {
        do {
            let advertisement = try makeAdvertisement()
            let port = try await node.startAdvertising(
                serviceName: serviceName,
                advertisement: advertisement
            ) { [weak self] session in
                guard let self else { return }
                self.acceptIncomingSession(session)
            }
            state = .advertising(controlPort: port)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
