//
//  DeckHandApp.swift
//  DeckHandiOS
//

import LoomKit
import SwiftUI

@main
struct DeckHandApp: App {
    let loomContainer: LoomContainer

    init() {
        loomContainer = try! LoomContainer(
            for: LoomContainerConfiguration(
                serviceType: "_deckhand._tcp",
                serviceName: UIDevice.current.name,
                deviceIDSuiteName: "DeckHandLoomStore",
                // Same-iCloud awareness: this device publishes its identity
                // to the user's private CloudKit DB; Macs on the same
                // account surface with `.cloudKitOwn` → "My Mac" badge,
                // priority sort, and host-side auto-allow (DeckHandCloud).
                cloudKit: DeckHandCloud.cloudKitConfiguration,
                remoteSignaling: DeckHandCloud.remoteSignalingConfiguration,
                // Manual lifecycle only — see MacHostApp for rationale.
                retryPolicy: .disabled
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentRootView()
                .loomContainer(loomContainer, autostart: false)
        }
    }
}
