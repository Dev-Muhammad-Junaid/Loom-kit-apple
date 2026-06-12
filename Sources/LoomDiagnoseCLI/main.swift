//
//  main.swift
//  loom-diagnose
//
//  CLI diagnostics tool for Loom (WID-345): connectivity checks, peer
//  probing, and configuration auditing from the terminal — no app build
//  required. Dependency-free by design (hand-rolled argument parsing) so
//  it adds nothing to the package's dependency graph.
//
//  Usage:
//    loom-diagnose doctor --service <type> [--plist <path/to/Info.plist>]
//        Audits local-network configuration. With --plist it checks an
//        app's Info.plist (handy in CI); without it, it checks the
//        current process and notes that non-bundled executables are
//        exempt from the plist requirements.
//
//    loom-diagnose discover --service <type> [--seconds <n>] [--no-p2p]
//        Browses Bonjour for Loom peers and prints what it finds —
//        verifies advertising hosts, mDNS health, and network reachability
//        in one shot.
//

import Foundation
import Loom

// MARK: - Argument parsing

struct Arguments {
    let command: String?
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var rest = raw.dropFirst() // executable path
        command = rest.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
        if command != nil { rest = rest.dropFirst() }

        var iterator = rest.makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("--") else { continue }
            let name = String(token.dropFirst(2))
            // Flag-style options have no value; peek by convention:
            // known boolean flags are listed here.
            if ["no-p2p", "help", "json"].contains(name) {
                flags.insert(name)
            } else if let value = iterator.next() {
                options[name] = value
            }
        }
    }

    func option(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
}

func printUsage() {
    print(
        """
        loom-diagnose — Loom connectivity & configuration diagnostics

        COMMANDS
          doctor    --service <type> [--plist <path>]
                    Audit local-network configuration (NSBonjourServices,
                    NSLocalNetworkUsageDescription) for a service type.

          discover  --service <type> [--seconds <n>] [--no-p2p]
                    Browse Bonjour for Loom peers and print discoveries.

        EXAMPLES
          loom-diagnose doctor --service _miragecontrol._tcp --plist ./MyApp/Info.plist
          loom-diagnose discover --service _miragecontrol._tcp --seconds 10
        """
    )
}

// MARK: - doctor

func runDoctor(_ args: Arguments) -> Int32 {
    guard let serviceType = args.option("service") else {
        print("error: doctor requires --service <type> (e.g. _miragecontrol._tcp)")
        return 64 // EX_USAGE
    }

    let findings: [LoomLocalNetworkDiagnostics.Finding]
    if let plistPath = args.option("plist") {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any]
        else {
            print("error: couldn't read a plist dictionary at \(plistPath)")
            return 66 // EX_NOINPUT
        }
        findings = LoomLocalNetworkDiagnostics.evaluate(serviceType: serviceType, infoDictionary: info)
        print("Auditing \(plistPath) for service type \(serviceType):")
    } else if Bundle.main.bundleIdentifier == nil {
        print(
            """
            This is a non-bundled executable — macOS doesn't require \
            NSBonjourServices/NSLocalNetworkUsageDescription for it.
            To audit an app's configuration, pass --plist <path/to/Info.plist>.
            """
        )
        return 0
    } else {
        findings = LoomLocalNetworkDiagnostics.evaluate(serviceType: serviceType)
        print("Auditing \(Bundle.main.bundleIdentifier ?? "current bundle") for service type \(serviceType):")
    }

    if findings.isEmpty {
        print("  ✓ Configuration looks correct.")
        return 0
    }
    for finding in findings {
        print("  ✗ \(finding.summary)")
        print("    → \(finding.remediation)")
    }
    return 1
}

// MARK: - discover

@MainActor
func runDiscover(_ args: Arguments) async -> Int32 {
    guard let serviceType = args.option("service") else {
        print("error: discover requires --service <type> (e.g. _miragecontrol._tcp)")
        return 64
    }
    let seconds = args.option("seconds").flatMap(UInt64.init) ?? 8
    let enableP2P = !args.flag("no-p2p")

    print("Browsing \(serviceType) for \(seconds)s (peer-to-peer: \(enableP2P ? "on" : "off"))…")

    let discovery = LoomDiscovery(serviceType: serviceType, enablePeerToPeer: enableP2P)
    var seen = Set<LoomPeerID>()
    discovery.onPeersChanged = { peers in
        for peer in peers where !seen.contains(peer.id) {
            seen.insert(peer.id)
            print("  + \(peer.name) [\(peer.deviceType)] id=\(peer.id)")
        }
    }
    discovery.startDiscovery()

    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)

    let peers = discovery.discoveredPeers
    discovery.stopDiscovery()

    if peers.isEmpty {
        print(
            """
              No peers found. Checklist:
              • Is a Loom host advertising \(serviceType) on this network?
              • Same Wi-Fi / subnet? mDNS doesn't cross most VLANs.
              • macOS: System Settings > Privacy & Security > Local Network.
            """
        )
        return 1
    }
    print("Done — \(peers.count) peer(s) visible.")
    return 0
}

// MARK: - entry

let args = Arguments(CommandLine.arguments)

switch args.command {
case "doctor":
    exit(runDoctor(args))
case "discover":
    // Top-level code is MainActor-isolated, matching LoomDiscovery's
    // isolation; NWBrowser's main-queue callbacks are serviced while the
    // sleep suspends.
    let code = await runDiscover(args)
    exit(code)
default:
    printUsage()
    exit(args.command == nil || args.flag("help") ? 0 : 64)
}
