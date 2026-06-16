//
//  LoomAsyncBroadcaster.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

package final class LoomAsyncBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    /// When `true`, every yielded element is retained and replayed to any
    /// future subscriber. This closes a subscribe-vs-yield race: a stream
    /// `.open` broadcast before an observer subscribes would otherwise be
    /// lost forever (the receiver never drains that stream). Used for the
    /// incoming-stream observer so a late-subscribing `LoomConnectionHandle`
    /// still sees streams opened during session setup.
    private let retainsHistory: Bool
    private var history: [Element] = []

    package init(retainsHistory: Bool = false) {
        self.retainsHistory = retainsHistory
    }

    package func makeStream(
        initialValue: Element? = nil
    ) -> AsyncStream<Element> {
        AsyncStream(Element.self) { continuation in
            let token = UUID()

            // Snapshot replay history while holding the lock together with
            // the continuation insert, so an element yielded concurrently is
            // delivered EITHER via replay OR live — never both, never neither.
            lock.lock()
            continuations[token] = continuation
            let replay = retainsHistory ? history : []
            lock.unlock()

            if let initialValue {
                continuation.yield(initialValue)
            }
            for element in replay {
                continuation.yield(element)
            }

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(for: token)
            }
        }
    }

    package func yield(_ value: Element) {
        lock.lock()
        if retainsHistory {
            history.append(value)
        }
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(value)
        }
    }

    package func finish() {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        continuations.removeAll(keepingCapacity: false)
        history.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.finish()
        }
    }

    private func removeContinuation(for token: UUID) {
        lock.lock()
        continuations.removeValue(forKey: token)
        lock.unlock()
    }
}
