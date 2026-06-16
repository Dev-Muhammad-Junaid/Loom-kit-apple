//
//  LoomStoreIncomingDedupTests.swift
//  LoomKit
//
//  Regression coverage for the "established-connection-wins" dedup of
//  incoming authenticated sessions.
//
//  A direct-connect dial races its transports (`racesLocalCandidates`) and a
//  churny peer can redial while its previous link is still working, so a
//  single working connection can be shadowed by additional incoming sessions.
//  Previously each new arrival called `replaceExistingConnection(for:)`, which
//  `disconnect()`s (goodbye-kills) the connection the peer was actually using
//  — producing an endless reconnect loop.
//
//  The fix keys dedup on session *liveness* rather than a fragile time window:
//  while an existing connection's session is still `.ready` the new arrival is
//  treated as a duplicate and dropped (its session cancelled), REGARDLESS of
//  how much time has passed. Only once the existing session is genuinely dead
//  does a new incoming session replace it (so a real reconnect still works).
//
//  These tests drive the real `LoomStore.acceptIncomingSession(_:)` path with
//  real loopback `LoomAuthenticatedSession` pairs. The only production change
//  required was relaxing `acceptIncomingSession` from `private` to `internal`
//  (a documented test seam); the runtime dedup logic is exercised unchanged.
//

@testable import Loom
@testable import LoomKit
import Foundation
import Network
import Testing

@Suite("LoomStore Incoming Dedup", .serialized)
struct LoomStoreIncomingDedupTests {

    @MainActor
    @Test("Duplicate incoming session from the same peer is dropped and the established connection is kept")
    func duplicateIncomingFromSamePeerIsDropped() async throws {
        let store = makeStore()
        let peerDeviceID = UUID()
        let clientIdentity = makeIdentityManager(label: "dedup-same-client")

        let first = try await makeStartedIncomingSession(
            peerDeviceID: peerDeviceID,
            clientIdentityManager: clientIdentity
        )
        defer { Task { await first.stop() } }

        await store.acceptIncomingSession(first.incoming)

        let afterFirst = await currentConnections(store)
        #expect(afterFirst.count == 1)
        let establishedConnectionID = try #require(afterFirst.first?.id)
        #expect(afterFirst.first?.peerID.deviceID == peerDeviceID)

        // Second, near-simultaneous incoming session from the SAME peer while
        // the first is still live and recently registered.
        let second = try await makeStartedIncomingSession(
            peerDeviceID: peerDeviceID,
            clientIdentityManager: clientIdentity
        )
        defer { Task { await second.stop() } }

        await store.acceptIncomingSession(second.incoming)

        let afterSecond = await currentConnections(store)
        // The established connection is retained (same id), the duplicate did
        // not replace it.
        #expect(afterSecond.count == 1)
        #expect(afterSecond.first?.id == establishedConnectionID)

        // The duplicate session was cancelled; the established session is
        // untouched (NOT disconnected).
        #expect(await second.incoming.state == .cancelled)
        #expect(await first.incoming.state == .ready)

        await store.stop()
    }

    @MainActor
    @Test("Incoming session from a different peer is accepted alongside an existing connection")
    func incomingFromDifferentPeerIsAccepted() async throws {
        let store = makeStore()

        let first = try await makeStartedIncomingSession(
            peerDeviceID: UUID(),
            clientIdentityManager: makeIdentityManager(label: "dedup-diff-a")
        )
        defer { Task { await first.stop() } }
        await store.acceptIncomingSession(first.incoming)
        #expect(await currentConnections(store).count == 1)

        // A different peer (different device id + identity) within the same
        // window must NOT be treated as a duplicate.
        let second = try await makeStartedIncomingSession(
            peerDeviceID: UUID(),
            clientIdentityManager: makeIdentityManager(label: "dedup-diff-b")
        )
        defer { Task { await second.stop() } }
        await store.acceptIncomingSession(second.incoming)

        let connections = await currentConnections(store)
        #expect(connections.count == 2)
        #expect(await first.incoming.state == .ready)
        #expect(await second.incoming.state == .ready)

        await store.stop()
    }

    @MainActor
    @Test("A live connection is kept and the duplicate dropped even well outside any 3s window (fragile-window regression)")
    func liveSamePeerConnectionOutsideWindowIsDropped() async throws {
        let store = makeStore()
        let peerDeviceID = UUID()
        let clientIdentity = makeIdentityManager(label: "dedup-live-window-client")

        let first = try await makeStartedIncomingSession(
            peerDeviceID: peerDeviceID,
            clientIdentityManager: clientIdentity
        )
        defer { Task { await first.stop() } }
        await store.acceptIncomingSession(first.incoming)

        let afterFirst = await currentConnections(store)
        #expect(afterFirst.count == 1)
        let establishedConnectionID = try #require(afterFirst.first?.id)

        // Wait WELL PAST the old fragile 3s window. Under the previous
        // time-window dedup this arrival would have been (wrongly) treated as a
        // reconnect and replaced the still-live link, kicking off the churn
        // loop. Liveness-based dedup must still drop it because the first
        // session is alive.
        try await Task.sleep(for: formerDuplicateWindow + .seconds(1))

        // Sanity: the first session is genuinely still live.
        #expect(await first.incoming.state == .ready)

        let second = try await makeStartedIncomingSession(
            peerDeviceID: peerDeviceID,
            clientIdentityManager: clientIdentity
        )
        defer { Task { await second.stop() } }
        await store.acceptIncomingSession(second.incoming)

        let afterSecond = await currentConnections(store)
        // The established connection is retained (same id); the duplicate did
        // not replace it.
        #expect(afterSecond.count == 1)
        #expect(afterSecond.first?.id == establishedConnectionID)

        // The duplicate was cancelled; the established session is untouched.
        #expect(await second.incoming.state == .cancelled)
        #expect(await first.incoming.state == .ready)

        await store.stop()
    }

    @MainActor
    @Test("A new incoming session replaces a genuinely-dead existing connection (legitimate reconnect)")
    func deadSamePeerConnectionIsReplaced() async throws {
        let store = makeStore()
        let peerDeviceID = UUID()
        let clientIdentity = makeIdentityManager(label: "dedup-reconnect-client")

        let first = try await makeStartedIncomingSession(
            peerDeviceID: peerDeviceID,
            clientIdentityManager: clientIdentity
        )
        defer { Task { await first.stop() } }
        await store.acceptIncomingSession(first.incoming)

        let afterFirst = await currentConnections(store)
        #expect(afterFirst.count == 1)
        let oldConnectionID = try #require(afterFirst.first?.id)

        // Kill the first session so it is genuinely dead. Timing no longer
        // matters — the new incoming session must replace it because the old
        // one is no longer `.ready`.
        await first.incoming.cancel()
        #expect(await first.incoming.state == .cancelled)

        let second = try await makeStartedIncomingSession(
            peerDeviceID: peerDeviceID,
            clientIdentityManager: clientIdentity
        )
        defer { Task { await second.stop() } }
        await store.acceptIncomingSession(second.incoming)

        let afterSecond = await currentConnections(store)
        // Still a single connection for the peer, but it is a fresh one — the
        // dead connection was replaced.
        #expect(afterSecond.count == 1)
        #expect(afterSecond.first?.id != oldConnectionID)
        #expect(afterSecond.first?.peerID.deviceID == peerDeviceID)

        // The new session stays live.
        #expect(await second.incoming.state == .ready)

        await store.stop()
    }

    // MARK: - Test Constants

    /// The width of the dedup time window that the previous (fragile)
    /// implementation used. Liveness-based dedup no longer keys on a window;
    /// the `liveSamePeerConnectionOutsideWindowIsDropped` test waits past this
    /// to prove that a live connection is kept regardless of elapsed time.
    private let formerDuplicateWindow: Duration = .seconds(3)

    // MARK: - Store Helpers

    @MainActor
    private func makeStore() -> LoomStore {
        let serviceType = "_dedup\(UUID().uuidString.prefix(6).lowercased())._tcp"
        let configuration = LoomContainerConfiguration(
            serviceType: serviceType,
            serviceName: "Dedup Store Host",
            deviceIDSuiteName: "com.ethanlipnik.loom.tests.dedup-store.\(UUID().uuidString)",
            enablePeerToPeer: false
        )
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                serviceType: serviceType,
                enablePeerToPeer: false,
                enabledDirectTransports: [.tcp]
            ),
            identityManager: makeIdentityManager(label: "dedup-node")
        )
        return LoomStore(
            configuration: configuration,
            deviceID: UUID(),
            node: node,
            trustStore: LoomTrustStore(
                suiteName: "com.ethanlipnik.loom.tests.dedup-trust.\(UUID().uuidString)"
            ),
            cloudKitManager: nil,
            peerProvider: nil,
            shareManager: nil,
            signalingClient: nil,
            connectionCoordinator: LoomConnectionCoordinator(node: node)
        )
    }

    @MainActor
    private func makeIdentityManager(label: String) -> LoomIdentityManager {
        LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.\(label).\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
    }

    /// Reads the current connection snapshots. `makeSnapshotStream()` yields the
    /// current snapshot as its initial value, so the first element reflects the
    /// store's settled state after an awaited `acceptIncomingSession`.
    @MainActor
    private func currentConnections(_ store: LoomStore) async -> [LoomConnectionSnapshot] {
        let stream = await store.makeSnapshotStream()
        for await snapshot in stream {
            return snapshot.connections
        }
        return []
    }

    // MARK: - Loopback Incoming Session

    /// A started loopback session pair where `incoming` is the receiver side
    /// (the session the store accepts as an incoming connection) authenticated
    /// against a client whose hello carries `peerDeviceID`.
    private struct StartedIncomingSession {
        let listener: NWListener
        let client: LoomAuthenticatedSession
        let incoming: LoomAuthenticatedSession

        func stop() async {
            listener.cancel()
            await client.cancel()
            await incoming.cancel()
        }
    }

    @MainActor
    private func makeStartedIncomingSession(
        peerDeviceID: UUID,
        clientIdentityManager: LoomIdentityManager
    ) async throws -> StartedIncomingSession {
        let listener = try NWListener(using: .tcp, on: .any)
        let acceptedConnection = DedupAsyncBox<NWConnection>()
        let readyPort = DedupAsyncBox<UInt16>()

        listener.newConnectionHandler = { connection in
            Task { await acceptedConnection.set(connection) }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue {
                Task { await readyPort.set(port) }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))

        let port = try #require(await readyPort.take())
        let clientConnection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let serverConnection = try #require(await acceptedConnection.take(after: {
            clientConnection.start(queue: .global(qos: .userInitiated))
        }))

        let client = LoomAuthenticatedSession(
            rawSession: LoomSession(connection: clientConnection),
            role: .initiator,
            transportKind: .tcp
        )
        let incoming = LoomAuthenticatedSession(
            rawSession: LoomSession(connection: serverConnection),
            role: .receiver,
            transportKind: .tcp
        )

        // The client's hello device id becomes the resolved peer id on the
        // receiver, so reusing `peerDeviceID` makes two sessions look like the
        // same peer.
        let clientHello = LoomSessionHelloRequest(
            deviceID: peerDeviceID,
            deviceName: "Dedup Peer",
            deviceType: .iPad,
            advertisement: LoomPeerAdvertisement(deviceID: peerDeviceID, deviceType: .iPad)
        )
        let serverHello = LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Dedup Store Host",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(deviceType: .mac)
        )
        let serverIdentityManager = makeIdentityManager(label: "dedup-incoming-server")

        async let clientContext = client.start(
            localHello: clientHello,
            identityManager: clientIdentityManager
        )
        async let serverContext = incoming.start(
            localHello: serverHello,
            identityManager: serverIdentityManager
        )
        _ = try await (clientContext, serverContext)

        return StartedIncomingSession(
            listener: listener,
            client: client,
            incoming: incoming
        )
    }
}

private actor DedupAsyncBox<Value: Sendable> {
    private var value: Value?
    private var continuations: [CheckedContinuation<Value?, Never>] = []

    func set(_ newValue: Value) {
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: newValue)
            return
        }
        value = newValue
    }

    func take(after action: @escaping @Sendable () -> Void) async -> Value? {
        action()
        return await take()
    }

    func take() async -> Value? {
        if let value {
            self.value = nil
            return value
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
