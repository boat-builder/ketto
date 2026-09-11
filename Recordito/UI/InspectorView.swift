import SwiftUI

/// Minimal v1 inspector: background, frame, cursor, zoom and effects. Every control writes straight into
/// `session.edit`, which rebuilds the composer and autosaves.
struct InspectorView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        Form {
            backgroundSection
            frameSection
            cursorSection
            zoomSection
            effectsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Background

    private var backgroundSection: some View {
        Section("Background") {
            Picker("Style", selection: backgroundType) {
                Text("Solid").tag(BackgroundType.solid)
                Text("Gradient").tag(BackgroundType.gradient)
            }
            .pickerStyle(.segmented)
            let isGradient = session.edit.style.background.type == .gradient
            ColorPicker(isGradient ? "Start" : "Color", selection: color(at: 0), supportsOpacity: false)
            if isGradient {
                ColorPicker("End", selection: color(at: 1), supportsOpacity: false)
                LabeledSlider(title: "Angle", value: $session.edit.style.background.angle, range: 0...360, format: { "\(Int($0.rounded()))°" })
            }
            presetRow
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
            HStack(spacing: 8) {
                ForEach(GradientPreset.all) { preset in
                    Button {
                        session.edit.style.background = preset.background
                    } label: {
                        Circle()
                            .fill(preset.swatch)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.primary.opacity(session.edit.style.background == preset.background ? 0.8 : 0.15), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
        }
    }

    private var backgroundType: Binding<BackgroundType> {
        Binding(
            get: { session.edit.style.background.type },
            set: { type in
                var doc = session.edit
                doc.style.background.type = type
                if type == .gradient, doc.style.background.colors.count < 2 {
                    doc.style.background.colors.append(BackgroundSpec.default.colors[1])
                }
                session.edit = doc
            }
        )
    }

    private func color(at index: Int) -> Binding<Color> {
        Binding(
            get: {
                let colors = session.edit.style.background.colors
                let color = index < colors.count ? colors[index] : (colors.last ?? .black)
                return color.color
            },
            set: { newColor in
                var doc = session.edit
                while doc.style.background.colors.count <= index {
                    doc.style.background.colors.append(doc.style.background.colors.last ?? .black)
                }
                doc.style.background.colors[index] = RGBAColor(color: newColor)
                session.edit = doc
            }
        )
    }

    // MARK: - Frame

    private var frameSection: some View {
        Section("Frame") {
            LabeledSlider(title: "Padding", value: $session.edit.style.padding, range: 0...200, format: { pixels($0) })
            LabeledSlider(title: "Corner radius", value: $session.edit.style.cornerRadius, range: 0...64, format: { pixels($0) })
            LabeledSlider(title: "Shadow blur", value: $session.edit.style.shadow.radius, range: 0...120, format: { pixels($0) })
            LabeledSlider(title: "Shadow opacity", value: $session.edit.style.shadow.opacity, range: 0...1, format: { percent($0) })
            LabeledSlider(title: "Shadow offset", value: $session.edit.style.shadow.y, range: -40...80, format: { pixels($0) })
        }
    }

    // MARK: - Cursor

    private var cursorSection: some View {
        Section("Cursor") {
            LabeledSlider(title: "Size", value: $session.edit.cursor.scale, range: 0.5...3, format: { String(format: "%.1f×", $0) })
            LabeledSlider(title: "Smoothing", value: $session.edit.cursor.smoothing, range: 0...1, format: { percent($0) })
            Toggle("Hide when idle", isOn: $session.edit.cursor.hideWhenIdle)
            Toggle("Click highlight", isOn: $session.edit.cursor.clickHighlight)
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        Section("Zoom") {
            Toggle("Auto zoom", isOn: $session.edit.autoZoom.enabled)
            LabeledSlider(title: "Intensity", value: zoomIntensity, range: 0.5...1.5, format: { String(format: "%.2f", $0) })
                .disabled(!session.edit.autoZoom.enabled)
            HStack {
                Text("\(session.edit.zooms.count) zoom\(session.edit.zooms.count == 1 ? "" : "s") from \(clickCount) click\(clickCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Regenerate") { session.regenerateZooms() }
                    .disabled(!session.edit.autoZoom.enabled)
            }
        }
    }

    private var clickCount: Int {
        session.events.clicks.filter { $0.phase == .down }.count
    }

    private var zoomIntensity: Binding<Double> {
        Binding(
            get: { session.edit.autoZoom.intensity },
            set: { session.setZoomIntensity($0) }
        )
    }

    // MARK: - Effects

    private var effectsSection: some View {
        Section("Effects") {
            Toggle("Motion blur on zoom and pan", isOn: $session.edit.effects.motionBlur)
        }
    }

    // MARK: - Formatting

    private func pixels(_ value: Double) -> String {
        "\(Int(value.rounded())) px"
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }
}

/// A slider with its title on the left and the formatted value on the right.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
