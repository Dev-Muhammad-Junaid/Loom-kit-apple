//
//  OCRResultView.swift
//  DeckHandiOS
//
//  On-device OCR of whatever screenshot the user just captured (full
//  screen, region, or window). We use `VNRecognizeTextRequest` so no
//  Mac round-trip is needed — the iPad already has the JPEG, and Vision
//  runs the recognizer on-device.
//
//  This is intentionally separate from `ScreenshotPreviewView`'s
//  Annotate/Save/Share flow. OCR is a different intent: the user wants
//  *text*, not a picture, so we surface the recognized text in a
//  scrollable/copyable sheet with a "Copy All" affordance up top.
//

import SwiftUI
import UIKit
@preconcurrency import Vision

struct OCRResultView: View {
    let image: UIImage
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var state: RecognitionState = .recognizing
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    enum RecognitionState {
        case recognizing
        case ready(text: String, lineCount: Int)
        case empty
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DeckHandTheme.canvasBackground(colorScheme).ignoresSafeArea()

                content
            }
            .navigationTitle("Recognized Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: onDismiss)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if case let .ready(text, _) = state {
                        Button {
                            UIPasteboard.general.string = text
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showToast("Copied to Clipboard")
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                        }
                    }
                }
            }
            .task { await runRecognition() }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(DeckHandTheme.violet.opacity(0.9)))
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: toastMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .recognizing:
            DeckHandLoadingStateView(title: "Reading text from screenshot…")
        case let .ready(text, lineCount):
            VStack(alignment: .leading, spacing: 0) {
                summaryBar(lineCount: lineCount, characterCount: text.count)

                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(20)
                }
            }
        case .empty:
            VStack(spacing: 14) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 42, weight: .thin))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                Text("No text recognized in this image.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 38, weight: .thin))
                    .foregroundStyle(Color.orange)
                Text("OCR failed")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(message)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summaryBar(lineCount: Int, characterCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.secondary)
            Text("\(lineCount) line\(lineCount == 1 ? "" : "s") · \(characterCount) chars")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DeckHandTheme.subtleWellFill(colorScheme))
    }

    @MainActor
    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation { toastMessage = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - Vision

    private func runRecognition() async {
        guard let cgImage = image.cgImage else {
            await update(.failed("Could not access image data."))
            return
        }
        let result: RecognitionState = await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return .failed(error.localizedDescription)
            }
            guard let observations = request.results, !observations.isEmpty else {
                return .empty
            }

            var lines: [String] = []
            lines.reserveCapacity(observations.count)
            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    lines.append(candidate.string)
                }
            }
            let joined = lines.joined(separator: "\n")
            return joined.isEmpty
                ? .empty
                : .ready(text: joined, lineCount: lines.count)
        }.value

        await update(result)
    }

    @MainActor
    private func update(_ next: RecognitionState) {
        withAnimation(.easeInOut(duration: 0.2)) {
            state = next
        }
    }
}
