import Loom

extension MyHostService {
    private func acceptIncomingSession(_ session: LoomSession) {
        session.setStateUpdateHandler { state in
            print("Host session state:", state)
        }

        session.start(queue: .main)

        Task {
            await runHandshakeAndSessionLoop(for: session)
        }
    }
}
