//
//  LoomTelemetryExporter.swift
//  Loom
//
//  Telemetry export pathway over the existing instrumentation/diagnostics
//  sink architecture (WID-344).
//
//  Loom deliberately doesn't depend on any telemetry SDK. Instead this
//  exporter aggregates instrumentation steps and diagnostics errors into
//  periodic, allocation-light snapshots and hands them to a pluggable
//  handler. A built-in encoder produces OTLP/JSON (the OpenTelemetry
//  HTTP+JSON metrics wire shape), so adopters can POST snapshots straight
//  to any OpenTelemetry collector — or feed their own pipeline — without
//  Loom taking a dependency.
//
//  Design constraints (performance/memory):
//   • Aggregation is counter-based: a step observed N times within a
//     window is one dictionary entry, never N stored events.
//   • The export handler runs on the exporter's actor, off every hot path.
//   • `LoomInstrumentation.record` already short-circuits when no sinks
//     are registered, so an app that never starts an exporter pays nothing.
//

import Foundation

// MARK: - Snapshot model

/// One aggregation window of telemetry, ready for export.
public struct LoomTelemetrySnapshot: Sendable, Equatable {
    /// Window boundaries (wall clock).
    public let startedAt: Date
    public let endedAt: Date
    /// Instrumentation step counts observed in the window
    /// (e.g. "loom.transfer.complete.incoming.resumed" → 3).
    public let stepCounts: [String: UInt64]
    /// Diagnostics error counts keyed by "category/severity"
    /// (e.g. "transfer/error" → 1).
    public let errorCounts: [String: UInt64]

    public var isEmpty: Bool { stepCounts.isEmpty && errorCounts.isEmpty }

    public init(
        startedAt: Date,
        endedAt: Date,
        stepCounts: [String: UInt64],
        errorCounts: [String: UInt64]
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stepCounts = stepCounts
        self.errorCounts = errorCounts
    }
}

/// Receives finished snapshots. Runs on the exporter's actor — keep it
/// lightweight or hop to your own executor.
public typealias LoomTelemetryExportHandler = @Sendable (LoomTelemetrySnapshot) async -> Void

// MARK: - Exporter

/// Aggregates Loom instrumentation + diagnostics into periodic snapshots.
///
/// ```swift
/// let exporter = LoomTelemetryExporter(interval: .seconds(60)) { snapshot in
///     guard !snapshot.isEmpty else { return }
///     var request = URLRequest(url: collectorURL)   // e.g. …/v1/metrics
///     request.httpMethod = "POST"
///     request.setValue("application/json", forHTTPHeaderField: "Content-Type")
///     request.httpBody = try? LoomTelemetryExporter.otlpJSONData(
///         from: snapshot, serviceName: "com.example.myapp"
///     )
///     _ = try? await URLSession.shared.data(for: request)
/// }
/// await exporter.start()
/// ```
public actor LoomTelemetryExporter: LoomInstrumentationSink, LoomDiagnosticsSink {
    private let interval: Duration
    private let export: LoomTelemetryExportHandler

    private var stepCounts: [String: UInt64] = [:]
    private var errorCounts: [String: UInt64] = [:]
    private var windowStartedAt = Date()

    private var instrumentationToken: LoomInstrumentationSinkToken?
    private var diagnosticsToken: LoomDiagnosticsSinkToken?
    private var flushTask: Task<Void, Never>?

    public init(
        interval: Duration = .seconds(60),
        export: @escaping LoomTelemetryExportHandler
    ) {
        self.interval = interval
        self.export = export
    }

    /// Registers with the instrumentation + diagnostics pipelines and
    /// begins the periodic flush loop. Idempotent.
    public func start() async {
        guard flushTask == nil else { return }
        windowStartedAt = Date()
        instrumentationToken = await LoomInstrumentation.addSink(self)
        diagnosticsToken = await LoomDiagnostics.addSink(self)
        flushTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await self?.flush()
            }
        }
    }

    /// Unregisters and performs a final flush so no counted events are lost.
    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        if let instrumentationToken {
            await LoomInstrumentation.removeSink(instrumentationToken)
            self.instrumentationToken = nil
        }
        if let diagnosticsToken {
            await LoomDiagnostics.removeSink(diagnosticsToken)
            self.diagnosticsToken = nil
        }
        await flush()
    }

    /// Closes the current window and exports it (skips empty windows).
    public func flush() async {
        let endedAt = Date()
        guard !stepCounts.isEmpty || !errorCounts.isEmpty else {
            windowStartedAt = endedAt
            return
        }
        let snapshot = LoomTelemetrySnapshot(
            startedAt: windowStartedAt,
            endedAt: endedAt,
            stepCounts: stepCounts,
            errorCounts: errorCounts
        )
        stepCounts.removeAll(keepingCapacity: true)
        errorCounts.removeAll(keepingCapacity: true)
        windowStartedAt = endedAt
        await export(snapshot)
    }

    // MARK: Sink conformances

    public func record(event: LoomInstrumentationEvent) async {
        stepCounts[event.name, default: 0] += 1
    }

    public func record(error event: LoomDiagnosticsErrorEvent) async {
        let key = "\(event.category.rawValue)/\(event.severity.rawValue)"
        errorCounts[key, default: 0] += 1
    }

    // `record(log:)` uses the protocol's default no-op: log volume is
    // unbounded and belongs in a logging pipeline, not a metrics one.

    // MARK: - OTLP/JSON encoding

    /// Encodes a snapshot as OTLP/HTTP JSON (`ExportMetricsServiceRequest`)
    /// suitable for POSTing to an OpenTelemetry collector's `/v1/metrics`.
    /// Counters are emitted as monotonic delta sums over the window.
    public static func otlpJSONData(
        from snapshot: LoomTelemetrySnapshot,
        serviceName: String
    ) throws -> Data {
        func nanos(_ date: Date) -> String {
            String(UInt64(date.timeIntervalSince1970 * 1_000_000_000))
        }

        func dataPoint(_ value: UInt64) -> [String: Any] {
            [
                "startTimeUnixNano": nanos(snapshot.startedAt),
                "timeUnixNano": nanos(snapshot.endedAt),
                "asInt": String(value),
            ]
        }

        func sumMetric(name: String, points: [[String: Any]]) -> [String: Any] {
            [
                "name": name,
                "sum": [
                    "dataPoints": points,
                    "aggregationTemporality": 1, // AGGREGATION_TEMPORALITY_DELTA
                    "isMonotonic": true,
                ],
            ]
        }

        var metrics: [[String: Any]] = []
        for (step, count) in snapshot.stepCounts.sorted(by: { $0.key < $1.key }) {
            var point = dataPoint(count)
            point["attributes"] = [["key": "loom.step", "value": ["stringValue": step]]]
            metrics.append(sumMetric(name: "loom.instrumentation.steps", points: [point]))
        }
        for (key, count) in snapshot.errorCounts.sorted(by: { $0.key < $1.key }) {
            var point = dataPoint(count)
            point["attributes"] = [["key": "loom.error", "value": ["stringValue": key]]]
            metrics.append(sumMetric(name: "loom.diagnostics.errors", points: [point]))
        }

        let body: [String: Any] = [
            "resourceMetrics": [[
                "resource": [
                    "attributes": [[
                        "key": "service.name",
                        "value": ["stringValue": serviceName],
                    ]],
                ],
                "scopeMetrics": [[
                    "scope": ["name": "loom"],
                    "metrics": metrics,
                ]],
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
