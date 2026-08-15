//
//  AppShortcutsSheet.swift
//  DeckHandiOS
//
//  Bottom sheet that lists every shortcut bound to a specific macOS app,
//  lets the user trigger one with a tap, and manage (add / edit / delete)
//  custom bindings. Shown when the user taps any tile in StreamDeckGridView.
//

import SwiftUI
import UIKit

struct AppShortcutsSheet: View {
    let app: InstalledAppInfo
    let sender: TrackpadSender
    let onDismiss: () -> Void

    @ObservedObject private var store = ShortcutStore.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var editing: AppShortcutBinding?
    @State private var isAdding = false
    @State private var isImporting = false
    @State private var importBanner: String?

    private var bindings: [AppShortcutBinding] { store.bindings(for: app.bundleID) }

    /// Per-session expand/collapse state for category sections. Defaults are
    /// set lazily in `isExpanded(_:)` — system-ish categories (Window, Help,
    /// Apple) start collapsed, everything else expanded.
    @State private var expandedOverrides: [String: Bool] = [:]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    // MARK: - Sectioning

    /// Top-level menus that the user almost certainly doesn't care about by
    /// default — these come from macOS itself and appear in every app's
    /// menu bar. Start collapsed; expose a disclosure chevron so the user
    /// can still dig in when they want a window-tiling shortcut.
    private static let collapsedByDefault: Set<String> = [
        "Window", "Help", "Apple", "Services", "Edit"
    ]

    private struct Section: Identifiable {
        let id: String            // "" = "My Shortcuts"
        let title: String
        let bindings: [AppShortcutBinding]
        let collapsible: Bool
    }

    private var sections: [Section] {
        var uncategorized: [AppShortcutBinding] = []
        var grouped: [String: [AppShortcutBinding]] = [:]
        var insertionOrder: [String] = []

        for binding in bindings {
            if let category = binding.effectiveCategory {
                if grouped[category] == nil {
                    grouped[category] = []
                    insertionOrder.append(category)
                }
                grouped[category]!.append(binding)
            } else {
                uncategorized.append(binding)
            }
        }

        var result: [Section] = []
        if !uncategorized.isEmpty {
            result.append(Section(
                id: "",
                title: "My Shortcuts",
                bindings: uncategorized,
                collapsible: false
            ))
        }

        // App-specific menus (File, View, app name) first, then system menus.
        let sorted = insertionOrder.sorted { lhs, rhs in
            let lSystem = Self.collapsedByDefault.contains(lhs)
            let rSystem = Self.collapsedByDefault.contains(rhs)
            if lSystem != rSystem { return !lSystem }   // non-system first
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        for category in sorted {
            result.append(Section(
                id: category,
                title: category,
                bindings: grouped[category] ?? [],
                collapsible: true
            ))
        }
        return result
    }

    private func isExpanded(_ section: Section) -> Bool {
        if let override = expandedOverrides[section.id] { return override }
        return !Self.collapsedByDefault.contains(section.id)
    }

    private func toggle(_ section: Section) {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedOverrides[section.id] = !isExpanded(section)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeckHandTheme.canvasBackground(colorScheme).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                            .padding(.bottom, 18)

                        if bindings.isEmpty {
                            emptyState
                        } else {
                            ForEach(sections) { section in
                                sectionView(section)
                            }
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let banner = importBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(banner)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                        Spacer()
                    }
                    .foregroundStyle(DeckHandTheme.violet)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(DeckHandTheme.subtleWellFill(colorScheme))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onDismiss)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isAdding = true
                        } label: {
                            Label("New shortcut", systemImage: "plus")
                        }
                        Button {
                            importFromApp()
                        } label: {
                            Label("Import from \(app.displayName)", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isImporting)
                        if !CuratedShortcuts.bindings(for: app.bundleID).isEmpty,
                           (store.hiddenCuratedIDs[app.bundleID]?.isEmpty == false) {
                            Button {
                                store.restoreCurated(for: app.bundleID)
                            } label: {
                                Label("Restore built-in", systemImage: "arrow.counterclockwise")
                            }
                        }
                    } label: {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.system(size: 20))
                        }
                    }
                }
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appMenuShortcutsImported)) { note in
            guard let bundleID = note.userInfo?["bundleID"] as? String,
                  bundleID == app.bundleID else { return }
            let added = (note.userInfo?["added"] as? Int) ?? 0
            let total = (note.userInfo?["total"] as? Int) ?? 0
            isImporting = false
            withAnimation(.easeInOut(duration: 0.25)) {
                importBanner = messageForImport(added: added, total: total)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { importBanner = nil }
            }
        }
        .sheet(isPresented: $isAdding) {
            ShortcutEditor(bundleID: app.bundleID, existing: nil) { binding in
                store.addCustom(binding)
            }
        }
        .sheet(item: $editing) { binding in
            ShortcutEditor(bundleID: app.bundleID, existing: binding) { updated in
                store.updateCustom(updated)
            }
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        let expanded = isExpanded(section)
        let useShortNames = !section.id.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section, expanded: expanded)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            if expanded {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(section.bindings) { binding in
                        ShortcutCard(
                            binding: binding,
                            colorScheme: colorScheme,
                            useShortName: useShortNames,
                            onTap: { trigger(binding) },
                            onEdit: binding.isCurated ? nil : { editing = binding },
                            onDelete: { delete(binding) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: Section, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.secondary.opacity(0.85))
                .tracking(0.5)

            Text("\(section.bindings.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.primary.opacity(0.07))
                )

            Spacer()

            if section.collapsible {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .animation(.easeInOut(duration: 0.2), value: expanded)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard section.collapsible else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            toggle(section)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            appIcon
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                Text(bindings.isEmpty ? "No shortcuts yet" : "\(bindings.count) shortcut\(bindings.count == 1 ? "" : "s")")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let data = app.iconData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(DeckHandTheme.subtleWellFill(colorScheme))
                .overlay(Image(systemName: "app").foregroundStyle(.secondary))
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text("No shortcuts for \(app.displayName) yet.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.secondary)
            HStack(spacing: 10) {
                Button {
                    isAdding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.primary.opacity(0.08))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        )
                }
                Button {
                    importFromApp()
                } label: {
                    Label("Import from app", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(DeckHandTheme.violet.opacity(0.15))
                                .overlay(Capsule().strokeBorder(DeckHandTheme.violet.opacity(0.3), lineWidth: 1))
                        )
                        .foregroundStyle(DeckHandTheme.violet)
                }
                .disabled(isImporting)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)

            if !CuratedShortcuts.bindings(for: app.bundleID).isEmpty,
               (store.hiddenCuratedIDs[app.bundleID]?.isEmpty == false) {
                Button("Restore built-in shortcuts") {
                    store.restoreCurated(for: app.bundleID)
                }
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(DeckHandTheme.violet)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Actions

    private func trigger(_ binding: AppShortcutBinding) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            await sender.sendAppShortcut(bundleID: binding.bundleID, keys: binding.keys)
        }
    }

    private func delete(_ binding: AppShortcutBinding) {
        withAnimation(.easeInOut(duration: 0.2)) {
            store.delete(binding)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func importFromApp() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isImporting = true
        withAnimation(.easeInOut(duration: 0.25)) {
            importBanner = "Reading \(app.displayName)'s menu bar…"
        }
        Task { await sender.requestMenuShortcuts(bundleID: app.bundleID) }
    }

    private func messageForImport(added: Int, total: Int) -> String {
        if total == 0 {
            return "No shortcuts found. Make sure \(app.displayName) is installed and try again."
        }
        if added == 0 {
            return "Already up to date — \(total) shortcut\(total == 1 ? "" : "s") matched."
        }
        return "Imported \(added) new shortcut\(added == 1 ? "" : "s") from \(app.displayName)."
    }
}

// MARK: - Shortcut card

private struct ShortcutCard: View {
    let binding: AppShortcutBinding
    let colorScheme: ColorScheme
    /// When `true`, renders `binding.shortDisplayName` — strips the leading
    /// `Category › ` prefix because the category is already shown as the
    /// section header above the card.
    let useShortName: Bool
    let onTap: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: () -> Void

    @State private var isPressed = false

    private var label: String {
        useShortName ? binding.shortDisplayName : binding.displayName
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: binding.sfSymbol)
                    .font(.system(size: 15, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DeckHandTheme.violet)
                    .frame(width: 22, height: 22)

                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(binding.keyGlyphs)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DeckHandTheme.subtleWellFill(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
        .contextMenu {
            if let onEdit {
                Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(binding.isCurated ? "Hide" : "Delete",
                      systemImage: binding.isCurated ? "eye.slash" : "trash")
            }
        }
    }
}

// MARK: - Editor

struct ShortcutEditor: View {
    let bundleID: String
    let existing: AppShortcutBinding?
    let onSave: (AppShortcutBinding) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String = ""
    @State private var sfSymbol: String = "keyboard"
    @State private var keyLiteral: String = ""
    @State private var cmd: Bool = false
    @State private var shift: Bool = false
    @State private var option: Bool = false
    @State private var ctrl: Bool = false

    private var previewKeys: [String] {
        var keys: [String] = []
        if cmd { keys.append("cmd") }
        if shift { keys.append("shift") }
        if option { keys.append("option") }
        if ctrl { keys.append("ctrl") }
        if !keyLiteral.isEmpty { keys.append(keyLiteral.lowercased()) }
        return keys
    }

    private var previewBinding: AppShortcutBinding {
        AppShortcutBinding(
            id: existing?.id ?? UUID().uuidString,
            bundleID: bundleID,
            displayName: displayName.isEmpty ? "Shortcut" : displayName,
            keys: previewKeys,
            sfSymbol: sfSymbol.isEmpty ? "keyboard" : sfSymbol,
            isCurated: false
        )
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !keyLiteral.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Shortcut") {
                    TextField("Name", text: $displayName)
                        .textInputAutocapitalization(.words)
                    HStack {
                        TextField("SF Symbol", text: $sfSymbol)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Image(systemName: sfSymbol.isEmpty ? "keyboard" : sfSymbol)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Keys") {
                    Toggle("⌘ Command", isOn: $cmd)
                    Toggle("⇧ Shift", isOn: $shift)
                    Toggle("⌥ Option", isOn: $option)
                    Toggle("⌃ Control", isOn: $ctrl)
                    TextField("Key (e.g. p, space, f5, up)", text: $keyLiteral)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Preview") {
                    HStack {
                        Image(systemName: sfSymbol.isEmpty ? "keyboard" : sfSymbol)
                            .foregroundStyle(DeckHandTheme.violet)
                        Text(previewBinding.displayName)
                            .font(.system(.body, design: .rounded))
                        Spacer()
                        Text(previewBinding.keyGlyphs)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Shortcut" : "Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(previewBinding)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                guard let existing else { return }
                displayName = existing.displayName
                sfSymbol = existing.sfSymbol
                let mods = Set(existing.keys.map { $0.lowercased() })
                cmd    = mods.contains("cmd") || mods.contains("command")
                shift  = mods.contains("shift")
                option = mods.contains("option") || mods.contains("alt")
                ctrl   = mods.contains("ctrl") || mods.contains("control")
                keyLiteral = existing.keys.first {
                    let l = $0.lowercased()
                    return !["cmd", "command", "shift", "option", "alt", "ctrl", "control", "fn"].contains(l)
                } ?? ""
            }
        }
    }
}
