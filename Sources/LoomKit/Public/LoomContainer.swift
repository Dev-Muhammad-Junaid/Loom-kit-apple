//
//  LoomContainer.swift
//  LoomKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation
import Loom
import LoomCloudKit
import LoomSharedRuntime

/// Shared LoomKit runtime container modeled after SwiftData's `ModelContainer`.
@MainActor
public final class LoomContainer {
    /// Normalized configuration used to construct the shared runtime stack.
    public let configuration: LoomContainerConfiguration
    /// Default main-actor context injected into SwiftUI environment values.
    public let mainContext: LoomContext

    private let store: LoomStore

    /// Creates a SwiftUI-first LoomKit container and its shared runtime stack.
    public init(for configuration: LoomContainerConfiguration) throws {
        let trimmedServiceType = configuration.serviceType.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedServiceName = configuration.serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServiceType.isEmpty else {
            throw LoomKitError(message: "LoomKit service type must not be empty.")
        }
        guard !trimmedServiceName.isEmpty else {
            throw LoomKitError(message: "LoomKit service name must not be empty.")
        }

        self.configuration = LoomContainerConfiguration(
            serviceType: trimmedServiceType,
            serviceName: trimmedServiceName,
            deviceIDSuiteName: configuration.deviceIDSuiteName,
            cloudKit: configuration.cloudKit,
            overlayDirectory: configuration.overlayDirectory,
            remoteSignaling: configuration.remoteSignaling,
            appGroup: configuration.appGroup,
            trust: configuration.trust,
            enablePeerToPeer: configuration.enablePeerToPeer,
            advertisementMetadata: configuration.advertisementMetadata,
            supportedFeatures: configuration.supportedFeatures,
            bootstrapMetadataProvider: configuration.bootstrapMetadataProvider,
            remoteSessionID: configuration.remoteSessionID,
            transferConfiguration: configuration.transferConfiguration,
            directConnectionPolicy: configuration.directConnectionPolicy,
            // Thread the reconnection and rate-limit policies through the
            // rebuilt configuration. Omitting them silently substituted the
            // `.default` retry policy (maxAttempts == 5), so an app that asked
            // for `.disabled` still auto-reconnected — re-dialing a peer whose
            // live connection had just been replaced and driving a churn loop.
            retryPolicy: configuration.retryPolicy,
            messageRateLimitPolicy: configuration.messageRateLimitPolicy
        )

        let deviceID = LoomSharedDeviceID.getOrCreate(
            suiteName: configuration.deviceIDSuiteName
        )
        let networkConfiguration = LoomNetworkConfiguration(
            serviceType: trimmedServiceType,
            overlayProbePort: configuration.overlayDirectory?.probePort,
            enablePeerToPeer: configuration.enablePeerToPeer,
            directConnectionPolicy: configuration.directConnectionPolicy
        )
        let trustStore = LoomTrustStore(suiteName: configuration.deviceIDSuiteName)
        let node = LoomNode(
            configuration: networkConfiguration,
            identityManager: LoomIdentityManager.shared
        )
        let signalingClient = configuration.remoteSignaling.map { LoomRemoteSignalingClient(configuration: $0) }
        let cloudKitConfiguration = configuration.cloudKit.map {
            Self.resolvedCloudKitConfiguration(
                $0,
                deviceIDSuiteName: configuration.deviceIDSuiteName
            )
        }
        let cloudKitManager = cloudKitConfiguration.map(LoomCloudKitManager.init(configuration:))
        let peerProvider = cloudKitManager.map(LoomCloudKitPeerProvider.init(cloudKitManager:))
        let shareManager = cloudKitManager.map { LoomCloudKitShareManager(cloudKitManager: $0) }

        if let cloudKitManager {
            node.trustProvider = LoomCloudKitTrustProvider(
                cloudKitManager: cloudKitManager,
                localTrustStore: trustStore,
                trustMode: Self.cloudKitTrustMode(for: configuration.trust)
            )
        } else {
            node.trustProvider = LoomLocalTrustProvider(trustStore: trustStore)
        }

        let connectionCoordinator = LoomConnectionCoordinator(
            node: node,
            signalingClient: signalingClient,
            policy: configuration.directConnectionPolicy
        )
        let bootstrapMetadataProvider = self.configuration.bootstrapMetadataProvider
        let hostAdvertisementMetadata = self.configuration.advertisementMetadata
        let hostSupportedFeatures = self.configuration.supportedFeatures
        let overlayDirectoryConfiguration = self.configuration.overlayDirectory
        let hostClient: LoomHostClient?
        #if os(macOS)
        if let appGroup = self.configuration.appGroup {
            let sharedHost = LoomSharedHostConfiguration(
                appGroupIdentifier: appGroup.appGroupIdentifier,
                app: LoomHostAppDescriptor(
                    appID: appGroup.app.appID,
                    displayName: appGroup.app.displayName,
                    metadata: appGroup.app.metadata,
                    supportedFeatures: appGroup.app.supportedFeatures
                ),
                socketName: appGroup.socketName
            )
            hostClient = LoomHostClient(
                configuration: sharedHost,
                runtimeFactory: {
                    LoomHostRuntimeDependencies(
                        serviceName: trimmedServiceName,
                        deviceID: deviceID,
                        node: node,
                        cloudKitManager: cloudKitManager,
                        peerProvider: peerProvider,
                        shareManager: shareManager,
                        signalingClient: signalingClient,
                        overlayDirectoryConfiguration: overlayDirectoryConfiguration,
                        connectionCoordinator: connectionCoordinator,
                        bootstrapMetadataProvider: bootstrapMetadataProvider,
                        hostAdvertisementMetadata: hostAdvertisementMetadata,
                        hostSupportedFeatures: hostSupportedFeatures
                    )
                }
            )
        } else {
            hostClient = nil
        }
        #else
        hostClient = nil
        #endif
        store = LoomStore(
            configuration: self.configuration,
            deviceID: deviceID,
            node: node,
            trustStore: trustStore,
            cloudKitManager: cloudKitManager,
            peerProvider: peerProvider,
            shareManager: shareManager,
            signalingClient: signalingClient,
            connectionCoordinator: connectionCoordinator,
            hostClient: hostClient
        )
        mainContext = LoomContext(store: store)
    }

    /// Creates another context backed by the same shared LoomKit store.
    public func makeContext() -> LoomContext {
        LoomContext(store: store)
    }

    /// Placeholder container used as the SwiftUI environment default.
    ///
    /// This is safe because the configuration uses hardcoded non-empty values
    /// that always pass validation. A `preconditionFailure` guards against
    /// future regressions instead of an opaque `try!` crash.
    static let environmentFallback: LoomContainer = {
        do {
            return try LoomContainer(
                for: LoomContainerConfiguration(
                    serviceName: "Loom"
                )
            )
        } catch {
            preconditionFailure(
                "LoomContainer environment fallback failed to initialize: \(error.localizedDescription)"
            )
        }
    }()

    private static func cloudKitTrustMode(for trustMode: LoomTrustMode) -> LoomCloudKitTrustMode {
        switch trustMode {
        case .manualOnly:
            .manualOnly
        case .sameAccountAutoTrust:
            .sameAccountAutoTrust
        case .shareAwareAutoTrust:
            .shareAwareAutoTrust
        }
    }

    private static func resolvedCloudKitConfiguration(
        _ configuration: LoomCloudKitConfiguration,
        deviceIDSuiteName: String?
    ) -> LoomCloudKitConfiguration {
        LoomCloudKitConfiguration(
            containerIdentifier: configuration.containerIdentifier,
            deviceRecordType: configuration.deviceRecordType,
            peerRecordType: configuration.peerRecordType,
            peerZoneName: configuration.peerZoneName,
            participantIdentityRecordType: configuration.participantIdentityRecordType,
            shareTitle: configuration.shareTitle,
            deviceIDKey: configuration.deviceIDKey,
            deviceIDSuiteName: configuration.deviceIDSuiteName ?? deviceIDSuiteName,
            shareParticipantCacheTTL: configuration.shareParticipantCacheTTL
        )
    }
}
