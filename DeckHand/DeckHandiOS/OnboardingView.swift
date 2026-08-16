//
//  OnboardingView.swift
//  DeckHandiOS
//
//  First-run walkthrough. Four pages: what the app is, then the three things
//  it does, ending on what the user has to do on the Mac before any of it
//  works. Shown once, then never again unless settings are reset.
//

import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private var pages: [OnboardingPage] { OnboardingPage.all }

    var body: some View {
        ZStack {
            DeckHandTheme.brandBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                skipButton

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                        OnboardingPageView(page: item)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageIndicator
                    .padding(.bottom, 28)

                continueButton
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var skipButton: some View {
        HStack {
            Spacer()
            Button("Skip") { onFinish() }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 24)
                .padding(.top, 12)
                // Hidden rather than removed on the last page so the header
                // doesn't change height under the content.
                .opacity(page == pages.count - 1 ? 0 : 1)
                .disabled(page == pages.count - 1)
                .animation(.easeOut(duration: 0.18), value: page)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? DeckHandTheme.Brand.glow : Color.white.opacity(0.22))
                    .frame(width: index == page ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.16), value: page)
        .accessibilityHidden(true)
    }

    private var continueButton: some View {
        Button {
            if page < pages.count - 1 {
                withAnimation(.easeOut(duration: 0.26)) { page += 1 }
            } else {
                onFinish()
            }
        } label: {
            Text(page == pages.count - 1 ? "Get Started" : "Continue")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: DeckHandTheme.Radius.lg, style: .continuous)
                        .fill(DeckHandTheme.Brand.litTileGradient)
                )
                .shadow(color: DeckHandTheme.Brand.glow.opacity(0.45), radius: 18, y: 6)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Page model

struct OnboardingPage: Identifiable {
    let id = UUID()
    /// `nil` on the first page, which shows the app mark instead of a symbol.
    let symbol: String?
    let title: String
    let body: String
    /// Short supporting lines rendered as a checklist. Empty on most pages.
    let bullets: [String]

    static let all: [OnboardingPage] = [
        OnboardingPage(
            symbol: nil,
            title: "Deck Hand",
            body: "Your iPad becomes a trackpad, a second view of your Mac, and a capture tool — over your own Wi-Fi, with nothing in between.",
            bullets: []
        ),
        OnboardingPage(
            symbol: "hand.point.up.left",
            title: "A real trackpad",
            body: "Move, click, and scroll with the same gestures you already use. Sensitivity, haptics, and scroll direction are all yours to set.",
            bullets: [
                "Two fingers to scroll",
                "Three fingers to switch spaces",
                "Press and hold to right-click",
            ]
        ),
        OnboardingPage(
            symbol: "rectangle.on.rectangle",
            title: "Watch your Mac",
            body: "Pin a live view of the Mac screen anywhere on the iPad. Pinch it larger when you need to read, drop it back to a corner when you don't.",
            bullets: [
                "Drag it anywhere",
                "Pinch to resize",
                "Sharpens as it grows",
            ]
        ),
        OnboardingPage(
            symbol: "camera.viewfinder",
            title: "Capture and mark up",
            body: "Pull a screenshot from the Mac, crop it, annotate it, or lift the text out of it — then save or share it from the iPad.",
            bullets: [
                "Full screen, region, or window",
                "Annotate before you send",
                "Recognize text in place",
            ]
        ),
        OnboardingPage(
            symbol: "wifi",
            title: "One thing on the Mac",
            body: "Open Deck Hand on your Mac and keep both devices on the same Wi-Fi. The first time you connect, the Mac asks you to approve this iPad.",
            bullets: [
                "Same Wi-Fi network",
                "Deck Hand running on the Mac",
                "Approve the iPad once",
            ]
        ),
    ]
}

// MARK: - Page

private struct OnboardingPageView: View {
    let page: OnboardingPage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            artwork
                .padding(.bottom, 44)

            VStack(spacing: 14) {
                Text(page.title)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(page.body)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 460)
            }
            .padding(.horizontal, 32)
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 10)

            if !page.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(page.bullets.enumerated()), id: \.offset) { index, bullet in
                        HStack(spacing: 11) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(DeckHandTheme.Brand.mint)
                                .frame(width: 18, height: 18)
                                .background(
                                    Circle().fill(DeckHandTheme.Brand.mint.opacity(0.14))
                                )
                            Text(bullet)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 8)
                        .animation(
                            reduceMotion
                                ? .easeOut(duration: 0.2)
                                : .easeOut(duration: 0.32).delay(0.16 + Double(index) * 0.06),
                            value: revealed
                        )
                    }
                }
                .padding(.top, 30)
            }

            Spacer(minLength: 24)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.34).delay(0.06),
            value: revealed
        )
        .onAppear { revealed = true }
        .onDisappear { revealed = false }
    }

    @ViewBuilder
    private var artwork: some View {
        if let symbol = page.symbol {
            ZStack {
                Circle()
                    .fill(DeckHandTheme.Brand.glow.opacity(0.14))
                    .frame(width: 148, height: 148)
                    .blur(radius: 18)

                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(DeckHandTheme.Brand.unlitTileGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 40, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .frame(width: 136, height: 136)
                    .shadow(color: DeckHandTheme.Brand.glow.opacity(0.35), radius: 26)

                Image(systemName: symbol)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(DeckHandTheme.Brand.litTileGradient)
            }
            .scaleEffect(revealed ? 1 : 0.92)
            .opacity(revealed ? 1 : 0)
        } else {
            DeckHandMark(size: 172)
        }
    }
}

// MARK: - Button style

/// Press feedback for the primary calls to action. Subtle scale, quick
/// release — the button should feel like it heard the tap immediately.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
