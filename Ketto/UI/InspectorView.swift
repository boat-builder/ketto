import SwiftUI

/// The inspector: the selected block first, then canvas, background, frame, cursor, zoom, camera, masks,
/// keystrokes, audio and effects. Every control writes into `session.edit` (one undo step per slider drag) or
/// through a session operation (one undo step each); the composer rebuilds and `edit.json` autosaves.
struct InspectorView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        Form {
            if let zoom = session.selectedZoom {
                selectedZoomSection(zoom)
            }
            if let clip = session.selectedClip {
                selectedClipSection(clip)
            }
            if let mask = session.selectedMask {
                selectedMaskSection(mask)
            }
            canvasSection
            backgroundSection
            frameSection
            cursorSection
            zoomSection
            if session.hasCameraTrack {
                cameraSection
            }
            masksSection
            keystrokesSection
            if session.bundle.hasMicTrack || session.bundle.hasSystemAudioTrack {
                audioSection
            }
            effectsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Selection

    private func selectedZoomSection(_ zoom: Zoom) -> some View {
        Section {
            LabeledSlider(title: "Scale", value: zoomValue(\.scale, default: 2), range: 1.05...4, format: { String(format: "%.2f×", $0) })
            Picker("Easing", selection: zoomEasing) {
                ForEach(Easing.allCases, id: \.self) { easing in
                    Text(Self.easingName(easing)).tag(easing)
                }
            }
            HStack {
                Text("\(TransportBar.timecode(zoom.start)) – \(TransportBar.timecode(zoom.end))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Start Here") { retimeZoom(id: zoom.id, start: true) }
                Button("End Here") { retimeZoom(id: zoom.id, start: false) }
            }
            .controlSize(.small)
            Text("Drag the crosshair in the preview to aim the zoom.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete Zoom", role: .destructive) { session.deleteSelection() }
        } header: {
            Text(zoom.userModified ? "Zoom (manual)" : "Zoom (automatic)")
        }
    }

    private func zoomValue(_ keyPath: WritableKeyPath<Zoom, Double>, default defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { session.selectedZoom?[keyPath: keyPath] ?? defaultValue },
            set: { value in
                guard let id = session.selectedZoom?.id else { return }
                var doc = session.edit
                doc.updateZoom(id: id) { $0[keyPath: keyPath] = value }
                session.edit = doc
            }
        )
    }

    private var zoomEasing: Binding<Easing> {
        Binding(
            get: { session.selectedZoom?.easing ?? .easeInOutCubic },
            set: { easing in
                guard let id = session.selectedZoom?.id else { return }
                session.apply { doc in doc.updateZoom(id: id) { $0.easing = easing } }
            }
        )
    }

    private func retimeZoom(id: String, start: Bool) {
        let t = session.playheadSourceTime
        let limit = session.sourceDuration
        session.apply { doc in
            if start {
                doc.trimZoom(id: id, start: t, limit: limit)
            } else {
                doc.trimZoom(id: id, end: t, limit: limit)
            }
        }
    }

    static func easingName(_ easing: Easing) -> String {
        switch easing {
        case .linear: return "Linear"
        case .easeInQuad: return "Ease in"
        case .easeOutQuad: return "Ease out"
        case .easeInOutQuad: return "Ease in-out (soft)"
        case .easeInOutCubic: return "Ease in-out"
        case .easeOutCubic: return "Ease out (cubic)"
        case .easeInOutSine: return "Sine"
        case .easeOutExpo: return "Snap"
        }
    }

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    private func selectedClipSection(_ clip: Clip) -> some View {
        let speeds = Self.speeds.contains(clip.speed) ? Self.speeds : (Self.speeds + [clip.speed]).sorted()
        let clipCount = session.edit.resolvedClips(sourceDuration: session.sourceDuration).count
        return Section("Clip") {
            Picker("Speed", selection: clipSpeed(id: clip.id, current: clip.speed)) {
                ForEach(speeds, id: \.self) { speed in
                    Text(Self.speedName(speed)).tag(speed)
                }
            }
            Text("\(TransportBar.timecode(clip.sourceStart)) – \(TransportBar.timecode(clip.sourceEnd)) of the recording · \(TransportBar.timecode(clip.outputDuration)) in the edit")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HStack {
                Button("Split at Playhead") { session.splitAtPlayhead() }
                Button("Join with Next") { session.joinSelectedClipWithNext() }
                Spacer()
                Button("Delete", role: .destructive) { session.deleteSelection() }
                    .disabled(clipCount <= 1)
            }
            .controlSize(.small)
            Text("Deleting a clip cuts that part of the recording out of the edit. The recording itself is never changed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func clipSpeed(id: String, current: Double) -> Binding<Double> {
        Binding(
            get: { current },
            set: { session.setClipSpeed(id: id, speed: $0) }
        )
    }

    static func speedName(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    private func selectedMaskSection(_ mask: Mask) -> some View {
        Section("Mask") {
            Picker("Type", selection: maskKind) {
                Text("Blur").tag(MaskKind.blur)
                Text("Highlight").tag(MaskKind.highlight)
            }
            .pickerStyle(.segmented)
            LabeledSlider(title: mask.kind == .blur ? "Blur" : "Dimming", value: maskValue(\.strength, default: 1), range: 0...1, format: { percent($0) })
            LabeledSlider(title: "Corner radius", value: maskValue(\.cornerRadius, default: 8), range: 0...64, format: { pixels($0) })
            HStack {
                Text("\(TransportBar.timecode(mask.start)) – \(mask.end.map { TransportBar.timecode($0) } ?? "end")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Start Here") { retimeMask(id: mask.id, start: true) }
                Button("End Here") { retimeMask(id: mask.id, start: false) }
            }
            .controlSize(.small)
            Toggle("Until the end of the recording", isOn: maskOpenEnded)
            Text("Drag the region in the preview to move it; drag its corners to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Delete Mask", role: .destructive) { session.deleteSelection() }
        }
    }

    private var maskKind: Binding<MaskKind> {
        Binding(
            get: { session.selectedMask?.kind ?? .blur },
            set: { kind in
                guard let id = session.selectedMask?.id else { return }
                session.apply { doc in doc.updateMask(id: id) { $0.kind = kind } }
            }
        )
    }

    private func maskValue(_ keyPath: WritableKeyPath<Mask, Double>, default defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { session.selectedMask?[keyPath: keyPath] ?? defaultValue },
            set: { value in
                guard let id = session.selectedMask?.id else { return }
                var doc = session.edit
                doc.updateMask(id: id) { $0[keyPath: keyPath] = value }
                session.edit = doc
            }
        )
    }

    private var maskOpenEnded: Binding<Bool> {
        Binding(
            get: { session.selectedMask?.end == nil },
            set: { open in
                guard let mask = session.selectedMask else { return }
                let playhead = session.playheadSourceTime
                session.apply { doc in
                    doc.updateMask(id: mask.id) { m in
                        m.end = open ? nil : max(playhead, m.start + 1)
                    }
                }
            }
        )
    }

    private func retimeMask(id: String, start: Bool) {
        let t = session.playheadSourceTime
        session.apply { doc in
            doc.updateMask(id: id) { m in
                if start {
                    m.start = min(t, (m.end ?? .infinity) - 0.1)
                } else {
                    m.end = max(t, m.start + 0.1)
                }
            }
        }
    }

    // MARK: - Canvas

    private var canvasSection: some View {
        Section("Canvas") {
            Picker("Aspect", selection: aspectPreset) {
                ForEach(CanvasSpec.presetNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.segmented)
            Picker("Framing", selection: framing) {
                Text("Fit").tag(FramingMode.fit)
                Text("Fill").tag(FramingMode.fill)
            }
            .pickerStyle(.segmented)
            Text(session.edit.canvas.framing == .fit
                 ? "The whole recording is visible inside the frame."
                 : "The frame is filled; the visible part of the recording follows the cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(session.edit.crop.isFull ? "No crop" : cropDescription(session.edit.crop))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(session.isEditingCrop ? "Done" : "Edit Crop…") {
                    if session.isEditingCrop { session.endCropEditing() } else { session.beginCropEditing() }
                }
                Button("Reset") { session.resetCrop() }
                    .disabled(session.edit.crop.isFull)
            }
            .controlSize(.small)
            if session.isEditingCrop {
                Text("Drag the rectangle in the preview. Automatic zooms are re-optimised when you are done.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cropDescription(_ crop: CropSpec) -> String {
        let width = Int((crop.width * Double(session.source.width)).rounded())
        let height = Int((crop.height * Double(session.source.height)).rounded())
        return "Crop \(width) × \(height) px"
    }

    private var aspectPreset: Binding<String> {
        Binding(
            get: { session.edit.canvas.aspect },
            set: { name in
                guard name != session.edit.canvas.aspect else { return }
                session.applyCanvasPreset(name)
            }
        )
    }

    private var framing: Binding<FramingMode> {
        Binding(
            get: { session.edit.canvas.framing },
            set: { mode in
                guard mode != session.edit.canvas.framing else { return }
                session.setFraming(mode)
            }
        )
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
                        session.apply { $0.style.background = preset.background }
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
                session.apply { doc in
                    doc.style.background.type = type
                    if type == .gradient, doc.style.background.colors.count < 2 {
                        doc.style.background.colors.append(BackgroundSpec.default.colors[1])
                    }
                }
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
            Toggle("Return to the start position at the end", isOn: $session.edit.cursor.loop)
            Text("For seamless loops: the cursor glides back to where it started over the last moments.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        Section("Zoom") {
            Toggle("Auto zoom", isOn: $session.edit.autoZoom.enabled)
            LabeledSlider(title: "Intensity", value: zoomIntensity, range: 0.5...1.5, format: { String(format: "%.2f", $0) })
                .disabled(!session.edit.autoZoom.enabled)
            HStack {
                Text(zoomSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Regenerate") { session.regenerateZooms() }
                    .disabled(!session.edit.autoZoom.enabled)
                    .help("Re-run automatic zoom generation. Manual zooms are kept.")
            }
            Text("Double-click the zoom track to add a zoom; drag blocks to move them and their edges to retime.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var zoomSummary: String {
        let zooms = session.edit.zooms
        let manual = zooms.filter(\.userModified).count
        let automatic = zooms.count - manual
        var parts: [String] = []
        parts.append("\(automatic) automatic from \(clickCount) click\(clickCount == 1 ? "" : "s")")
        if manual > 0 { parts.append("\(manual) manual") }
        return parts.joined(separator: ", ")
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

    // MARK: - Camera

    private var cameraSection: some View {
        Section("Camera") {
            Toggle("Show camera", isOn: $session.edit.camera.enabled)
            Picker("Shape", selection: $session.edit.camera.shape) {
                Text("Circle").tag(CameraShape.circle)
                Text("Rounded").tag(CameraShape.roundedRect)
            }
            .pickerStyle(.segmented)
            LabeledSlider(title: "Size", value: $session.edit.camera.size, range: 0.1...0.6, format: { percent($0) })
            if session.edit.camera.shape == .roundedRect {
                LabeledSlider(title: "Aspect", value: $session.edit.camera.aspect, range: 0.5...2, format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Corner radius", value: $session.edit.camera.cornerRadius, range: 0...120, format: { pixels($0) })
            }
            HStack {
                Text("Position")
                Spacer()
                ForEach(Self.cameraCorners) { corner in
                    Button {
                        session.apply { $0.camera.position = corner.position }
                    } label: {
                        Image(systemName: corner.symbol)
                    }
                    .help(corner.name)
                }
            }
            .buttonStyle(.borderless)
            LabeledSlider(title: "Border", value: $session.edit.camera.border.width, range: 0...12, format: { pixels($0) })
            ColorPicker("Border color", selection: borderColor, supportsOpacity: false)
            Toggle("Shadow", isOn: $session.edit.camera.shadow)
            Toggle("Mirror", isOn: $session.edit.camera.mirrored)
            Toggle("Move out of the cursor's way", isOn: $session.edit.camera.dodgeCursor)
            Text("Drag the camera in the preview to place it; drag its corner to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private struct CameraCorner: Identifiable {
        let name: String
        let symbol: String
        let position: SIMD2<Double>
        var id: String { name }
    }

    private static let cameraCorners: [CameraCorner] = [
        CameraCorner(name: "Top left", symbol: "arrow.up.left.square", position: SIMD2(0.14, 0.18)),
        CameraCorner(name: "Top right", symbol: "arrow.up.right.square", position: SIMD2(0.86, 0.18)),
        CameraCorner(name: "Bottom left", symbol: "arrow.down.left.square", position: SIMD2(0.14, 0.82)),
        CameraCorner(name: "Bottom right", symbol: "arrow.down.right.square", position: SIMD2(0.86, 0.82)),
    ]

    private var borderColor: Binding<Color> {
        Binding(
            get: { session.edit.camera.border.color.color },
            set: { session.edit.camera.border.color = RGBAColor(color: $0) }
        )
    }

    // MARK: - Masks

    private var masksSection: some View {
        Section("Masks") {
            if session.edit.masks.isEmpty {
                Text("Blur a region to hide sensitive information, or highlight one for emphasis. Masks follow zooms and crops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.edit.masks) { mask in
                HStack {
                    Label(mask.kind == .blur ? "Blur" : "Highlight", systemImage: mask.kind == .blur ? "drop.fill" : "sun.max.fill")
                    Spacer()
                    Text("\(TransportBar.timecode(mask.start)) – \(mask.end.map { TransportBar.timecode($0) } ?? "end")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    session.selection = .mask(mask.id)
                    let sourceTime = session.playheadSourceTime
                    if !mask.isActive(at: sourceTime) {
                        session.player.seek(to: session.timeline.outputTime(forSource: mask.start))
                    }
                }
                .listRowBackground(session.selection == .mask(mask.id) ? Color.accentColor.opacity(0.15) : nil)
            }
            HStack {
                Button("Add Blur") { session.addMask(kind: .blur) }
                Button("Add Highlight") { session.addMask(kind: .highlight) }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Keystrokes

    private var keystrokesSection: some View {
        Section("Keystrokes") {
            if session.events.keys.isEmpty {
                Text("No keystrokes were recorded. Turn on keystroke capture in the recorder to show shortcuts on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Show keystrokes", isOn: $session.edit.keystrokes.enabled)
                Toggle("Shortcuts only", isOn: $session.edit.keystrokes.shortcutsOnly)
                    .disabled(!session.edit.keystrokes.enabled)
                Picker("Position", selection: $session.edit.keystrokes.position) {
                    Text("Top").tag(OverlayEdge.top)
                    Text("Bottom").tag(OverlayEdge.bottom)
                }
                .pickerStyle(.segmented)
                .disabled(!session.edit.keystrokes.enabled)
                LabeledSlider(title: "Size", value: $session.edit.keystrokes.scale, range: 0.5...2, format: { String(format: "%.1f×", $0) })
                    .disabled(!session.edit.keystrokes.enabled)
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section("Audio") {
            if session.bundle.hasMicTrack {
                LabeledSlider(title: "Voice", value: $session.edit.audio.micVolume, range: 0...2, format: { percent($0) })
                Toggle("Normalize voice level", isOn: $session.edit.audio.normalize)
                Toggle("Remove background noise", isOn: $session.edit.audio.noiseRemoval)
                switch session.audioProcessing {
                case .idle:
                    if session.edit.audio.normalize || session.edit.audio.noiseRemoval {
                        Text("Processed voice track ready.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .running:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Processing the voice track…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text("Voice processing failed: \(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if session.bundle.hasSystemAudioTrack {
                LabeledSlider(title: "System audio", value: $session.edit.audio.systemVolume, range: 0...2, format: { percent($0) })
            }
        }
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
