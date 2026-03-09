# Loom

Loom is a Swift package for Apple-to-Apple connectivity.

It handles the infrastructure around peer discovery, identity, trust, session setup, remote reachability, and bootstrap flows so the app above it can stay focused on product protocol and UI.

Used in [MirageKit](https://github.com/EthanLipnik/MirageKit).

## What Loom Owns

- Bonjour discovery and peer-to-peer transport setup
- signed device identity and trust decisions
- direct session lifecycle on top of `Network.framework`
- relay-backed remote coordination and STUN preflight
- bootstrap flows such as Wake-on-LAN, SSH, and control-channel handoff
- diagnostics and instrumentation for the networking layer

## What Loom Does Not Own

- app protocol design
- payload schemas and encoding
- product-specific CloudKit naming
- UI, workflow, or collaboration semantics

If a type starts carrying app-specific behavior, it probably belongs above Loom.

## Package Layout

- `Loom`: the core networking, identity, trust, relay, bootstrap, and diagnostics layer
- `LoomCloudKit`: optional CloudKit-backed peer coordination and trust integration

## Good Fits

- remote workspace and screen-sharing tools
- local-first collaboration products
- peer-to-peer sync systems
- operator and companion apps across Apple devices
- LAN-first apps that need remote fallback

## Docs

- [Docs](https://ethanlipnik.github.io/Loom/documentation/loom/)
- [Architecture](Architecture.md)

## Platforms

- macOS 14+
- iOS 17.4+
- visionOS 26+

## Development

```bash
swift build
swift test --scratch-path .build-local
```
