//
//  DeckHandCloud.swift
//  Deck Hand – Shared
//
//  Same-iCloud awareness + remote reachability configuration.
//
//  When CloudKit is enabled on the Loom container, every device signed
//  into the user's iCloud account publishes its identity into the user's
//  *private* CloudKit database. LoomKit merges those records with Bonjour
//  discovery into one peer snapshot — so a peer whose `sources` include
//  `.cloudKitOwn` is provably one of the user's own devices (only the
//  account owner can write to that database). That proof is what powers:
//
//   • iPad: "My Mac" badge + priority sort in the peer picker.
//   • Mac:  auto-allow (no Allow/Deny prompt) for the user's own devices,
//           controllable via the menu-bar toggle and a per-device blocklist.
//
//  None of this changes transport performance — frames travel the same
//  network paths either way. It changes trust and convenience only.
//

import Foundation
import Loom
import LoomCloudKit
import LoomKit

enum DeckHandCloud {
    /// Master switch for same-iCloud awareness. CloudKit requires a paid
    /// Apple Developer account (registered container + iCloud capability
    /// in both targets' entitlements), so this ships OFF. Flip to `true`
    /// once `containerIdentifier` is registered and the iCloud keys in
    /// both .entitlements files are uncommented — no other change needed.
    /// With it off, everything else works exactly as before: Bonjour
    /// discovery, approval prompts, mirror, transfers.
    static let isCloudEnabled = false

    /// CloudKit container shared by the iOS remote and the Mac host.
    /// Must be registered in the Apple Developer portal and present in
    /// both targets' iCloud entitlements.
    static let containerIdentifier = "iCloud.com.deckhand.shared"

    /// CloudKit configuration for the Loom container. `nil` disables
    /// same-iCloud awareness ("My Mac" badge, host auto-allow).
    static var cloudKitConfiguration: LoomCloudKitConfiguration? {
        guard isCloudEnabled else { return nil }
        return .init(
            containerIdentifier: containerIdentifier,
            // Same suite as the Loom container so the CloudKit record
            // carries the identical device ID Bonjour advertises — that
            // equality is what lets LoomKit merge the two sources.
            deviceIDSuiteName: "DeckHandLoomStore"
        )
    }

    /// Remote signaling (over-the-internet reachability) configuration.
    ///
    /// Returns `nil` until a relay backend is deployed — Loom's signaling
    /// client is ready (see `LoomRemoteSignalingConfiguration` and the
    /// open WID-341 reference-server issue), and both apps already pass
    /// this through, so deploying a relay and filling in the URL + secret
    /// here is the only step left to enable "control my Mac from anywhere".
    static var remoteSignalingConfiguration: LoomRemoteSignalingConfiguration? {
        // Example once a relay exists:
        // LoomRemoteSignalingConfiguration(
        //     baseURL: URL(string: "https://relay.example.com")!,
        //     appAuthentication: .init(
        //         appID: "deckhand",
        //         sharedSecret: <secret from secure storage>
        //     )
        // )
        nil
    }
}

extension LoomPeerSnapshot {
    /// `true` when this peer is one of the current user's own iCloud
    /// devices — its record came from the user's private CloudKit
    /// database, which only the account owner's devices can write to.
    var isSameICloudDevice: Bool {
        sources.contains(.cloudKitOwn)
    }
}
