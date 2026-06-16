//
//  LoomAsyncBroadcasterReplayTests.swift
//  Loom
//
//  Regression coverage for the incoming-stream observer replay buffer.
//
//  `LoomAsyncBroadcaster` gained `init(retainsHistory:)`. When `true`, every
//  yielded element is retained and replayed (in order) to any subscriber
//  created later via `makeStream(initialValue:)`. This closes a
//  subscribe-vs-yield race: a stream `.open` broadcast before
//  `LoomConnectionHandle` subscribed its incoming-stream observer would
//  otherwise be lost forever (iPad stuck "awaiting authorization").
//
//  These are deterministic unit tests — each broadcaster is `finish()`ed so
//  the draining `for await` terminates and the test can never hang.
//

@testable import Loom
import Foundation
import Testing

@Suite("LoomAsyncBroadcaster Replay")
struct LoomAsyncBroadcasterReplayTests {

    @Test("Late subscriber on a retainsHistory broadcaster replays prior elements in order, then live ones")
    func lateSubscriberReplaysHistoryThenLive() async {
        let broadcaster = LoomAsyncBroadcaster<Int>(retainsHistory: true)

        // Yields BEFORE any subscriber exists. Without the replay buffer these
        // would be lost to a late subscriber (the bug FIX 1 addresses).
        broadcaster.yield(1)
        broadcaster.yield(2)

        // Subscribe AFTER the early yields.
        let stream = broadcaster.makeStream()

        // A subsequent live yield should arrive after the replayed history.
        broadcaster.yield(3)
        broadcaster.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [1, 2, 3])
    }

    @Test("Default (retainsHistory: false) broadcaster does NOT replay to a late subscriber")
    func defaultBroadcasterDoesNotReplay() async {
        let broadcaster = LoomAsyncBroadcaster<Int>()

        broadcaster.yield(1)
        broadcaster.yield(2)

        let stream = broadcaster.makeStream()

        broadcaster.yield(3)
        broadcaster.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        // Pre-subscribe yields are missed; only the live yield is delivered.
        #expect(received == [3])
    }

    @Test("No duplicate delivery: a subscriber present before yields receives each element exactly once")
    func noDuplicateDeliveryForEarlySubscriber() async {
        let broadcaster = LoomAsyncBroadcaster<Int>(retainsHistory: true)

        // Subscribe BEFORE any yields. With the replay buffer, this subscriber
        // must still receive each element exactly once (live delivery only, no
        // replay double-counting).
        let stream = broadcaster.makeStream()

        broadcaster.yield(1)
        broadcaster.yield(2)
        broadcaster.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [1, 2])
    }
}
