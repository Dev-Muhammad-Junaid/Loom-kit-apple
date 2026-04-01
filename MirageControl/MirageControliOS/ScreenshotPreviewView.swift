//
//  ScreenshotPreviewView.swift
//  MirageControliOS
//

import Photos
import SwiftUI
import UIKit

struct ScreenshotPreviewView: View {
    let image: UIImage
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showShareSheet = false
    @State private var toastMessage: String?
    @State private var imageScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    @State private var isSaving = false
    @State private var toastTask: Task<Void, Never>?
    @State private var showAnnotationView = false
    // Holds the annotated version once the user finishes annotating;
    // all Save/Copy/Share actions use this instead of the original.
    @State private var annotatedImage: UIImage?

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background
            Color.black.ignoresSafeArea()

            // Zoomable image — shows annotated version if one exists
            GeometryReader { geo in
                Image(uiImage: annotatedImage ?? image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(imageScale)
                    .offset(imageOffset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                imageScale = max(1.0, lastScale * val)
                            }
                            .onEnded { _ in
                                lastScale = imageScale
                                if imageScale < 1.0 {
                                    withAnimation(.spring()) { imageScale = 1.0; imageOffset = .zero }
                                    lastScale = 1.0; lastOffset = .zero
                                }
                            }
                        .simultaneously(with:
                            DragGesture()
                                .onChanged { val in
                                    guard imageScale > 1.01 else { return }
                                    imageOffset = CGSize(
                                        width: lastOffset.width + val.translation.width,
                                        height: lastOffset.height + val.translation.height
                                    )
                                }
                                .onEnded { _ in lastOffset = imageOffset }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.3)) {
                            if imageScale > 1.01 {
                                imageScale = 1.0; imageOffset = .zero
                                lastScale = 1.0; lastOffset = .zero
                            } else {
                                imageScale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
            }
            .ignoresSafeArea()

            // Top bar
            VStack {
                HStack {
                    // Mac display dimensions badge
                    Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.1)))

                    if annotatedImage != nil {
                        Text("Annotated")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.yellow.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.yellow.opacity(0.18)))
                    }

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()
            }

            // Bottom action bar
            VStack(spacing: 0) {
                // Toast
                if let toast = toastMessage {
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(.white.opacity(0.18))
                        )
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Action row
                HStack(spacing: 0) {
                    ActionButton(
                        icon: "square.and.arrow.down",
                        label: "Save",
                        color: .white,
                        isLoading: isSaving
                    ) {
                        toastTask?.cancel()
                        toastTask = Task { await saveToPhotos() }
                    }

                    ActionButton(
                        icon: "doc.on.doc",
                        label: "Copy",
                        color: .white
                    ) {
                        UIPasteboard.general.image = image
                        toastTask?.cancel()
                        toastTask = Task { await showToast("Copied to Clipboard") }
                    }

                    ActionButton(
                        icon: "square.and.arrow.up",
                        label: "Share",
                        color: .white
                    ) {
                        showShareSheet = true
                    }

                    ActionButton(
                        icon: "pencil.tip",
                        label: "Annotate",
                        color: .white
                    ) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showAnnotationView = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.9))
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [annotatedImage ?? image])
        }
        .fullScreenCover(isPresented: $showAnnotationView) {
            AnnotationView(image: annotatedImage ?? image) { result in
                showAnnotationView = false
                if let annotated = result {
                    // Reset zoom so the new annotated image fits cleanly
                    withAnimation(.spring(response: 0.3)) {
                        annotatedImage = annotated
                        imageScale = 1.0
                        imageOffset = .zero
                        lastScale = 1.0
                        lastOffset = .zero
                    }
                    toastTask?.cancel()
                    toastTask = Task { await showToast("Annotation applied") }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: toastMessage)
        .onDisappear {
            // Cancel any in-flight toast timer so it doesn't fire against a deallocated view
            toastTask?.cancel()
        }
    }

    // MARK: - Actions

    @MainActor
    private func saveToPhotos() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        // Exit immediately if the view was dismissed before we started
        guard !Task.isCancelled else { return }

        // Request authorization using the modern async API
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            await showToast("Photos permission denied")
            return
        }

        // Use the annotated version if one exists, otherwise the original.
        // Convert to Data (Sendable) before crossing the @Sendable closure boundary.
        let imageToSave = annotatedImage ?? image
        guard let imgData = imageToSave.jpegData(compressionQuality: 0.92) else {
            await showToast("Save failed: could not encode image")
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges({ @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imgData, options: nil)
            })
            await showToast("Saved to Photos ✓")
        } catch {
            await showToast("Save failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func showToast(_ message: String) async {
        withAnimation { toastMessage = message }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation { toastMessage = nil }
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    let icon: String
    let label: String
    let color: Color
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: {
            guard !isLoading else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .tint(color.opacity(0.85))
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .thin))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(color.opacity(isPressed ? 1.0 : 0.85))
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(color.opacity(isLoading ? 0.4 : 0.65))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isPressed ? Color.white.opacity(0.1) : Color.clear)
            )
            .scaleEffect(isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - UIActivityViewController wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
