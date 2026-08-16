//
//  SettingsView.swift
//  DeckHandiOS
//
//  The remote's preferences. Grouped so the two costly sections — mirror and
//  pointer — read as the ones worth touching, with footers that say what a
//  choice actually costs rather than just what it does.
//
//  Segmented controls carry their own titles: a `Picker` in a `Form` drops
//  its label under `.segmented`, which leaves bare options like "Off / Light
//  / Full" floating with nothing to say what they belong to.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: DeckHandSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                mirrorSection
                pointerSection
                captureSection
                appearanceSection
                connectionSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Applied here as well as at the app root: a sheet gets its own
        // presentation host, so without this the appearance change wouldn't
        // reach the very screen you changed it on until it was reopened.
        .preferredColorScheme(settings.appearance.colorScheme)
    }

    // MARK: - Live mirror

    private var mirrorSection: some View {
        Section {
            Picker("Sharpness", selection: $settings.mirrorSharpness) {
                ForEach(MirrorSharpness.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Text(settings.mirrorSharpness.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            SettingBlock("Frame rate") {
                Picker("Frame rate", selection: $settings.mirrorFrameRate) {
                    ForEach(MirrorFrameRate.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Remember size and position", isOn: $settings.rememberMirrorLayout)
        } header: {
            Text("Live mirror")
        } footer: {
            Text("Sharpness and frame rate together decide how much of your network the mirror uses. Drop both if the picture stutters before you blame the Mac.")
        }
    }

    // MARK: - Pointer

    private var pointerSection: some View {
        Section {
            SettingBlock("Sensitivity", value: TrackpadSensitivity.label(for: settings.pointerSensitivity)) {
                Slider(
                    value: Binding(
                        get: { Double(TrackpadSensitivity.nearestIndex(to: settings.pointerSensitivity)) },
                        set: { settings.pointerSensitivity = TrackpadSensitivity.anchors[Int($0.rounded())] }
                    ),
                    in: TrackpadSensitivity.indexRange,
                    step: 1
                )
                .accessibilityLabel("Pointer sensitivity")
                .accessibilityValue(TrackpadSensitivity.label(for: settings.pointerSensitivity))
            }

            SettingBlock("Haptics", caption: "Taps and gestures buzz the iPad.") {
                Picker("Haptics", selection: $settings.hapticStrength) {
                    ForEach(HapticStrength.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Natural scrolling", isOn: $settings.naturalScrolling)

            SettingBlock("Send rate", caption: "How often touches are sent to the Mac.") {
                Picker("Send rate", selection: $settings.inputSendRate) {
                    ForEach(InputSendRate.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } header: {
            Text("Pointer and gestures")
        } footer: {
            Text("Natural scrolling moves the content with your fingers. 120 Hz matches ProMotion so no touch is discarded; 60 Hz halves the packets if the pointer feels erratic on a busy network.")
        }
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            Picker("Capture button", selection: $settings.defaultCapture) {
                ForEach(DefaultCapture.allCases) { option in
                    Label(option.label, systemImage: option.icon).tag(option)
                }
            }

            SettingBlock("Quality", caption: settings.screenshotQuality.detail) {
                Picker("Quality", selection: $settings.screenshotQuality) {
                    ForEach(CaptureQuality.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("Save to Photos automatically", isOn: $settings.autoSaveToPhotos)
        } header: {
            Text("Screenshots")
        } footer: {
            Text("Quality applies to full-screen captures. Region and window captures already ship at close to native resolution. Saving automatically asks for Photos access the first time a capture lands.")
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            SettingBlock("Theme") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Applies to the control screens. The device picker stays dark to match the app icon.")
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            UnavailableRow(
                title: "Recognize my own devices",
                detail: "Macs on your iCloud account would connect without the approval prompt."
            )
        } header: {
            Text("Connection")
        } footer: {
            Text("The code path for this exists on both sides; switching it on needs a CloudKit container registered to a paid developer account.")
        }
    }

}

// MARK: - Building blocks

/// A titled control. Segmented pickers and sliders lose their `Picker` label
/// inside a `Form`, so the title is drawn explicitly above the control.
private struct SettingBlock<Content: View>: View {
    let title: String
    var value: String?
    var caption: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        value: String? = nil,
        caption: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.value = value
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                if let value {
                    Spacer()
                    Text(value)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            content
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A setting that is deliberately visible but not wired up yet. Rendered as
/// inert text rather than a disabled control, so it can't read as a toggle
/// that simply failed to respond.
private struct UnavailableRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Not available")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.14))
                    )
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). Not available. \(detail)")
    }
}
