//
//  MirageLoadingStateView.swift
//  MirageControliOS
//

import SwiftUI

/// Shared progress + copy for in-app loading and empty states (picker, control shell, apps grid, screenshot capture).
struct MirageLoadingStateView: View {
    let title: String
    var subtitle: String?
    var verticalPadding: CGFloat = 60
    var progressScale: CGFloat = 1.22
    var progressTint: Color = MirageTheme.violet
    var titleColor: Color = .secondary
    var subtitleColor: Color?

    var body: some View {
        VStack(spacing: subtitle == nil ? 14 : 10) {
            ProgressView()
                .scaleEffect(progressScale)
                .tint(progressTint)
            Text(title)
                .font(MirageTheme.TypeStyle.loadingTitle)
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(MirageTheme.TypeStyle.captionRounded)
                    .foregroundStyle(subtitleColor ?? titleColor.opacity(0.88))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, verticalPadding)
    }
}
