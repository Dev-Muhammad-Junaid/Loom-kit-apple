# Add Remote Reachability and Bootstrap

Remote support in Loom is intentionally composable. You can adopt as much or as little of it as your product needs.

The broad pattern looks like this:

1. probe whether direct external connectivity is possible
2. publish remote presence and candidates
3. expose bootstrap metadata for recovery paths
4. attempt deterministic recovery in app-owned policy order

That is also how `MirageKit` uses Loom. Remote reachability, CloudKit peer records, and bootstrap control are layered on top of the same local discovery and identity model.

## Start with STUN preflight

Use ``LoomSTUNProbe`` to see whether the current network can expose a usable mapped endpoint.

```swift
let stunResult = await LoomSTUNProbe.run()

guard stunResult.reachable,
      let address = stunResult.mappedAddress,
      let port = stunResult.mappedPort else {
    return
}

let candidate = LoomRelayCandidate(
    transport: .quic,
    address: address,
    port: port
)
```

That gives your app concrete information about whether direct remote connectivity is even worth advertising.

## Publish remote presence

Use ``LoomRelayClient`` with app-owned signaling credentials.

```swift
let relayClient = LoomRelayClient(configuration: relayConfiguration)

try await relayClient.advertisePeerSession(
    sessionID: sessionID,
    peerID: deviceID,
    acceptingConnections: true,
    peerCandidates: [candidate]
)
```

The important ownership split is the same as everywhere else in Loom:

- Loom signs and sends the signaling requests
- your app owns the session identifier, endpoint, Worker deployment, and policy for when remote access is exposed

## Publish bootstrap metadata separately

Bootstrap recovery is not the same thing as the primary session transport.

Use ``LoomBootstrapMetadata`` to publish optional recovery channels such as:

- SSH endpoints
- a bootstrap control port
- a pinned SSH host key fingerprint
- a Wake-on-LAN payload

```swift
let bootstrapMetadata = LoomBootstrapMetadata(
    enabled: true,
    supportsControlChannel: true,
    supportsCredentialSubmission: true,
    endpoints: [
        .init(host: "host.example.com", port: 22, source: .user),
        .init(host: "192.168.1.25", port: 22, source: .auto),
    ],
    sshPort: 22,
    controlPort: 9849,
    sshHostKeyFingerprint: hostKeyFingerprint,
    controlAuthSecret: controlSecret,
    wakeOnLAN: .init(
        macAddress: "AA:BB:CC:DD:EE:FF",
        broadcastAddresses: ["192.168.1.255"]
    )
)
```

`MirageKit` persists this kind of information alongside peer records so remote recovery can happen without overloading the local session protocol.

## Resolve endpoints deterministically

Before attempting recovery, normalize the endpoint list with ``LoomBootstrapEndpointResolver``.

```swift
let orderedEndpoints = LoomBootstrapEndpointResolver.resolve(bootstrapMetadata.endpoints)
```

That gives you a stable order:

1. user-entered endpoints
2. auto-discovered endpoints
3. last-seen cached endpoints

That deterministic order is important when you want retries to feel predictable across launches.

## Use the control channel first when available

If the peer publishes a control port and auth secret, ``LoomDefaultBootstrapControlClient`` gives you a single-line TCP protocol for status checks and credential submission.

```swift
let controlClient = LoomDefaultBootstrapControlClient()

let status = try await controlClient.requestStatus(
    endpoint: orderedEndpoints[0],
    controlPort: bootstrapMetadata.controlPort ?? 0,
    controlAuthSecret: bootstrapMetadata.controlAuthSecret ?? "",
    timeout: .seconds(3)
)
```

That is the cleanest path when the peer already exposes a dedicated bootstrap daemon.

## Fall back to Wake-on-LAN or SSH when needed

Loom also ships focused clients for the other common recovery steps:

- ``LoomDefaultWakeOnLANClient`` sends magic packets using ``LoomWakeOnLANInfo``
- ``LoomDefaultSSHBootstrapClient`` validates pinned-host SSH credentials with ``LoomBootstrapEndpoint``

Those clients are deliberately narrow. Your app still decides:

- when to wake a device
- which credentials can be submitted
- how many retries are acceptable
- how recovery status maps into UI

That is the right split. Bootstrap logic is transport-adjacent, but the policy is still product-owned.
