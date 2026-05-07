//
//  WindowPickerView.swift
//  MirageControliOS
//
//  Modal sheet that shows every visible Mac window from the latest
//  `windowListResponse` so the user can pick one to capture.
//
//  Layout: an adaptive `LazyVGrid` so wider devices (iPad, iPhone Pro Max
//  in landscape) see more cells per row and selection stays fast. Cells
//  show the owning app icon + app name + window title.
//
//  Order: most-recently-active first via the parent's `runningBundleIDs`
//  (Cmd+Tab order). Windows whose owning bundle isn't currently in the
//  Mac's running list fall to the end, sorted alphabetically by app name.
//
//  Tap routing: a `ButtonStyle` exposes press feedback, so we don't need a
//  competing `simultaneousGesture(DragGesture)` — that earlier approach
//  was eating taps inside the sheet, which is why the picker used to feel
//  unresponsive.
//

import SwiftUI
import UIKit

struct WindowPickerView: View {
    let windows: [WindowInfo]
    /// Cmd+Tab-ordered bundle IDs supplied by `RunningAppMonitor` via
    /// `ControlView`. Used purely for sorting; not displayed.
    let runningBundleIDs: [String]
    let isLoading: Bool
    let onPick: (WindowInfo) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)
    ]

    private var orderedWindows: [WindowInfo] {
        // Build a rank table from `runningBundleIDs`. Lower index = more
        // recent. Bundles not present rank at `Int.max` so they sort to
        // the end, keeping a stable secondary order by app name + title.
        let rankByBundle: [String: Int] = Dictionary(
            uniqueKeysWithValues: runningBundleIDs.enumerated().map { ($1, $0) }
        )
        return windows.sorted { lhs, rhs in
            let lRank = lhs.bundleID.flatMap { rankByBundle[$0] } ?? .max
            let rRank = rhs.bundleID.flatMap { rankByBundle[$0] } ?? .max
            if lRank != rRank { return lRank < rRank }
            let appCompare = lhs.appName.localizedCaseInsensitiveCompare(rhs.appName)
            if appCompare != .orderedSame {
                return appCompare == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
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
                    grid
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(orderedWindows) { window in
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onPick(window)
                    } label: {
                        WindowCell(window: window, colorScheme: colorScheme)
                    }
                    .buttonStyle(WindowCellButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
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

// MARK: - Cell

private struct WindowCell: View {
    let window: WindowInfo
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            icon
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

            Text(window.appName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(window.title)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MirageTheme.subtleWellFill(colorScheme).opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let data = window.appIconData, let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MirageTheme.subtleWellFill(colorScheme))
                .overlay(
                    Image(systemName: "macwindow")
                        .font(.system(size: 24, weight: .thin))
                        .foregroundStyle(Color.primary.opacity(0.4))
                )
        }
    }
}

// MARK: - Button style
//
// Press feedback via `ButtonStyleConfiguration.isPressed` so we can drop the
// previous `simultaneousGesture(DragGesture(minimumDistance: 0))` hack.
// That hack was the reason taps weren't reaching `onPick` — it intercepted
// the sheet's gesture pipeline and either swallowed the press or blocked
// the scroll, depending on platform.

private struct WindowCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
