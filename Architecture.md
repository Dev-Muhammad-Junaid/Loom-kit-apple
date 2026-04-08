# Loom Architecture

This document describes the generic networking package and its layered products.

It applies to:

- `Sources/Loom`
- `Sources/LoomCloudKit`
- `Sources/LoomShell`
- `Sources/LoomKit`
- `Sources/LoomHost` (target: `LoomSharedRuntime`)
- `Tests/LoomTests`
- `Tests/LoomCloudKitTests`
- `Tests/LoomShellTests`
- `Tests/LoomKitTests`
- `Tests/LoomHostTests`

## 1. Package Topology

Loom is a standalone Swift package with five library products:

- `Loom` — Core transport, identity, trust, bootstrap, diagnostics, and remote signaling.
- `LoomCloudKit` — CloudKit-backed discovery, sharing, and trust. Depends on `Loom`.
- `LoomShell` — Interactive shell sessions over authenticated Loom transport. Depends on `Loom`, `CLoomShellSupport`, and NIO/SSH.
- `LoomKit` — SwiftUI-first container, context, query, and connection handle surface. Depends on `Loom`, `LoomCloudKit`, and `LoomSharedRuntime`.
- `LoomSharedRuntime` — Multi-app host coordination runtime. Depends on `Loom` and `LoomCloudKit`. Source is in `Sources/LoomHost`.

Supported platforms:

- macOS 14+
- iOS 17.4+
- visionOS 2+

External dependencies:

- `swift-nio`
- `swift-nio-ssh`

## 2. Ownership Boundary

Loom is intentionally product-agnostic.

It owns:

- peer discovery
- transport and session lifecycle
- signaling/direct connectivity
- identity and trust
- replay protection
- diagnostics and instrumentation
- bootstrap transport
- STUN and remote signaling
- CloudKit-backed discovery, sharing, and trust
- interactive shell sessions
- SwiftUI-first container and context

It does not own product-specific:

- service types
- CloudKit record naming
- signaling header prefixes
- control message schemas
- stream, window, app, or UI semantics

## 3. Core Types

### 3.1 Node and Session

- `LoomNode` is the main entry point for discovery, advertising, and connections.
- `LoomSession` represents a raw `NWConnection` wrapper.
- `LoomAuthenticatedSession` layers a signed handshake, multiplexed streams, and optional encryption on top of `LoomSession`.
- `LoomPeer` is the discovered or remote-resolved peer model.

`LoomNode` composes discovery, identity, trust, and transport policy into a single object higher-level packages can own directly.

### 3.2 Identity and Trust

- `LoomIdentityManager` manages signing keys and shared-key derivation via Keychain-backed P256 keys.
- `LoomTrustProvider` abstracts approval policy.
- `LoomTrustStore` provides local persistence for trusted peers.
- `LoomCloudKitTrustProvider` adds CloudKit-backed trust semantics when needed.
- `LoomLocalTrustProvider` provides identity-based trust without CloudKit.

### 3.3 LoomKit (SwiftUI Surface)

- `LoomContainer` owns the runtime, modeled after SwiftData's `ModelContainer`.
- `LoomContext` is the main-actor action surface injected through SwiftUI environment.
- `@LoomQuery` provides live peer, connection, and transfer snapshots for SwiftUI.
- `LoomConnectionHandle` is the actor-backed handle for message streams, file transfer, and custom multiplexed streams.
- `LoomStore` is the internal shared state coordinator that merges nearby and CloudKit peers.

### 3.4 Remote and Bootstrap

- `LoomRemoteSignalingClient` handles signaling-backed remote coordination.
- `LoomConnectionCoordinator` resolves and attempts authenticated connections across local, overlay, and signaling paths.
- `LoomSTUNProbe` discovers external candidate information.
- `LoomOverlayDirectory` manages Tailscale and other overlay network peer discovery.
- `LoomBootstrapEndpointResolver`, `LoomBootstrapControlClient`, `LoomWakeOnLANClient`, and `LoomSSHBootstrapClient` support peer recovery and bootstrap flows.

### 3.5 Shell

- `LoomShellService` manages shell session lifecycle on the host.
- `LoomNativeShellSession` runs PTY-backed shell sessions (macOS).
- `LoomShellPlanner` evaluates connection strategies before shell establishment.
- `LoomSSHFallbackRuntime` provides OpenSSH fallback when native Loom transport is unavailable.

### 3.6 Diagnostics

- `LoomDiagnostics` handles structured log/error fan-out and runtime context providers.
- `LoomLogCategory` is string-backed and open so higher-level packages can define their own category vocabularies.
- `LoomInstrumentation` captures timeline-style lifecycle events.

These sinks are generic and reusable. Higher-level packages add their own categories and context without changing Loom's ownership model.

## 4. Layering Rule

Packages above Loom should:

- depend on Loom types directly
- inject product defaults from the product package
- keep product protocol/schema definitions out of Loom

If a type starts carrying product-specific naming or assumptions, it belongs above Loom.

## 5. Product Dependency Graph

```
LoomKit
├── Loom
├── LoomCloudKit → Loom
└── LoomSharedRuntime → Loom, LoomCloudKit

LoomShell
├── CLoomShellSupport
├── Loom
└── swift-nio, swift-nio-ssh
```

`Loom` is the foundation. `LoomCloudKit` extends it with iCloud features. `LoomSharedRuntime` coordinates across multiple apps in an App Group. `LoomKit` composes everything into a SwiftUI-first developer surface. `LoomShell` is independent and can be used without LoomKit.
