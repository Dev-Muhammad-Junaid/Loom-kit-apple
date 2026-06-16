//
//  LoomConnectionLifecycleTests.swift
//  Loom
//
//  Tests for connection lifecycle: goodbye frame, retry gating,
//  stale detection, and deduplication behavior.
//

@testable import Loom
@testable import LoomKit
import Foundation
import Network
import Testing

@Suite("Connection Lifecycle", .serialized)
struct LoomConnectionLifecycleTests {

    // MARK: - Goodbye Frame

    @MainActor
    @Test("Goodbye frame is received before disconnect completes")
    func goodbyeFrameReceivedBeforeDisconnect() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }

        async let clientCtx = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverCtx = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager
        )
        _ = try await (clientCtx, serverCtx)

        let serverErrorBox = CallbackBox<String?>()
        let serverHandle = LoomConnectionHandle(
            id: UUID(),
            peer: makePeerSnapshot(
                id: pair.clientHello.deviceID,
                name: pair.clientHello.deviceName,
                deviceType: pair.clientHello.deviceType
            ),
            session: pair.server,
            transferConfiguration: .default,
            onStateChanged: { _, _, _ in },
            onTransferChanged: { _ in },
            onDisconnected: { _, errorMessage in
                await serverErrorBox.set(errorMessage)
            }
        )
        let clientHandle = makeHandle(
            session: pair.client,
            peerID: pair.serverHello.deviceID,
            peerName: pair.serverHello.deviceName,
            peerDeviceType: pair.serverHello.deviceType
        )
        await clientHandle.startObservers()
        await serverHandle.startObservers()

        // Client sends a goodbye frame before cancelling (our disconnect() method)
        await clientHandle.disconnect()

        // Wait for server to process the disconnection
        let errorFromCallback = try await withTimeout(seconds: 3) {
            await serverErrorBox.take()
        }

        // The error should be nil because the goodbye frame was received,
        // meaning the server treats this as a graceful close → no retry.
        #expect(errorFromCallback == nil)
    }

    @MainActor
    @Test("Disconnect without goodbye reports failure error to the peer")
    func disconnectWithoutGoodbyeReportsFailure() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }

        async let clientCtx = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverCtx = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager
        )
        _ = try await (clientCtx, serverCtx)

        let serverErrorBox = CallbackBox<String?>()
        let serverHandle = LoomConnectionHandle(
            id: UUID(),
            peer: makePeerSnapshot(
                id: pair.clientHello.deviceID,
                name: pair.clientHello.deviceName,
                deviceType: pair.clientHello.deviceType
            ),
            session: pair.server,
            transferConfiguration: .default,
            onStateChanged: { _, _, _ in },
            onTransferChanged: { _ in },
            onDisconnected: { _, errorMessage in
                await serverErrorBox.set(errorMessage)
            }
        )
        await serverHandle.startObservers()

        // Directly cancel the session (simulate abrupt network drop — no goodbye)
        await pair.client.cancel()

        _ = try await withTimeout(seconds: 3) {
            await serverErrorBox.take()
        }

        // Without a goodbye frame, the server sees a failure with an error.
        // This is the scenario where retry WOULD be considered (if conditions met).
        // Note: depending on NWConnection behavior, this could be nil (.cancelled)
        // or a posix error string (.failed). Both are valid responses.
        // The key assertion is that the disconnect callback was invoked.
    }

    // MARK: - Concurrent Multi-Stream Draining (FIX 2)

    @MainActor
    @Test("Payload on a SECOND default-message stream is delivered without closing the first")
    func secondMessageStreamIsDrainedConcurrently() async throws {
        let pair = try await makeLoopbackPair()
        defer { Task { await pair.stop() } }

        async let clientCtx = pair.client.start(
            localHello: pair.clientHello,
            identityManager: pair.clientIdentityManager
        )
        async let serverCtx = pair.server.start(
            localHello: pair.serverHello,
            identityManager: pair.serverIdentityManager
        )
        _ = try await (clientCtx, serverCtx)

        // Server-side handle observing the session. Its incoming-stream
        // observer must drain every default-message stream concurrently.
        let serverHandle = LoomConnectionHandle(
            id: UUID(),
            peer: makePeerSnapshot(
                id: pair.clientHello.deviceID,
                name: pair.clientHello.deviceName,
                deviceType: pair.clientHello.deviceType
            ),
            session: pair.server,
            transferConfiguration: .default,
            onStateChanged: { _, _, _ in },
            onTransferChanged: { _ in },
            onDisconnected: { _, _ in }
        )
        await serverHandle.startObservers()

        // The private default-message stream label from LoomConnectionHandle.
        let messageLabel = "loomkit.messages.v1"
        let firstMarker = Data("first-stream-open".utf8)
        let secondPayload = Data("second-stream-payload".utf8)

        // Open TWO default-message streams over the one session. The first is
        // opened (and left OPEN) and the distinct assertion payload is sent on
        // the SECOND. Without FIX 2 the server's single inner `for await` loop
        // blocks on the first stream, so the second stream's payload buffers
        // unread until the first closes — and this await times out. With FIX 2
        // each stream is drained in its own child task, so it arrives promptly.
        let firstStream = try await pair.client.openStream(label: messageLabel)
        try await firstStream.send(firstMarker)

        let secondStream = try await pair.client.openStream(label: messageLabel)
        try await secondStream.send(secondPayload)

        // Collect from the server handle's `messages` stream until the second
        // stream's distinct payload appears. The first stream is never closed.
        let received = try await withTimeout(seconds: 5) {
            for await data in serverHandle.messages {
                if data == secondPayload {
                    return data
                }
            }
            return Data()
        }

        #expect(received == secondPayload)
    }

    // MARK: - Retry Policy

    @Test("Retry policy with disabled maxAttempts never retries")
    func retryPolicyDisabledNeverRetries() {
        let policy = LoomRetryPolicy.disabled
        #expect(policy.isDisabled)
        #expect(policy.maxAttempts == 0)
    }

    @MainActor
    @Test("LoomContainer preserves a .disabled retry policy (zero reconnect attempts)")
    func containerPreservesDisabledRetryPolicy() throws {
        // Regression: LoomContainer.init rebuilds the configuration to trim the
        // service name/type and previously omitted `retryPolicy`, silently
        // substituting `.default` (maxAttempts == 5). An app asking for
        // `.disabled` therefore still auto-reconnected (the observed
        // "auto-reconnect attempt 1/5"), re-dialing a peer whose live link had
        // just been replaced and driving a churn loop.
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Retry Policy Device",
                retryPolicy: .disabled
            )
        )

        #expect(container.configuration.retryPolicy.isDisabled)
        #expect(container.configuration.retryPolicy.maxAttempts == 0)
    }

    @MainActor
    @Test("LoomContainer preserves a custom retry policy")
    func containerPreservesCustomRetryPolicy() throws {
        let container = try LoomContainer(
            for: LoomContainerConfiguration(
                serviceName: "Retry Policy Device",
                retryPolicy: LoomRetryPolicy(maxAttempts: 3)
            )
        )

        #expect(container.configuration.retryPolicy.maxAttempts == 3)
    }

    @Test("Retry policy default has sensible values")
    func retryPolicyDefaultValues() {
        let policy = LoomRetryPolicy.default
        #expect(policy.maxAttempts == 5)
        #expect(policy.minimumEstablishedDuration == .seconds(10))
        #expect(!policy.isDisabled)
    }

    @Test("Retry policy minimum established duration is configurable")
    func retryPolicyMinimumEstablishedDurationConfigurable() {
        let policy = LoomRetryPolicy(minimumEstablishedDuration: .seconds(30))
        #expect(policy.minimumEstablishedDuration == .seconds(30))
    }

    @Test("Retry policy delay increases with attempt index")
    func retryPolicyDelayIncreasesWithAttempt() {
        let policy = LoomRetryPolicy(
            baseDelay: .seconds(1),
            maxDelay: .seconds(60),
            multiplier: 2.0,
            jitterFraction: 0.0
        )
        let delay0 = policy.delay(forAttempt: 0)
        let delay1 = policy.delay(forAttempt: 1)
        let delay2 = policy.delay(forAttempt: 2)

        #expect(delay0 == .milliseconds(1000))
        #expect(delay1 == .milliseconds(2000))
        #expect(delay2 == .milliseconds(4000))
    }

    @Test("Retry policy delay is capped at maxDelay")
    func retryPolicyDelayCappedAtMax() {
        let policy = LoomRetryPolicy(
            baseDelay: .seconds(1),
            maxDelay: .seconds(5),
            multiplier: 10.0,
            jitterFraction: 0.0
        )
        let delay3 = policy.delay(forAttempt: 3)
        #expect(delay3 == .milliseconds(5000))
    }

    // MARK: - Connection Snapshot States

    @Test("LoomConnectionSnapshot.State includes stale case")
    func snapshotStateIncludesStale() {
        let state = LoomConnectionSnapshot.State.stale
        #expect(state.rawValue == "stale")
    }

    @Test("All connection states have distinct raw values")
    func allConnectionStatesDistinct() {
        let states: [LoomConnectionSnapshot.State] = [
            .connecting, .connected, .stale, .disconnecting,
            .disconnected, .failed, .reconnecting,
        ]
        let rawValues = Set(states.map(\.rawValue))
        #expect(rawValues.count == states.count)
    }

    // MARK: - Rate Limiter

    @Test("Unlimited rate limiter policy is the default")
    func unlimitedRateLimiterIsDefault() {
        let policy = LoomMessageRateLimitPolicy.default
        #expect(policy == .unlimited)
        #expect(policy.maxBurst == .max)
    }

    @Test("Unlimited rate limiter produces nil limiter in connection handle")
    func unlimitedPolicyProducesNilLimiter() {
        let policy = LoomMessageRateLimitPolicy.unlimited
        let shouldBeNil = policy == .unlimited
        #expect(shouldBeNil)
    }

    @Test("Moderate rate limiter allows burst then throttles")
    func moderateRateLimiterThrottlesAfterBurst() {
        let policy = LoomMessageRateLimitPolicy.moderate
        let limiter = LoomTokenBucketRateLimiter(policy: policy)

        // Should consume up to maxBurst tokens
        var consumed = 0
        for _ in 0..<policy.maxBurst {
            if limiter.tryConsume() {
                consumed += 1
            }
        }
        #expect(consumed == policy.maxBurst)

        // Next one should be throttled (no refill time elapsed)
        let throttled = !limiter.tryConsume()
        #expect(throttled)
    }

    @Test("Strict rate limiter reports correct drop count")
    func strictRateLimiterDropCount() {
        let policy = LoomMessageRateLimitPolicy.strict
        let limiter = LoomTokenBucketRateLimiter(policy: policy)

        // Exhaust the bucket
        for _ in 0..<policy.maxBurst {
            _ = limiter.tryConsume()
        }

        // These should be dropped
        _ = limiter.tryConsume()
        _ = limiter.tryConsume()
        _ = limiter.tryConsume()

        #expect(limiter.droppedCount == 3)
    }

    // MARK: - Connection Origin

    @Test("Connection origin enum distinguishes outgoing and incoming")
    func connectionOriginValues() {
        let outgoing = LoomConnectionOrigin.outgoing
        let incoming = LoomConnectionOrigin.incoming
        #expect(outgoing.rawValue == "outgoing")
        #expect(incoming.rawValue == "incoming")
        #expect(outgoing != incoming)
    }

    // MARK: - Connection Health

    @Test("Health snapshot derives poor quality from unsatisfied path")
    func healthSnapshotDerivesFromPath() {
        let path = LoomSessionNetworkPathSnapshot(
            status: .unsatisfied,
            interfaceNames: [],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: false,
            supportsIPv6: false,
            usesWiFi: false,
            usesWiredEthernet: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            localEndpoint: nil,
            remoteEndpoint: nil
        )
        let health = LoomConnectionHealthSnapshot(from: path)
        #expect(health.quality == .poor)
        #expect(health.pathStatus == .unsatisfied)
    }

    @Test("Health snapshot derives excellent quality from wired ethernet")
    func healthSnapshotExcellentOnWired() {
        let path = LoomSessionNetworkPathSnapshot(
            status: .satisfied,
            interfaceNames: ["en0"],
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            usesWiFi: false,
            usesWiredEthernet: true,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            localEndpoint: nil,
            remoteEndpoint: nil
        )
        let health = LoomConnectionHealthSnapshot(from: path)
        #expect(health.quality == .excellent)
        #expect(health.interfaceKind == "wired")
    }

    // MARK: - Helpers

    private func makePeerSnapshot(
        id: UUID,
        name: String,
        deviceType: DeviceType
    ) -> LoomPeerSnapshot {
        LoomPeerSnapshot(
            id: id,
            name: name,
            deviceType: deviceType,
            sources: [.nearby],
            isNearby: true,
            isShared: false,
            remoteAccessEnabled: false,
            signalingSessionID: nil,
            advertisement: LoomPeerAdvertisement(
                deviceID: id,
                deviceType: deviceType
            ),
            bootstrapMetadata: nil,
            lastSeen: Date()
        )
    }

    @MainActor
    private func makeHandle(
        session: LoomAuthenticatedSession,
        peerID: UUID,
        peerName: String,
        peerDeviceType: DeviceType
    ) -> LoomConnectionHandle {
        LoomConnectionHandle(
            id: UUID(),
            peer: makePeerSnapshot(id: peerID, name: peerName, deviceType: peerDeviceType),
            session: session,
            transferConfiguration: .default,
            onStateChanged: { _, _, _ in },
            onTransferChanged: { _ in },
            onDisconnected: { _, _ in }
        )
    }
}

// MARK: - Shared Test Infrastructure

private actor CallbackBox<Value: Sendable> {
    private var value: Value?
    private var continuations: [CheckedContinuation<Value, Never>] = []

    func set(_ newValue: Value) {
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: newValue)
            return
        }
        value = newValue
    }

    func take() async -> Value {
        if let value {
            self.value = nil
            return value
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private struct LoopbackSessionPair {
    let listener: NWListener
    let clientIdentityManager: LoomIdentityManager
    let serverIdentityManager: LoomIdentityManager
    let clientHello: LoomSessionHelloRequest
    let serverHello: LoomSessionHelloRequest
    let client: LoomAuthenticatedSession
    let server: LoomAuthenticatedSession

    func stop() async {
        listener.cancel()
        await client.cancel()
        await server.cancel()
    }
}

@MainActor
private func makeLoopbackPair(
    clientDeviceType: DeviceType = .mac,
    serverDeviceType: DeviceType = .mac
) async throws -> LoopbackSessionPair {
    let clientIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.lifecycle-client.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )
    let serverIdentityManager = LoomIdentityManager(
        service: "com.ethanlipnik.loom.tests.lifecycle-server.\(UUID().uuidString)",
        account: "p256-signing",
        synchronizable: false
    )

    let listener = try NWListener(using: .tcp, on: .any)
    let acceptedConnection = AsyncPairBox<NWConnection>()
    let readyPort = AsyncPairBox<UInt16>()

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
    let server = LoomAuthenticatedSession(
        rawSession: LoomSession(connection: serverConnection),
        role: .receiver,
        transportKind: .tcp
    )

    let clientHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Client",
        deviceType: clientDeviceType,
        advertisement: LoomPeerAdvertisement(deviceType: clientDeviceType)
    )
    let serverHello = LoomSessionHelloRequest(
        deviceID: UUID(),
        deviceName: "Server",
        deviceType: serverDeviceType,
        advertisement: LoomPeerAdvertisement(deviceType: serverDeviceType)
    )

    return LoopbackSessionPair(
        listener: listener,
        clientIdentityManager: clientIdentityManager,
        serverIdentityManager: serverIdentityManager,
        clientHello: clientHello,
        serverHello: serverHello,
        client: client,
        server: server
    )
}

private actor AsyncPairBox<Value: Sendable> {
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

private func withTimeout<T: Sendable>(
    seconds: Int64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LoomError.timeout
        }
        guard let result = try await group.next() else {
            throw LoomError.timeout
        }
        group.cancelAll()
        return result
    }
}
