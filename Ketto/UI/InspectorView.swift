import SwiftUI

/// The inspector: whatever is selected on the timeline first (a zoom, a clip or a mask gets its own card on top),
/// then four tabs. Look holds canvas, background and frame; Motion the automatic zooms, the cursor and effects;
/// Overlays the camera bubble, masks and keystrokes; Audio the volumes and voice clean-up. Every control writes
/// into `session.edit` (one undo step per slider drag) or through a session operation (one undo step each); the
/// composer rebuilds and `edit.json` autosaves.
struct InspectorView: View {
    @Bindable var session: ProjectSession

    enum Tab: String, CaseIterable, Identifiable {
        case look = "Look"
        case motion = "Motion"
        case overlays = "Overlays"
        case audio = "Audio"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .look

    var body: some View {
        VStack(spacing: 0) {
            EditorSegmentedPicker(selection: $tab, options: Tab.allCases.map { ($0, $0.rawValue) }, height: 26, expands: true)
                .accessibilityLabel("Inspector")
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let zoom = session.selectedZoom {
                        selectedZoomCard(zoom)
                    }
                    if let clip = session.selectedClip {
                        selectedClipCard(clip)
                    }
                    if let mask = session.selectedMask {
                        selectedMaskCard(mask)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .look:
                            canvasSection
                            Hairline()
                            backgroundSection
                            Hairline()
                            frameSection
                        case .motion:
                            zoomSection
                            Hairline()
                            cursorSection
                            Hairline()
                            effectsSection
                        case .overlays:
                            cameraSection
                            Hairline()
                            masksSection
                            Hairline()
                            keystrokesSection
                        case .audio:
                            if session.bundle.hasMicTrack || session.bundle.hasSystemAudioTrack {
                                audioSection
                            } else {
                                InspectorGroup(title: "Audio") {
                                    Caption("This recording has no audio tracks. Switch the microphone or system audio on in the capture bar before recording.")
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(KettoTheme.ink)
        .tint(KettoTheme.accent)
        .background(KettoTheme.canvas)
        .onChange(of: session.selection) { _, selection in
            // A new selection opens the tab its controls live on, so the card and its context sit together.
            switch selection {
            case .zoom: tab = .motion
            case .mask: tab = .overlays
            case .clip, .none: break
            }
        }
    }

    // MARK: - Selection

    private func selectedZoomCard(_ zoom: Zoom) -> some View {
        SelectionCard {
            HStack(spacing: 8) {
                Text("Zoom").font(.system(size: 13, weight: .semibold))
                Tag(zoom.userModified ? "Manual" : "Automatic")
                Spacer(minLength: 0)
                Text("\(TransportBar.timecode(zoom.start)) – \(TransportBar.timecode(zoom.end))")
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .monospacedDigit()
            }
        } content: {
            LabeledSlider(title: "Scale", value: zoomValue(\.scale, default: 2), range: 1.05...4, format: { String(format: "%.2f×", $0) }, track: KettoTheme.accentLine.opacity(0.75))
            ValueRow("Easing") {
                Picker("Easing", selection: zoomEasing) {
                    ForEach(Easing.allCases, id: \.self) { easing in
                        Text(Self.easingName(easing)).tag(easing)
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Start Here") { retimeZoom(id: zoom.id, start: true) }
                Button("End Here") { retimeZoom(id: zoom.id, start: false) }
                Spacer(minLength: 0)
                TrashButton(help: "Delete this zoom") { session.deleteSelection() }
            }
            .buttonStyle(CompactPillButtonStyle(filled: true))
            Caption("Drag the crosshair in the preview to aim the zoom.")
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

    private func selectedClipCard(_ clip: Clip) -> some View {
        let speeds = Self.speeds.contains(clip.speed) ? Self.speeds : (Self.speeds + [clip.speed]).sorted()
        let clipCount = session.edit.resolvedClips(sourceDuration: session.sourceDuration).count
        return SelectionCard {
            HStack(spacing: 8) {
                Text("Clip").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(TransportBar.timecode(clip.outputDuration)) in the edit")
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .monospacedDigit()
            }
        } content: {
            ValueRow("Speed") {
                Picker("Speed", selection: clipSpeed(id: clip.id, current: clip.speed)) {
                    ForEach(speeds, id: \.self) { speed in
                        Text(Self.speedName(speed)).tag(speed)
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Split at Playhead") { session.splitAtPlayhead() }
                Button("Join with Next") { session.joinSelectedClipWithNext() }
                Spacer(minLength: 0)
                TrashButton(help: "Delete this clip") { session.deleteSelection() }
                    .disabled(clipCount <= 1)
            }
            .buttonStyle(CompactPillButtonStyle(filled: true))
            Caption("\(TransportBar.timecode(clip.sourceStart)) – \(TransportBar.timecode(clip.sourceEnd)) of the recording. Deleting a clip cuts that part of the recording out of the edit. The recording itself is never changed.")
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

    private func selectedMaskCard(_ mask: Mask) -> some View {
        SelectionCard {
            HStack(spacing: 8) {
                Text("Mask").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                EditorSegmentedPicker(selection: maskKind, options: [(MaskKind.blur, "Blur"), (MaskKind.highlight, "Highlight")], height: 22, fontSize: 12, track: KettoTheme.accentTint)
                    .accessibilityLabel("Type")
            }
        } content: {
            LabeledSlider(title: mask.kind == .blur ? "Blur" : "Dimming", value: maskValue(\.strength, default: 1), range: 0...1, format: { percent($0) }, track: KettoTheme.accentLine.opacity(0.75))
            LabeledSlider(title: "Corner radius", value: maskValue(\.cornerRadius, default: 8), range: 0...64, format: { pixels($0) }, track: KettoTheme.accentLine.opacity(0.75))
            HStack(spacing: 6) {
                Text("\(TransportBar.timecode(mask.start)) – \(mask.end.map { TransportBar.timecode($0) } ?? "end")")
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Button("Start Here") { retimeMask(id: mask.id, start: true) }
                Button("End Here") { retimeMask(id: mask.id, start: false) }
            }
            .buttonStyle(CompactPillButtonStyle(filled: true))
            SwitchRow("Until the end of the recording", isOn: maskOpenEnded)
            HStack(spacing: 8) {
                Caption("Drag the region in the preview to move it; drag its corners to resize.")
                Spacer(minLength: 0)
                TrashButton(help: "Delete this mask") { session.deleteSelection() }
            }
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
        InspectorGroup(title: "Canvas") {
            AspectPicker(selection: aspectPreset)
            ValueRow("Framing", detail: session.edit.canvas.framing == .fit
                     ? "The whole recording is visible inside the frame."
                     : "The frame is filled; the visible part of the recording follows the cursor.") {
                EditorSegmentedPicker(selection: framing, options: [(FramingMode.fit, "Fit"), (FramingMode.fill, "Fill")])
                    .accessibilityLabel("Framing")
            }
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Crop")
                    Text(session.edit.crop.isFull ? "None" : cropDescription(session.edit.crop))
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(session.isEditingCrop ? "Done" : "Edit Crop…") {
                    if session.isEditingCrop { session.endCropEditing() } else { session.beginCropEditing() }
                }
                Button("Reset") { session.resetCrop() }
                    .disabled(session.edit.crop.isFull)
            }
            .buttonStyle(CompactPillButtonStyle())
            if session.isEditingCrop {
                Caption("Drag the rectangle in the preview. Automatic zooms are re-optimised when you are done.")
            }
        }
    }

    private func cropDescription(_ crop: CropSpec) -> String {
        let width = Int((crop.width * Double(session.source.width)).rounded())
        let height = Int((crop.height * Double(session.source.height)).rounded())
        return "\(width) × \(height) px"
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
        InspectorGroup(title: "Background") {
            EditorSegmentedPicker(selection: backgroundType, options: [(BackgroundType.solid, "Solid"), (BackgroundType.gradient, "Gradient")], height: 22, fontSize: 12)
                .accessibilityLabel("Style")
        } content: {
            presetRow
            let isGradient = session.edit.style.background.type == .gradient
            HStack(spacing: 10) {
                Text(isGradient ? "Colors" : "Color")
                Spacer(minLength: 0)
                ColorPicker(isGradient ? "Start" : "Color", selection: color(at: 0), supportsOpacity: false)
                    .labelsHidden()
                if isGradient {
                    ColorPicker("End", selection: color(at: 1), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            if isGradient {
                LabeledSlider(title: "Angle", value: $session.edit.style.background.angle, range: 0...360, format: { "\(Int($0.rounded()))°" })
            }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 10) {
            ForEach(GradientPreset.all) { preset in
                let isSelected = session.edit.style.background == preset.background
                Button {
                    session.apply { $0.style.background = preset.background }
                } label: {
                    Circle()
                        .fill(preset.swatch)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(isSelected ? KettoTheme.accent : Color.clear, lineWidth: KettoTheme.line))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, -3)
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
        InspectorGroup(title: "Frame") {
            LabeledSlider(title: "Padding", value: $session.edit.style.padding, range: 0...200, format: { pixels($0) })
            LabeledSlider(title: "Corner radius", value: $session.edit.style.cornerRadius, range: 0...64, format: { pixels($0) })
            LabeledSlider(title: "Shadow blur", value: $session.edit.style.shadow.radius, range: 0...120, format: { pixels($0) })
            LabeledSlider(title: "Shadow opacity", value: $session.edit.style.shadow.opacity, range: 0...1, format: { percent($0) })
            LabeledSlider(title: "Shadow offset", value: $session.edit.style.shadow.y, range: -40...80, format: { pixels($0) })
        }
    }

    // MARK: - Cursor

    private var cursorSection: some View {
        InspectorGroup(title: "Cursor") {
            LabeledSlider(title: "Size", value: $session.edit.cursor.scale, range: 0.5...3, format: { String(format: "%.1f×", $0) })
            LabeledSlider(title: "Smoothing", value: $session.edit.cursor.smoothing, range: 0...1, format: { percent($0) })
            SwitchRow("Hide when idle", isOn: $session.edit.cursor.hideWhenIdle)
            SwitchRow("Click highlight", isOn: $session.edit.cursor.clickHighlight)
            SwitchRow("Return to the start position at the end", detail: "For seamless loops: the cursor glides back to where it started over the last moments.", isOn: $session.edit.cursor.loop)
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        InspectorGroup(title: "Automatic zooms") {
            SwitchRow("Auto zoom", isOn: $session.edit.autoZoom.enabled)
            LabeledSlider(title: "Intensity", value: zoomIntensity, range: 0.5...1.5, format: { String(format: "%.2f", $0) })
                .disabled(!session.edit.autoZoom.enabled)
            HStack(spacing: 8) {
                Text(zoomSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(KettoTheme.secondaryInk)
                Spacer(minLength: 0)
                Button("Regenerate") { session.regenerateZooms() }
                    .buttonStyle(CompactPillButtonStyle())
                    .disabled(!session.edit.autoZoom.enabled)
                    .help("Re-run automatic zoom generation. Manual zooms are kept.")
            }
            Caption("Double-click the zoom track to add a zoom; drag blocks to move them and their edges to retime.")
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

    /// Always present, so the feature is discoverable: a project without a camera track says how to get one.
    @ViewBuilder
    private var cameraSection: some View {
        if session.hasCameraTrack {
            InspectorGroup(title: "Camera") {
                Toggle("Show camera", isOn: $session.edit.camera.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show camera")
            } content: {
                cameraControls
            }
        } else {
            InspectorGroup(title: "Camera") {
                Caption("This project has no camera track. Switch the camera on in the capture bar to record yourself alongside the screen; the camera floats over the display while you record and becomes a bubble here, with its shape, size, position, corners and border to adjust.")
            }
        }
    }

    @ViewBuilder
    private var cameraControls: some View {
        Group {
            ValueRow("Shape") {
                EditorSegmentedPicker(selection: $session.edit.camera.shape, options: [(CameraShape.circle, "Circle"), (CameraShape.roundedRect, "Rounded")])
                    .accessibilityLabel("Shape")
            }
            LabeledSlider(title: "Size", value: $session.edit.camera.size, range: 0.1...0.6, format: { percent($0) })
            if session.edit.camera.shape == .roundedRect {
                LabeledSlider(title: "Aspect", value: $session.edit.camera.aspect, range: 0.5...2, format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Corner radius", value: $session.edit.camera.cornerRadius, range: 0...120, format: { pixels($0) })
            }
            ValueRow("Position", detail: "Pick a corner, or drag the bubble in the preview") {
                cornerPad
            }
            LabeledSlider(title: "Horizontal", value: cameraPosition(\.x), range: 0...1, format: { percent($0) })
            LabeledSlider(title: "Vertical", value: cameraPosition(\.y), range: 0...1, format: { percent($0) })
        }
        Group {
            HStack(alignment: .bottom, spacing: 12) {
                LabeledSlider(title: "Border", value: $session.edit.camera.border.width, range: 0...12, format: { pixels($0) })
                ColorPicker("Border color", selection: borderColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Border color")
            }
            SwitchRow("Shadow", isOn: $session.edit.camera.shadow)
            SwitchRow("Mirror", isOn: $session.edit.camera.mirrored)
            SwitchRow("Move out of the cursor’s way", isOn: $session.edit.camera.dodgeCursor)
            Caption("Drag the camera in the preview to place it; drag its corner to resize. It starts out where the floating bubble was when the recording stopped.")
        }
    }

    /// Four corner targets in a small frame; the corner the bubble sits in is filled.
    private var cornerPad: some View {
        let columns = [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)]
        return LazyVGrid(columns: columns, spacing: 22) {
            ForEach(Array(Self.cameraCorners.enumerated()), id: \.element.id) { index, corner in
                let offset = session.edit.camera.position - corner.position
                let isOn = (offset.x * offset.x + offset.y * offset.y) < 0.0004
                Button {
                    session.apply { $0.camera.position = corner.position }
                } label: {
                    Circle()
                        .fill(isOn ? KettoTheme.accent : Color.clear)
                        .overlay(Circle().strokeBorder(isOn ? Color.clear : KettoTheme.secondaryInk.opacity(0.7), lineWidth: KettoTheme.line))
                        .frame(width: 14, height: 14)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: index.isMultiple(of: 2) ? .leading : .trailing)
                .help(corner.name)
                .accessibilityLabel(corner.name)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(width: 112, height: 64)
        .background(KettoTheme.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// One axis of the overlay's centre, 0 = left / top, 1 = right / bottom of the canvas.
    private func cameraPosition(_ keyPath: WritableKeyPath<SIMD2<Double>, Double>) -> Binding<Double> {
        Binding(
            get: { session.edit.camera.position[keyPath: keyPath] },
            set: { value in
                var doc = session.edit
                doc.camera.position[keyPath: keyPath] = min(max(value, 0), 1)
                session.edit = doc
            }
        )
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
        InspectorGroup(title: "Masks") {
            if session.edit.masks.isEmpty {
                Caption("Blur a region to hide sensitive information, or highlight one for emphasis. Masks follow zooms and crops.")
            } else {
                VStack(spacing: 2) {
                    ForEach(session.edit.masks) { mask in
                        maskRow(mask)
                    }
                }
            }
            HStack(spacing: 6) {
                Button { session.addMask(kind: .blur) } label: { Label("Blur", systemImage: "plus") }
                    .help("Add a blur at the playhead")
                Button { session.addMask(kind: .highlight) } label: { Label("Highlight", systemImage: "plus") }
                    .help("Add a highlight at the playhead")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(CompactPillButtonStyle())
        }
    }

    private func maskRow(_ mask: Mask) -> some View {
        let isSelected = session.selection == .mask(mask.id)
        return HStack(spacing: 8) {
            Image(systemName: mask.kind == .blur ? "drop" : "sun.max")
                .font(.system(size: 12))
                .frame(width: 16)
            Text(mask.kind == .blur ? "Blur" : "Highlight")
                .fontWeight(isSelected ? .medium : .regular)
            Spacer(minLength: 0)
            Text("\(TransportBar.timecode(mask.start)) – \(mask.end.map { TransportBar.timecode($0) } ?? "end")")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isSelected ? KettoTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            session.selection = .mask(mask.id)
            let sourceTime = session.playheadSourceTime
            if !mask.isActive(at: sourceTime) {
                session.player.seek(to: session.timeline.outputTime(forSource: mask.start))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Keystrokes

    @ViewBuilder
    private var keystrokesSection: some View {
        if session.events.keys.isEmpty {
            InspectorGroup(title: "Keystrokes") {
                Caption("No keystrokes were recorded. Turn on keystroke capture in the recorder to show shortcuts on screen.")
            }
        } else {
            InspectorGroup(title: "Keystrokes") {
                Toggle("Show keystrokes", isOn: $session.edit.keystrokes.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Show keystrokes")
            } content: {
                SwitchRow("Shortcuts only", isOn: $session.edit.keystrokes.shortcutsOnly)
                    .disabled(!session.edit.keystrokes.enabled)
                ValueRow("Position") {
                    EditorSegmentedPicker(selection: $session.edit.keystrokes.position, options: [(OverlayEdge.top, "Top"), (OverlayEdge.bottom, "Bottom")])
                        .accessibilityLabel("Position")
                }
                .disabled(!session.edit.keystrokes.enabled)
                LabeledSlider(title: "Size", value: $session.edit.keystrokes.scale, range: 0.5...2, format: { String(format: "%.1f×", $0) })
                    .disabled(!session.edit.keystrokes.enabled)
            }
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        if session.bundle.hasMicTrack {
            InspectorGroup(title: "Voice") {
                LabeledSlider(title: "Volume", value: $session.edit.audio.micVolume, range: 0...2, format: { percent($0) })
                SwitchRow("Normalize voice level", isOn: $session.edit.audio.normalize)
                SwitchRow("Remove background noise", isOn: $session.edit.audio.noiseRemoval)
                switch session.audioProcessing {
                case .idle:
                    if session.edit.audio.normalize || session.edit.audio.noiseRemoval {
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11))
                            Text("Processed voice track ready.")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                    }
                case .running:
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Processing the voice track…")
                            .font(.system(size: 12))
                            .foregroundStyle(KettoTheme.secondaryInk)
                    }
                case .failed(let message):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        StatusDot(color: KettoTheme.warning)
                        Text("Voice processing failed: \(message)")
                            .font(.system(size: 12))
                            .foregroundStyle(KettoTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if session.bundle.hasMicTrack && session.bundle.hasSystemAudioTrack {
            Hairline()
        }
        if session.bundle.hasSystemAudioTrack {
            InspectorGroup(title: "System audio") {
                LabeledSlider(title: "Volume", value: $session.edit.audio.systemVolume, range: 0...2, format: { percent($0) })
            }
        }
    }

    // MARK: - Effects

    private var effectsSection: some View {
        InspectorGroup(title: "Effects") {
            SwitchRow("Motion blur on zoom and pan", isOn: $session.edit.effects.motionBlur)
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

// MARK: - Inspector pieces

/// A slider with its title on the left and the formatted value on the right.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var track: Color = KettoTheme.track

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            EditorSlider(value: $value, range: range, track: track)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

/// The editor's slider: a 2pt track, the filled part in the accent, a small white thumb. Native sliders are
/// thicker than the rest of the editor's lines; this one keeps a native slider as its accessibility
/// representation, so VoiceOver and keyboard adjustment behave as before.
struct EditorSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var track: Color = KettoTheme.track
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false

    private static let thumb: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
            let fraction = CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
            let x = (width - Self.thumb) * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                    .frame(height: 2)
                Capsule()
                    .fill(isEnabled ? KettoTheme.accent : KettoTheme.outline)
                    .frame(width: max(x + Self.thumb / 2, 0), height: 2)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: x)
            }
            .frame(width: width, height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let f = min(max((drag.location.x - Self.thumb / 2) / max(width - Self.thumb, 1), 0), 1)
                        value = range.lowerBound + Double(f) * span
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 16)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation {
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
        }
    }
}

/// The editor's segmented control: a quiet fill with the chosen segment raised in white.
struct EditorSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var height: CGFloat = 24
    var expands = false
    var fontSize: CGFloat = 13
    var track: Color = KettoTheme.fill

    private static var raised: Color { KettoTheme.dynamic(light: 0xFFFFFF, dark: 0x4A4750) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: fontSize, weight: isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? KettoTheme.ink : KettoTheme.secondaryInk)
                        .lineLimit(1)
                        .padding(.horizontal, expands ? 4 : 11)
                        .frame(maxWidth: expands ? .infinity : nil)
                        .frame(height: height)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Self.raised)
                                    .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(track, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize(horizontal: !expands, vertical: true)
    }
}

/// The four canvas presets with a small outline of each shape.
private struct AspectPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasSpec.presetNames, id: \.self) { name in
                let isOn = name == selection
                Button {
                    selection = name
                } label: {
                    VStack(spacing: 4) {
                        AspectGlyph(name: name)
                            .stroke(isOn ? KettoTheme.ink : KettoTheme.secondaryInk, lineWidth: 1.2)
                            .frame(width: 22, height: 16)
                        Text(name)
                            .font(.system(size: 11, weight: isOn ? .semibold : .medium))
                            .foregroundStyle(isOn ? KettoTheme.ink : KettoTheme.secondaryInk)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(KettoTheme.dynamic(light: 0xFFFFFF, dark: 0x4A4750))
                                .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(name) canvas")
                .accessibilityLabel("\(name) canvas")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(KettoTheme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A rounded rectangle with the proportions of an aspect name like "16:9", fitted into the glyph box.
private struct AspectGlyph: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        let parts = name.split(separator: ":").compactMap { Double($0) }
        let aspect = parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1
        let box = rect.insetBy(dx: 1, dy: 1)
        var width = box.width
        var height = width / aspect
        if height > box.height {
            height = box.height
            width = height * aspect
        }
        let shape = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        return Path(roundedRect: shape, cornerRadius: 2)
    }
}

/// A titled group of inspector controls: a quiet small heading, an optional control on its right (a switch, a
/// segmented choice), and the rows underneath.
private struct InspectorGroup<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(KettoTheme.secondaryInk)
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: 22)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InspectorGroup where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// The card a selected zoom, clip or mask gets above the tab: an accent wash inside a 1pt accent line.
private struct SelectionCard<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 12, fill: KettoTheme.accentWash, stroke: KettoTheme.accentLine)
    }
}

/// A label on the left and a switch on the right, with an optional second line.
private struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .frame(minHeight: 22)
    }
}

/// A label (and optional second line) on the left, a control on the right.
private struct ValueRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(KettoTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
                .labelsHidden()
                .fixedSize()
        }
    }
}

/// Secondary explanatory text.
private struct Caption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(KettoTheme.secondaryInk)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small capsule tag on a card header ("Manual").
private struct Tag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(KettoTheme.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(KettoTheme.outline, lineWidth: 0.5))
    }
}

/// The trash icon that deletes the selected block.
private struct TrashButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
        }
        .buttonStyle(IconButtonStyle(size: 26, cornerRadius: 13))
        .hoverHighlight(cornerRadius: 13)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A 26pt pill for the inspector's small actions: outlined, or filled with the canvas inside a selection card.
private struct CompactPillButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(KettoTheme.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                configuration.isPressed ? KettoTheme.fill : (filled ? KettoTheme.canvas : Color.clear),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(KettoTheme.outline, lineWidth: filled ? 0.5 : KettoTheme.line))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
