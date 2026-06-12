//
//  LoomTelemetryExporterTests.swift
//  LoomTests
//
//  WID-344: telemetry export over instrumentation/diagnostics sinks.
//

import Foundation
@testable import Loom
import Testing

@Suite("Loom Telemetry Exporter", .serialized)
struct LoomTelemetryExporterTests {

    @Test("Aggregates step counts and flushes one snapshot per window")
    func aggregatesAndFlushes() async throws {
        let collected = SnapshotCollector()
        // Long interval — we drive flushes manually for determinism.
        let exporter = LoomTelemetryExporter(interval: .seconds(3600)) { snapshot in
            await collected.append(snapshot)
        }

        await exporter.record(event: LoomInstrumentationEvent(step: "loom.test.alpha"))
        await exporter.record(event: LoomInstrumentationEvent(step: "loom.test.alpha"))
        await exporter.record(event: LoomInstrumentationEvent(step: "loom.test.beta"))
        await exporter.flush()

        let snapshots = await collected.snapshots
        #expect(snapshots.count == 1)
        #expect(snapshots[0].stepCounts["loom.test.alpha"] == 2)
        #expect(snapshots[0].stepCounts["loom.test.beta"] == 1)
        #expect(snapshots[0].errorCounts.isEmpty)
    }

    @Test("Empty windows are not exported")
    func skipsEmptyWindows() async throws {
        let collected = SnapshotCollector()
        let exporter = LoomTelemetryExporter(interval: .seconds(3600)) { snapshot in
            await collected.append(snapshot)
        }
        await exporter.flush()
        await exporter.flush()
        #expect(await collected.snapshots.isEmpty)
    }

    @Test("Counters reset between windows")
    func countersResetBetweenWindows() async throws {
        let collected = SnapshotCollector()
        let exporter = LoomTelemetryExporter(interval: .seconds(3600)) { snapshot in
            await collected.append(snapshot)
        }
        await exporter.record(event: LoomInstrumentationEvent(step: "loom.test.alpha"))
        await exporter.flush()
        await exporter.record(event: LoomInstrumentationEvent(step: "loom.test.alpha"))
        await exporter.flush()

        let snapshots = await collected.snapshots
        #expect(snapshots.count == 2)
        #expect(snapshots[0].stepCounts["loom.test.alpha"] == 1)
        #expect(snapshots[1].stepCounts["loom.test.alpha"] == 1)
    }

    @Test("OTLP JSON encoding produces the expected envelope")
    func otlpEncoding() throws {
        let snapshot = LoomTelemetrySnapshot(
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 160),
            stepCounts: ["loom.test.alpha": 2],
            errorCounts: ["transfer/error": 1]
        )
        let data = try LoomTelemetryExporter.otlpJSONData(from: snapshot, serviceName: "com.test.app")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceMetrics = try #require(object["resourceMetrics"] as? [[String: Any]])
        #expect(resourceMetrics.count == 1)

        let scopeMetrics = try #require(resourceMetrics[0]["scopeMetrics"] as? [[String: Any]])
        let metrics = try #require(scopeMetrics[0]["metrics"] as? [[String: Any]])
        // One step metric + one error metric.
        #expect(metrics.count == 2)

        let names = Set(metrics.compactMap { $0["name"] as? String })
        #expect(names == ["loom.instrumentation.steps", "loom.diagnostics.errors"])
    }
}

private actor SnapshotCollector {
    private(set) var snapshots: [LoomTelemetrySnapshot] = []
    func append(_ snapshot: LoomTelemetrySnapshot) {
        snapshots.append(snapshot)
    }
}
