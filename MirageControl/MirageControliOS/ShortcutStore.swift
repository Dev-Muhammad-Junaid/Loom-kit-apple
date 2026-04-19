//
//  ShortcutStore.swift
//  MirageControliOS
//

import Foundation
import Combine

/// Persists user-authored `AppShortcutBinding`s and hidden curated presets,
/// keyed by bundleID. Single-source-of-truth for the Apps-tab shortcut sheet.
///
/// The model is intentionally lightweight — everything lives in `UserDefaults`
/// (same device, no sync) until we want iCloud sync, which is a 20-line swap
/// to `NSUbiquitousKeyValueStore` later.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var customBindings: [String: [AppShortcutBinding]] = [:]
    @Published private(set) var hiddenCuratedIDs: [String: Set<String>] = [:]

    private let defaults: UserDefaults
    private let customKey = "customShortcuts.v1"
    private let hiddenKey = "hiddenCuratedShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reads

    /// All bindings (curated + custom minus hidden) to show for `bundleID`.
    /// Curated come first, then user-added in insertion order.
    func bindings(for bundleID: String) -> [AppShortcutBinding] {
        let hidden = hiddenCuratedIDs[bundleID] ?? []
        let curated = CuratedShortcuts.bindings(for: bundleID)
            .filter { !hidden.contains($0.id) }
        let custom = customBindings[bundleID] ?? []
        return curated + custom
    }

    /// Does this app have any visible shortcuts (curated or custom)?
    func hasShortcuts(for bundleID: String) -> Bool {
        !bindings(for: bundleID).isEmpty
    }

    // MARK: - Writes

    func addCustom(_ binding: AppShortcutBinding) {
        var bucket = customBindings[binding.bundleID] ?? []
        bucket.append(binding)
        customBindings[binding.bundleID] = bucket
        persist()
    }

    func updateCustom(_ binding: AppShortcutBinding) {
        guard var bucket = customBindings[binding.bundleID] else { return }
        guard let idx = bucket.firstIndex(where: { $0.id == binding.id }) else { return }
        bucket[idx] = binding
        customBindings[binding.bundleID] = bucket
        persist()
    }

    /// Deletes a custom binding; hides a curated one (curated are immutable so
    /// the user can always get them back by calling `restoreCurated`).
    func delete(_ binding: AppShortcutBinding) {
        if binding.isCurated {
            var hidden = hiddenCuratedIDs[binding.bundleID] ?? []
            hidden.insert(binding.id)
            hiddenCuratedIDs[binding.bundleID] = hidden
        } else {
            var bucket = customBindings[binding.bundleID] ?? []
            bucket.removeAll { $0.id == binding.id }
            customBindings[binding.bundleID] = bucket.isEmpty ? nil : bucket
        }
        persist()
    }

    /// Re-reveals all curated bindings for `bundleID`.
    func restoreCurated(for bundleID: String) {
        hiddenCuratedIDs[bundleID] = nil
        persist()
    }

    /// Merges AX-discovered bindings into the user's custom list for
    /// `bundleID`. Dedupe is done by deterministic `id` (so re-importing is
    /// idempotent) *and* by display-name + key combo (so an imported "File ›
    /// New Tab ⌘T" doesn't stack on top of a curated "New Tab ⌘T").
    ///
    /// Returns the number of truly new bindings that were added.
    @discardableResult
    func importBindings(_ incoming: [AppShortcutBinding], for bundleID: String) -> Int {
        guard !incoming.isEmpty else { return 0 }
        var bucket = customBindings[bundleID] ?? []
        let curated = CuratedShortcuts.bindings(for: bundleID)

        func fingerprint(_ b: AppShortcutBinding) -> String {
            "\(b.displayName.lowercased())|\(b.keys.map { $0.lowercased() }.joined(separator: "+"))"
        }
        var seen = Set<String>(bucket.map(fingerprint))
        seen.formUnion(curated.map(fingerprint))
        var seenIDs = Set(bucket.map(\.id))

        var added = 0
        for binding in incoming {
            let fp = fingerprint(binding)
            guard !seen.contains(fp), !seenIDs.contains(binding.id) else { continue }
            seen.insert(fp)
            seenIDs.insert(binding.id)
            bucket.append(binding)
            added += 1
        }

        if added > 0 {
            customBindings[bundleID] = bucket
            persist()
        }
        return added
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: customKey),
           let decoded = try? JSONDecoder().decode([String: [AppShortcutBinding]].self, from: data) {
            customBindings = decoded
        }
        if let data = defaults.data(forKey: hiddenKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            hiddenCuratedIDs = decoded.mapValues { Set($0) }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customBindings) {
            defaults.set(data, forKey: customKey)
        }
        let serializable = hiddenCuratedIDs.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(serializable) {
            defaults.set(data, forKey: hiddenKey)
        }
    }
}
