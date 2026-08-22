# Deck Hand

Turn an iPad into a control surface for your Mac.

Deck Hand is a pair of apps — a menu bar host on the Mac and a remote on iPad or
iPhone — that discover each other on the local network and connect directly. The
remote gives you a precision trackpad, a live view of the Mac's screen, capture
tools, an app launcher, and shortcut chips that change with whatever app is
frontmost.

Everything runs peer-to-peer over [Loom](#the-loom-package), which is vendored in
this repository. As shipped there is no account, no relay, and no cloud service
in the path. CloudKit-backed "same iCloud account" awareness and internet
reachability are wired up but switched off in `Shared/DeckHandCloud.swift`, since
both need a paid developer account and a registered container.

## What it does

**Pointer and keyboard.** A multi-touch trackpad with adjustable sensitivity,
two-finger scrolling with native phase and momentum (so the Mac rubber-bands like
a real trackpad rather than emitting wheel ticks), clicks, double-clicks, and
keyboard shortcuts.

**Live mirror.** A floating thumbnail streams the Mac's screen as JPEG frames.
Pinch it and it grows to roughly full screen, renegotiating resolution in tiers
as it goes, up to 1920 px wide. Drag it anywhere; it stays inside the safe area
and can remember where you left it.

**Capture.** Full screen, a cropped region, or a single window picked from a live
list. Captures land in a preview where you can annotate them, run text
recognition on them with Vision, or save them to Photos — automatically, if you
turn that on.

**Apps and shortcuts.** Browse and launch installed apps, see what is running in
Cmd-Tab order, and get per-app shortcut chips. Deck Hand reads the frontmost
app's menu bar over Accessibility, so the chips reflect that app's real
shortcuts instead of a hard-coded list.

**Context-aware actions.** When a dialog or sheet is up on the Mac, its buttons
appear on the remote as chips, so "Don't Save / Cancel / Save" is one tap away
instead of a trackpad trip across the screen.

**Media keys** for playback control round it out.

## Settings

The remote exposes the knobs that cost bandwidth or host CPU, deliberately as
manual controls rather than an automatic heuristic:

| Setting | Options |
| --- | --- |
| Mirror frame rate | 15 / 20 / 30 fps (the host clamps at 30) |
| Mirror sharpness | Auto (follows pinch size), Battery saver (640 px), Sharp (1920 px) |
| Screenshot quality | Standard, High, Native |
| Input send rate | 60 Hz, or 120 Hz to match ProMotion |
| Pointer sensitivity | Continuous |
| Natural scrolling | On / off |
| Haptics | Off / Light / Full, respected app-wide |
| Default capture action | Which capture the main button triggers |
| Auto-save to Photos | On / off |
| Appearance | System / light / dark |

Hidden apps can also be restored from here, and the first-run tour can be
replayed.

## How it works

The Mac advertises `_deckhand._tcp` over Bonjour and the remote browses for it.
`LoomKit` handles discovery, the direct connection, device identity, and the
trust decision. Every connection has to be approved on the Mac, and that approval
is deliberately not persisted — a fresh host launch prompts again, because
auto-granting from stored state proved too easy to get wrong.

Above the transport, both apps speak a single `Codable` enum, `ControlMessage`,
defined once in `DeckHand/Shared/` and compiled into both targets so the wire
format cannot drift between them. A few details worth knowing:

- **Liveness is proven at the protocol level.** Transport state lags badly after
  an abrupt kill — buffered streams, half-open TCP — so each side pings every two
  seconds and trusts only recent traffic. Miss the pongs and the remote returns
  to the picker rather than showing a session that is already dead.
- **The host advertises what it can actually do.** `hostCapabilities` reports
  whether Accessibility and Screen Recording are granted, so the remote can say
  the Mac is missing a permission instead of letting taps fail silently.
- **Optional fields decode with defaults**, which is how capture quality was
  added without breaking older builds.

The wire format has contract tests. If you change `ControlMessage`, run them.

## Requirements

- macOS 14 or later (host)
- iOS / iPadOS 17.4 or later (remote — built for iPhone and iPad)
- Xcode 16, Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and run

The Xcode project is generated and not checked in, so generate it first:

```bash
cd DeckHand
xcodegen generate
open DeckHand.xcodeproj
```

Both app targets use automatic signing and are pinned to the original author's
team, so set `DEVELOPMENT_TEAM` in `DeckHand/project.yml` to your own and
regenerate before building to a device. Bundle identifiers are `com.deckhand.mac`
and `com.deckhand.ios`.

From the command line:

```bash
xcodebuild -project DeckHand.xcodeproj -scheme DeckHandMac  -destination 'platform=macOS' build
xcodebuild -project DeckHand.xcodeproj -scheme DeckHandiOS  -destination 'generic/platform=iOS' build
xcodebuild -project DeckHand.xcodeproj -scheme DeckHandTests -destination 'platform=macOS' test
```

Launch the Mac app through Finder or LaunchServices rather than running the
built executable directly — see [the note below](#a-macos-26-gotcha).

Both platforms' app icons are regenerated from a single square master image. iOS
gets it full-bleed since the system masks it; macOS icons are pre-masked with the
squircle and Apple's grid margin baked in:

```bash
swift Scripts/make-app-icons.swift <master.png>
```

## Permissions

The Mac host needs these granted in System Settings before it is useful:

- **Accessibility** — required for pointer and keyboard injection, menu bar
  shortcut discovery, and dialog buttons.
- **Screen Recording** — required for captures and the live mirror.
- **Local Network** — required for discovery on both sides.

The remote asks for **Photos** access only when you save a capture.

Because permissions are keyed to the bundle identifier, changing it means
granting them again.

## A macOS 26 gotcha

Repeatedly launching a menu bar app's executable directly — as Xcode's Run button
does — can poison the bundle identifier's status item state on macOS 26, after
which the icon never appears again for that identifier, on that machine, with no
supported way to clear it. It looks exactly like a broken `MenuBarExtra`, which
sends you chasing the wrong bug.

The investigation and the fix are written up in
[DeckHand/MenuBarStatusItems-macOS26.md](DeckHand/MenuBarStatusItems-macOS26.md).
Worth reading before you debug a missing status item.

## Repository layout

```
DeckHand/
  DeckHandMac/     macOS host: capture, input injection, Accessibility, menu bar
  DeckHandiOS/     iPad/iPhone remote: trackpad, mirror, capture UI, settings
  Shared/          ControlMessage and every type that crosses the wire
  DeckHandTests/   Wire-format contract tests
  Scripts/         App icon generation
  project.yml      XcodeGen project definition
Sources/           The Loom Swift package
Tests/             Loom package tests
```

## The Loom package

This repository is a fork of [Loom](https://github.com/EthanLipnik/Loom) by Ethan
Lipnik, the Swift package Deck Hand is built on. Loom is product-agnostic
networking for Apple platforms: Bonjour discovery, direct `Network.framework`
sessions, stable device identity, pluggable trust, overlay-network support for
Tailscale-style setups, remote reachability, and diagnostics. It ships five
library products — `Loom`, `LoomKit`, `LoomShell`, `LoomCloudKit`, and
`LoomSharedRuntime`. Deck Hand uses `LoomKit`, the SwiftUI-first surface.

This fork does not track upstream closely and the package here has diverged: it
adds local-network diagnostics, a telemetry exporter, a SwiftUI diagnostics view,
a retry policy, and a Bonjour entitlement check, along with smaller changes to
logging, discovery, and session security.

The package still builds and tests independently of the apps:

```bash
swift build
swift test --scratch-path .build-local
```

Two tests in the package (`invalidResumeOffsetIsRejected` and
`liveSamePeerConnectionOutsideWindowIsDropped`) hang rather than fail. It is
pre-existing and unrelated to Deck Hand, but it will stall an unattended run, so
filter them out in CI.

If you came here for the networking library rather than this app, depend on
upstream instead of this fork:

```swift
.package(url: "https://github.com/EthanLipnik/Loom.git", from: "1.4.0")
```

Upstream is also the better reference for the package itself:

- [LoomKit documentation](https://ethanlipnik.github.io/Loom/documentation/loomkit/)
- [Loom documentation](https://ethanlipnik.github.io/Loom/documentation/loom/)
- [Architecture notes](Architecture.md)

Keep the boundary in mind when contributing: transport, trust, and diagnostics
belong in `Sources/`; anything that knows what Deck Hand is belongs in
`DeckHand/`.

## License

MIT, © Ethan Lipnik. See [LICENSE](LICENSE).
