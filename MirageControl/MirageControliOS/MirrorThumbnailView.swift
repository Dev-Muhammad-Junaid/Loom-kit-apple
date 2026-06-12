//
//  MirrorThumbnailView.swift
//  MirageControliOS
//
//  Floating live-mirror thumbnail (WID-403). Renders the latest frame the
//  Mac streamed, draggable anywhere over the control surface, with two
//  sizes (tap to toggle) and a close affordance.
//
//  The view is intentionally dumb: frame decode, sequencing, and the
//  start/stop protocol all live in `ControlView`, which owns the single
//  host-message loop. This just shows whatever `image` it's handed.
//

import SwiftUI

struct MirrorThumbnailView: View {
    let image: UIImage?
    let onClose: () -> Void
    /// Fired when the user toggles between the compact and expanded size,
    /// so the host stream can be re-negotiated at a matching resolution.
    var onExpansionChanged: (Bool) -> Void = { _ in }

    /// Persisted drag offset (committed at drag end) + live in-drag delta.
    @State private var committedOffset: CGSize = .zero
    @GestureState private var dragDelta: CGSize = .zero
    @State private var isExpanded = false

    private var width: CGFloat { isExpanded ? 340 : 200 }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // First frame hasn't landed yet.
                ZStack {
                    Rectangle().fill(.black.opacity(0.85))
                    ProgressView()
                        .tint(.white)
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
            }
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .padding(4)
            .accessibilityLabel("Close live mirror")
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .offset(
            x: committedOffset.width + dragDelta.width,
            y: committedOffset.height + dragDelta.height
        )
        .gesture(
            DragGesture()
                .updating($dragDelta) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    committedOffset.width += value.translation.width
                    committedOffset.height += value.translation.height
                }
        )
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            onExpansionChanged(isExpanded)
        }
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .accessibilityLabel("Live mirror of the Mac screen")
        .accessibilityHint("Drag to move. Tap to resize.")
    }
}
