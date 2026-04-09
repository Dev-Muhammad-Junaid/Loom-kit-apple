//
//  LoomDiagnosticsView.swift
//  LoomKit
//
//  SwiftUI debug dashboard showing runtime state, peers, connections,
//  transfers, CloudKit health, and recent diagnostics events.
//

#if canImport(SwiftUI)
import CloudKit
import Loom
import LoomCloudKit
import SwiftUI

/// Drop-in SwiftUI diagnostics dashboard for inspecting a live LoomKit runtime.
///
/// Embed this view in a debug settings screen or present it in a sheet:
///
/// ```swift
/// .sheet(isPresented: $showDiagnostics) {
///     LoomDiagnosticsView()
/// }
/// ```
///
/// The view reads the current ``LoomContext`` from the SwiftUI environment.
@available(macOS 14, iOS 17, visionOS 1, *)
public struct LoomDiagnosticsView: View {
    @Environment(\.loomContext) private var context
    @Environment(\.loomContainer) private var container
    @State private var cloudKitIssues: [LoomCloudKitSchemaIssue] = []
    @State private var isValidatingSchema = false
    @State private var diagnosticsContext: LoomDiagnosticsContext = [:]
    @State private var isLoadingContext = false

    public init() {}

    public var body: some View {
        List {
            runtimeSection
            peersSection
            connectionsSection
            transfersSection
            cloudKitSection
            diagnosticsContextSection
        }
        #if os(iOS) || os(visionOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Loom Diagnostics")
        .task {
            await loadDiagnosticsContext()
        }
    }

    // MARK: - Runtime

    @ViewBuilder
    private var runtimeSection: some View {
        Section("Runtime") {
            row("Status", value: context.isRunning ? "Running" : "Stopped")
            row("Remote Reachability",
                value: context.isPublishingRemoteReachability ? "Publishing" : "Off")
            if let error = context.lastError {
                row("Last Error", value: error.message, isError: true)
            }
        }
    }

    // MARK: - Peers

    @ViewBuilder
    private var peersSection: some View {
        Section("Peers (\(context.peers.count))") {
            if context.peers.isEmpty {
                Text("No peers discovered")
                    .foregroundStyle(.secondary)
            }
            ForEach(context.peers) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(peer.name)
                            .font(.headline)
                        Spacer()
                        Text(peer.deviceType.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if peer.isNearby {
                            badge("Nearby", color: .green)
                        }
                        if peer.isShared {
                            badge("Shared", color: .blue)
                        }
                        if peer.remoteAccessEnabled {
                            badge("Remote", color: .purple)
                        }
                        ForEach(peer.sources, id: \.rawValue) { source in
                            badge(source.rawValue, color: .gray)
                        }
                    }
                    Text("ID: \(peer.deviceID.uuidString.prefix(8))…")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospaced()
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Connections

    @ViewBuilder
    private var connectionsSection: some View {
        Section("Connections (\(context.connections.count))") {
            if context.connections.isEmpty {
                Text("No active connections")
                    .foregroundStyle(.secondary)
            }
            ForEach(context.connections) { connection in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(connection.peerName)
                            .font(.headline)
                        Spacer()
                        connectionStateBadge(connection.state)
                    }
                    HStack(spacing: 8) {
                        badge(connection.transportKind.rawValue, color: .indigo)
                        Text("Since \(connection.connectedAt, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let error = connection.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Transfers

    @ViewBuilder
    private var transfersSection: some View {
        Section("Transfers (\(context.transfers.count))") {
            if context.transfers.isEmpty {
                Text("No active transfers")
                    .foregroundStyle(.secondary)
            }
            ForEach(context.transfers) { transfer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(transfer.logicalName)
                            .font(.headline)
                        Spacer()
                        Text(transfer.direction.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if transfer.totalBytes > 0 {
                        ProgressView(
                            value: Double(transfer.bytesTransferred),
                            total: Double(transfer.totalBytes)
                        )
                        Text("\(formattedBytes(transfer.bytesTransferred)) / \(formattedBytes(transfer.totalBytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - CloudKit

    @ViewBuilder
    private var cloudKitSection: some View {
        Section("CloudKit Schema") {
            Button {
                Task { await runSchemaValidation() }
            } label: {
                HStack {
                    Text("Validate Schema")
                    Spacer()
                    if isValidatingSchema {
                        ProgressView()
                    }
                }
            }
            .disabled(isValidatingSchema)

            if !cloudKitIssues.isEmpty {
                ForEach(cloudKitIssues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: issue.severity == .error
                                  ? "xmark.circle.fill"
                                  : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? .red : .orange)
                            Text(issue.message)
                                .font(.subheadline)
                        }
                        Text(issue.remediation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } else if !isValidatingSchema, cloudKitIssues.isEmpty {
                Text("Tap Validate to check CloudKit schema health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Diagnostics Context

    @ViewBuilder
    private var diagnosticsContextSection: some View {
        Section("Diagnostics Context") {
            Button {
                Task { await loadDiagnosticsContext() }
            } label: {
                HStack {
                    Text("Refresh Context")
                    Spacer()
                    if isLoadingContext {
                        ProgressView()
                    }
                }
            }
            .disabled(isLoadingContext)

            if diagnosticsContext.isEmpty {
                Text("No context providers registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(
                    diagnosticsContext.sorted(by: { $0.key < $1.key }),
                    id: \.key
                ) { key, value in
                    HStack {
                        Text(key)
                            .font(.subheadline)
                        Spacer()
                        Text(diagnosticsValueDescription(value))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, value: String, isError: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func connectionStateBadge(_ state: LoomConnectionSnapshot.State) -> some View {
        let (label, color): (String, Color) = switch state {
        case .connecting: ("Connecting", .orange)
        case .connected: ("Connected", .green)
        case .stale: ("Stale", .yellow)
        case .disconnecting: ("Disconnecting", .yellow)
        case .disconnected: ("Disconnected", .gray)
        case .failed: ("Failed", .red)
        case .reconnecting: ("Reconnecting", .orange)
        }
        return badge(label, color: color)
    }

    private func formattedBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func diagnosticsValueDescription(_ value: LoomDiagnosticsValue) -> String {
        switch value {
        case let .string(s): s
        case let .bool(b): b ? "true" : "false"
        case let .int(i): "\(i)"
        case let .double(d): String(format: "%.2f", d)
        case let .array(a): "[\(a.count) items]"
        case let .dictionary(d): "{\(d.count) keys}"
        case .null: "null"
        }
    }

    private func runSchemaValidation() async {
        isValidatingSchema = true
        defer { isValidatingSchema = false }

        guard let cloudKit = container.configuration.cloudKit else {
            cloudKitIssues = [LoomCloudKitSchemaIssue(
                severity: .warning,
                recordType: nil,
                field: nil,
                message: "CloudKit is not configured for this LoomContainer.",
                remediation: "Pass a LoomCloudKitConfiguration to LoomContainerConfiguration to enable CloudKit features."
            )]
            return
        }

        cloudKitIssues = await LoomCloudKitSchemaValidator.validate(
            configuration: cloudKit
        )

        if cloudKitIssues.isEmpty {
            cloudKitIssues = [LoomCloudKitSchemaIssue(
                severity: .warning,
                recordType: nil,
                field: nil,
                message: "Schema validation passed — no issues found.",
                remediation: "All expected record types and fields are present."
            )]
        }
    }

    private func loadDiagnosticsContext() async {
        isLoadingContext = true
        defer { isLoadingContext = false }
        diagnosticsContext = await LoomDiagnostics.snapshotContext()
    }
}
#endif
