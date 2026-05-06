//
//  WindowPickerView.swift
//  MirageControliOS
//
//  Modal sheet that lists every visible Mac window (from the latest
//  `windowListResponse`) so the user can pick a single one to capture.
//  Grouped by app for quick scanning; Cmd-Tab order is implicit through
//  the parent's `runningBundleIDs` if we ever want to surface it later.
//

import SwiftUI
import UIKit

struct WindowPickerView: View {
    let windows: [WindowInfo]
    let isLoading: Bool
    let onPick: (WindowInfo) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    // Group windows by their owning app for a calmer list.
    private var grouped: [(app: String, items: [WindowInfo])] {
        let dict = Dictionary(grouping: windows, by: \.appName)
        return dict
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MirageTheme.canvasBackground(colorScheme).ignoresSafeArea()

                if isLoading && windows.isEmpty {
                    MirageLoadingStateView(title: "Reading windows from Mac…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if windows.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Capture Window")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onRefresh()
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isLoading)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(grouped, id: \.app) { group in
                    sectionHeader(group.app)
                    ForEach(group.items) { window in
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onPick(window)
                        } label: {
                            WindowRow(window: window, colorScheme: colorScheme)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.secondary.opacity(0.85))
            .tracking(0.5)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text("No windows visible.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.secondary)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(MirageTheme.violet.opacity(0.18))
                    )
                    .foregroundStyle(MirageTheme.violet)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct WindowRow: View {
    let window: WindowInfo
    let colorScheme: ColorScheme

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(window.appName)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MirageTheme.subtleWellFill(colorScheme).opacity(isPressed ? 0.9 : 0.45))
                .padding(.horizontal, 14)
        )
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let data = window.appIconData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MirageTheme.subtleWellFill(colorScheme))
                .overlay(Image(systemName: "macwindow").foregroundStyle(.secondary))
        }
    }
}
