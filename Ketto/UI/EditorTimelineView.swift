import SwiftUI
import AppKit

/// Output seconds ↔ timeline points.
struct TimelineGeometry: Equatable {
    var pixelsPerSecond: Double
    var duration: Double

    static let trailingPadding: CGFloat = 32
    static let maximumPixelsPerSecond = 600.0

    var contentWidth: CGFloat { CGFloat(max(duration, 0) * pixelsPerSecond) + Self.trailingPadding }

    func x(_ t: Double) -> CGFloat { CGFloat(t * pixelsPerSecond) }
    func time(_ x: CGFloat) -> Double { Double(x) / max(pixelsPerSecond, 1e-6) }

    /// Points per second that fit the whole edit into `width`.
    static func fit(duration: Double, width: CGFloat) -> Double {
        max(Double(width - trailingPadding) / max(duration, 0.1), 1)
    }
}

/// The timeline: ruler with the playhead, the main track (filmstrip + waveforms, clips with trim handles),
/// the zoom track and the mask track. Blocks are plain views positioned by `TimelineGeometry`; the ruler,
/// filmstrip and waveforms are drawn in `Canvas` layers that only cover the visible window, so a long
/// project costs the same to draw as a short one. The playhead lives in its own view, so scrubbing moves one
/// small view instead of re-laying out the tracks.
struct EditorTimelineView: View {
    @Bindable var session: ProjectSession

    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var isScrubbing = false

    static let rulerHeight: CGFloat = 22
    static let clipTrackHeight: CGFloat = 58
    static let zoomTrackHeight: CGFloat = 28
    static let maskTrackHeight: CGFloat = 28
    static let trackSpacing: CGFloat = 6
    static let headerWidth: CGFloat = 96
    private static let anchorsPerSecond = 4.0

    private var geometry: TimelineGeometry {
        let duration = session.duration
        let fit = TimelineGeometry.fit(duration: duration, width: max(viewportWidth, 200))
        let pps = session.timelinePixelsPerSecond > 0 ? min(max(session.timelinePixelsPerSecond, fit), TimelineGeometry.maximumPixelsPerSecond) : fit
        return TimelineGeometry(pixelsPerSecond: pps, duration: duration)
    }

    private var totalHeight: CGFloat {
        Self.rulerHeight + Self.clipTrackHeight + Self.zoomTrackHeight + Self.maskTrackHeight + 3 * Self.trackSpacing
    }

    private var clipTrackY: CGFloat { Self.rulerHeight + Self.trackSpacing }
    private var zoomTrackY: CGFloat { clipTrackY + Self.clipTrackHeight + Self.trackSpacing }
    private var maskTrackY: CGFloat { zoomTrackY + Self.zoomTrackHeight + Self.trackSpacing }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                TimelineToolbar(session: session, geometry: geometry, viewportWidth: viewportWidth, scrollOffset: scrollOffset) { time, fraction in
                    scroll(proxy, toTime: time, atFraction: fraction)
                }
                HStack(spacing: 0) {
                    headerColumn
                        .frame(width: Self.headerWidth, height: totalHeight)
                    GeometryReader { outer in
                        ScrollView(.horizontal, showsIndicators: true) {
                            content
                                .frame(width: geometry.contentWidth, height: totalHeight, alignment: .topLeading)
                        }
                        .coordinateSpace(.named("timelineScroll"))
                        .onChange(of: outer.size.width, initial: true) { _, width in
                            viewportWidth = width
                            session.timelineFitPixelsPerSecond = TimelineGeometry.fit(duration: session.duration, width: max(width, 200))
                        }
                        .onChange(of: session.duration) { _, duration in
                            session.timelineFitPixelsPerSecond = TimelineGeometry.fit(duration: duration, width: max(viewportWidth, 200))
                        }
                    }
                    .frame(height: totalHeight)
                }
                .padding(.trailing, 16)
                .background(KettoTheme.canvas)
                PlayheadFollower(session: session, geometry: geometry, viewportWidth: viewportWidth, scrollOffset: scrollOffset) { time, fraction in
                    scroll(proxy, toTime: time, atFraction: fraction)
                }
            }
        }
        .frame(height: totalHeight + 52)
    }

    // MARK: - Header

    private var headerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlayheadTimecode(session: session)
                .frame(height: Self.rulerHeight)
            Spacer().frame(height: Self.trackSpacing)
            trackLabel("Video", systemImage: "film")
                .frame(height: Self.clipTrackHeight)
            Spacer().frame(height: Self.trackSpacing)
            HStack(spacing: 4) {
                trackLabel("Zoom", systemImage: "plus.magnifyingglass")
                Spacer(minLength: 0)
                Button { session.addZoomAtPlayhead() } label: { AddBadge() }
                    .buttonStyle(.plain)
                    .help("Add a zoom at the playhead")
                    .accessibilityLabel("Add a zoom at the playhead")
            }
            .frame(height: Self.zoomTrackHeight)
            Spacer().frame(height: Self.trackSpacing)
            HStack(spacing: 4) {
                trackLabel("Masks", systemImage: "drop")
                Spacer(minLength: 0)
                Menu {
                    Button("Blur Region") { session.addMask(kind: .blur) }
                    Button("Highlight Region") { session.addMask(kind: .highlight) }
                } label: {
                    AddBadge()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a mask at the playhead")
                .accessibilityLabel("Add a blur or highlight at the playhead")
            }
            .frame(height: Self.maskTrackHeight)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .background(KettoTheme.canvas)
    }

    private func trackLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .regular))
            Text(title)
                .font(.system(size: 12))
        }
        .foregroundStyle(KettoTheme.secondaryInk)
        .lineLimit(1)
    }

    // MARK: - Scrolling content

    private var content: some View {
        let geometry = geometry
        let timeline = session.timeline
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: geometry.contentWidth, height: totalHeight)
                .contentShape(Rectangle())
                .onTapGesture { session.selection = nil }
            GeometryReader { geo in
                Color.clear.onChange(of: geo.frame(in: .named("timelineScroll")).minX, initial: true) { _, minX in
                    scrollOffset = max(0, -minX)
                }
            }
            .frame(width: 1, height: 1)

            // Scroll anchors, so the view can be scrolled to a time programmatically.
            ForEach(0...Int(max(geometry.duration, 0) * Self.anchorsPerSecond), id: \.self) { index in
                Color.clear
                    .frame(width: 1, height: 1)
                    .id(index)
                    .offset(x: geometry.x(Double(index) / Self.anchorsPerSecond))
            }

            RulerCanvas(geometry: geometry, scrollOffset: scrollOffset, viewportWidth: viewportWidth)
                .frame(width: max(viewportWidth, 1), height: Self.rulerHeight)
                .offset(x: scrollOffset)
            MainTrackCanvas(session: session, geometry: geometry, scrollOffset: scrollOffset, viewportWidth: viewportWidth, height: Self.clipTrackHeight)
                .frame(width: max(viewportWidth, 1), height: Self.clipTrackHeight)
                .offset(x: scrollOffset, y: clipTrackY)
            trackBackground(y: zoomTrackY, height: Self.zoomTrackHeight)
                .onTapGesture(count: 2) { location in
                    addZoom(atOutput: geometry.time(location.x))
                }
            trackBackground(y: maskTrackY, height: Self.maskTrackHeight)

            // Snap targets are computed when a drag starts, never here: they include the playhead, and reading
            // it in the body would re-lay out every block thirty times a second during playback.
            let makeSnapper: (EditorSelection, Double) -> TimelineSnapper = { selection, speed in
                snapper(excluding: selection, speed: speed)
            }
            ForEach(timeline.segments, id: \.clipID) { segment in
                ClipBlockView(session: session, segment: segment, geometry: geometry, height: Self.clipTrackHeight, makeSnapper: makeSnapper)
                    .offset(x: geometry.x(segment.outputStart), y: clipTrackY)
            }
            ForEach(session.edit.zooms) { zoom in
                ZoomBlockView(session: session, zoom: zoom, geometry: geometry, height: Self.zoomTrackHeight, makeSnapper: makeSnapper)
                    .offset(y: zoomTrackY)
            }
            ForEach(session.edit.masks) { mask in
                MaskBlockView(session: session, mask: mask, geometry: geometry, height: Self.maskTrackHeight, makeSnapper: makeSnapper)
                    .offset(y: maskTrackY)
            }

            PlayheadView(session: session, geometry: geometry, height: totalHeight)

            // The ruler scrubs: any drag or click in it moves the playhead.
            Color.clear
                .frame(width: geometry.contentWidth, height: Self.rulerHeight)
                .contentShape(Rectangle())
                .gesture(scrubGesture(geometry: geometry))
        }
    }

    private func trackBackground(y: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(KettoTheme.surface)
            .frame(width: geometry.contentWidth - TimelineGeometry.trailingPadding, height: height)
            .offset(y: y)
            .contentShape(Rectangle())
    }

    private func scrubGesture(geometry: TimelineGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    session.player.beginScrubbing()
                }
                session.player.seek(to: min(max(geometry.time(value.location.x), 0), session.duration))
            }
            .onEnded { _ in
                isScrubbing = false
                session.player.endScrubbing()
            }
    }

    private func addZoom(atOutput t: Double) {
        session.player.seek(to: min(max(t, 0), session.duration))
        session.addZoomAtPlayhead()
    }

    /// Snap targets in source seconds: the recording's bounds, the playhead, and every other block's edges.
    private func snapper(excluding: EditorSelection, speed: Double) -> TimelineSnapper {
        let edit = session.edit
        let duration = session.sourceDuration
        var candidates: [Double] = [0, duration, session.playheadSourceTime]
        for clip in edit.resolvedClips(sourceDuration: duration) where excluding != .clip(clip.id) {
            candidates.append(clip.sourceStart)
            candidates.append(clip.sourceEnd)
        }
        for zoom in edit.zooms where excluding != .zoom(zoom.id) {
            candidates.append(zoom.start)
            candidates.append(zoom.end)
        }
        for mask in edit.masks where excluding != .mask(mask.id) {
            candidates.append(mask.start)
            candidates.append(mask.resolvedEnd(duration: duration))
        }
        return TimelineSnapper(candidates: candidates, tolerance: 8 / geometry.pixelsPerSecond * max(speed, 0.01))
    }

    private func scroll(_ proxy: ScrollViewProxy, toTime time: Double, atFraction fraction: CGFloat) {
        let index = Int((min(max(time, 0), geometry.duration) * Self.anchorsPerSecond).rounded())
        withAnimation(nil) {
            proxy.scrollTo(index, anchor: UnitPoint(x: min(max(fraction, 0), 1), y: 0))
        }
    }
}

// MARK: - Toolbar

private struct TimelineToolbar: View {
    let session: ProjectSession
    let geometry: TimelineGeometry
    let viewportWidth: CGFloat
    let scrollOffset: CGFloat
    let scrollTo: (Double, CGFloat) -> Void

    private var fitPixelsPerSecond: Double {
        TimelineGeometry.fit(duration: session.duration, width: max(viewportWidth, 200))
    }

    /// 0 = fit, 1 = maximum zoom, log scale in between.
    private var zoomLevel: Binding<Double> {
        Binding(
            get: {
                let fit = fitPixelsPerSecond
                guard session.timelinePixelsPerSecond > fit, TimelineGeometry.maximumPixelsPerSecond > fit else { return 0 }
                return log(session.timelinePixelsPerSecond / fit) / log(TimelineGeometry.maximumPixelsPerSecond / fit)
            },
            set: { level in setZoom(level: level) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            toolButton("Split", systemImage: "scissors", shortcut: "⌘B") { session.splitAtPlayhead() }
                .help("Split the clip at the playhead (⌘B)")
            toolButton("Delete", systemImage: "trash", shortcut: "⌫") { session.deleteSelection() }
                .disabled(session.selection == nil)
                .help("Delete the selected block (⌫)")
            Spacer()
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
            EditorSlider(value: zoomLevel, range: 0...1)
                .frame(width: 96)
                .help("Timeline zoom")
                .accessibilityLabel("Timeline zoom")
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(KettoTheme.secondaryInk)
            Button {
                session.timelinePixelsPerSecond = 0
            } label: {
                Text("Fit").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PillButtonStyle(height: 26))
            .help("Fit the whole edit in the window (⌘0)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func toolButton(_ title: String, systemImage: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .regular))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 13))
                    .foregroundStyle(KettoTheme.secondaryInk)
            }
            .foregroundStyle(KettoTheme.ink)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 14)
    }

    private func setZoom(level: Double) {
        let fit = fitPixelsPerSecond
        let level = min(max(level, 0), 1)
        // Keep the playhead where it is on screen across the zoom change.
        let playhead = session.player.currentTime
        let fraction = viewportWidth > 0 ? (geometry.x(playhead) - scrollOffset) / viewportWidth : 0.5
        if level < 0.001 {
            session.timelinePixelsPerSecond = 0
        } else {
            session.timelinePixelsPerSecond = fit * pow(TimelineGeometry.maximumPixelsPerSecond / fit, level)
        }
        if fraction >= 0, fraction <= 1 {
            scrollTo(playhead, fraction)
        }
    }
}

// MARK: - Playhead

private struct PlayheadTimecode: View {
    let session: ProjectSession

    var body: some View {
        Text(TransportBar.timecode(session.player.currentTime))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(KettoTheme.secondaryInk)
    }
}

private struct PlayheadView: View {
    let session: ProjectSession
    let geometry: TimelineGeometry
    let height: CGFloat

    var body: some View {
        let x = geometry.x(session.player.currentTime)
        ZStack(alignment: .top) {
            Rectangle()
                .fill(KettoTheme.ink)
                .frame(width: KettoTheme.line, height: height)
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 4.5, bottomTrailingRadius: 4.5, topTrailingRadius: 2, style: .continuous)
                .fill(KettoTheme.ink)
                .frame(width: 9, height: 11)
                .offset(y: EditorTimelineView.rulerHeight - 11)
        }
        .frame(width: 11, height: height, alignment: .top)
        .offset(x: x - 5)
        .allowsHitTesting(false)
    }
}

/// Scrolls the timeline along during playback when the playhead leaves the visible window.
private struct PlayheadFollower: View {
    let session: ProjectSession
    let geometry: TimelineGeometry
    let viewportWidth: CGFloat
    let scrollOffset: CGFloat
    let scrollTo: (Double, CGFloat) -> Void

    var body: some View {
        let time = session.player.currentTime
        let isPlaying = session.player.isPlaying
        Color.clear
            .frame(height: 0)
            .onChange(of: time) { _, now in
                guard isPlaying, viewportWidth > 0 else { return }
                let x = geometry.x(now) - scrollOffset
                if x < 0 || x > viewportWidth - 24 {
                    scrollTo(now, 0.1)
                }
            }
    }
}

// MARK: - Canvases

private struct RulerCanvas: View {
    let geometry: TimelineGeometry
    let scrollOffset: CGFloat
    let viewportWidth: CGFloat

    private static let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    var body: some View {
        Canvas { context, size in
            let pps = geometry.pixelsPerSecond
            let step = Self.steps.first { $0 * pps >= 80 } ?? Self.steps.last!
            let minor = step * pps / 5 >= 7 ? step / 5 : step / 2
            let startTime = max(0, geometry.time(scrollOffset))
            let endTime = min(geometry.duration, geometry.time(scrollOffset + size.width))
            guard endTime >= startTime else { return }
            var ticks = Path()
            var majors = Path()
            var t = (startTime / minor).rounded(.down) * minor
            while t <= endTime + 1e-9 {
                let x = geometry.x(t) - scrollOffset
                let isMajor = abs(t / step - (t / step).rounded()) < 1e-6
                if isMajor {
                    majors.move(to: CGPoint(x: x, y: size.height - 9))
                    majors.addLine(to: CGPoint(x: x, y: size.height))
                    let label = Text(Self.label(t, step: step)).font(.system(size: 10).monospacedDigit()).foregroundStyle(KettoTheme.secondaryInk)
                    context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                } else {
                    ticks.move(to: CGPoint(x: x, y: size.height - 4))
                    ticks.addLine(to: CGPoint(x: x, y: size.height))
                }
                t += minor
            }
            context.stroke(ticks, with: .color(KettoTheme.hairline), lineWidth: KettoTheme.line)
            context.stroke(majors, with: .color(KettoTheme.outline), lineWidth: KettoTheme.line)
            let baseline = Path(CGRect(x: 0, y: size.height - KettoTheme.line, width: size.width, height: KettoTheme.line))
            context.fill(baseline, with: .color(KettoTheme.hairline))
        }
    }

    static func label(_ t: Double, step: Double) -> String {
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        if step < 1 {
            return String(format: "%d:%04.1f", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, Int(seconds.rounded()))
    }
}

/// The filmstrip and the waveforms under the clips, in output time: each column maps through the timeline
/// to the recording, so cuts and speed changes show up as skips and compressions.
private struct MainTrackCanvas: View {
    let session: ProjectSession
    let geometry: TimelineGeometry
    let scrollOffset: CGFloat
    let viewportWidth: CGFloat
    let height: CGFloat

    var body: some View {
        let timeline = session.timeline
        let filmstrip = session.filmstrip
        let mic = session.micWaveform
        let system = session.systemWaveform
        Canvas { context, size in
            for segment in timeline.segments {
                let left = geometry.x(segment.outputStart) - scrollOffset
                let right = geometry.x(segment.outputEnd) - scrollOffset
                guard right > 0, left < size.width else { continue }
                let rect = CGRect(x: left, y: 0, width: right - left, height: size.height)
                var clipped = context
                clipped.clip(to: Path(roundedRect: rect.insetBy(dx: 1, dy: 0), cornerRadius: 8, style: .continuous))
                clipped.fill(Path(rect), with: .color(KettoTheme.fill))

                if let filmstrip {
                    let slotWidth = max(size.height * 16 / 9, 24)
                    let firstSlot = max(0, ((-left) / slotWidth).rounded(.down))
                    var slotX = left + firstSlot * slotWidth
                    var seams = Path()
                    while slotX < min(right, size.width) {
                        let outputTime = geometry.time(slotX + scrollOffset)
                        let sourceTime = segment.sourceTime(forOutput: min(max(outputTime, segment.outputStart), segment.outputEnd))
                        if let thumbnail = filmstrip.image(at: sourceTime) {
                            let image = Image(decorative: thumbnail.image, scale: 1)
                            let thumbnailAspect = CGFloat(thumbnail.image.width) / CGFloat(max(thumbnail.image.height, 1))
                            let drawWidth = size.height * thumbnailAspect
                            clipped.draw(image, in: CGRect(x: slotX, y: 0, width: drawWidth, height: size.height))
                        }
                        if slotX > left {
                            seams.addRect(CGRect(x: slotX, y: 0, width: KettoTheme.line, height: size.height))
                        }
                        slotX += slotWidth
                    }
                    // Thin seams between the frames, so the strip reads as a filmstrip rather than one smear.
                    clipped.fill(seams, with: .color(KettoTheme.fill))
                }

                // Waveforms: system audio faint underneath, the voice track on top.
                let columnStart = max(left, 0)
                let columnEnd = min(right, size.width)
                guard columnEnd > columnStart, mic != nil || system != nil else { continue }
                var micPath = Path()
                var systemPath = Path()
                var x = columnStart.rounded(.down)
                let midY = size.height * 0.5
                let amplitude = size.height * 0.42
                while x < columnEnd {
                    let t0 = min(max(geometry.time(x + scrollOffset), segment.outputStart), segment.outputEnd)
                    let t1 = min(max(geometry.time(x + 1 + scrollOffset), segment.outputStart), segment.outputEnd)
                    let s0 = segment.sourceTime(forOutput: t0)
                    let s1 = segment.sourceTime(forOutput: t1)
                    if let system {
                        let h = CGFloat(pow(Double(system.peak(from: s0, to: s1)), 0.7)) * amplitude
                        if h > 0.5 { systemPath.addRect(CGRect(x: x, y: midY - h, width: 1, height: 2 * h)) }
                    }
                    if let mic {
                        let h = CGFloat(pow(Double(mic.peak(from: s0, to: s1)), 0.7)) * amplitude
                        if h > 0.5 { micPath.addRect(CGRect(x: x, y: midY - h, width: 1, height: 2 * h)) }
                    }
                    x += 1
                }
                clipped.fill(systemPath, with: .color(KettoTheme.secondaryInk.opacity(0.3)))
                clipped.fill(micPath, with: .color(KettoTheme.accent.opacity(0.68)))
            }
        }
    }
}

// MARK: - Blocks

/// The invisible 8pt grab area at either end of a block, with a 1pt grip line in the middle.
private struct TrimHandle: View {
    let height: CGFloat
    var grip: Color = KettoTheme.secondaryInk.opacity(0.45)

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8, height: height)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(grip)
                    .frame(width: KettoTheme.line, height: min(max(height * 0.4, 8), 12))
            )
    }
}

/// The small round "+" beside a track's name.
private struct AddBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(KettoTheme.ink)
            .frame(width: 20, height: 20)
            .background(KettoTheme.fill, in: Circle())
            .contentShape(Circle())
    }
}

private struct ClipBlockView: View {
    let session: ProjectSession
    let segment: EditTimeline.Segment
    let geometry: TimelineGeometry
    let height: CGFloat
    let makeSnapper: (EditorSelection, Double) -> TimelineSnapper

    @State private var dragStart: Double?
    @State private var dragEnd: Double?
    @State private var snapper = TimelineSnapper(candidates: [], tolerance: 0)

    private var isSelected: Bool { session.selection == .clip(segment.clipID) }
    private var width: CGFloat { max(geometry.x(segment.outputDuration), 2) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? KettoTheme.accent : KettoTheme.hairline, lineWidth: KettoTheme.line)
                .background(isSelected ? KettoTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 1)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .onTapGesture { session.selection = .clip(segment.clipID) }
            if abs(segment.speed - 1) > 1e-6 {
                Text(Self.speedLabel(segment.speed))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(KettoTheme.ink, in: Capsule())
                    .foregroundStyle(KettoTheme.onInk)
                    .offset(x: 7, y: 6)
            }
            HStack(spacing: 0) {
                TrimHandle(height: height).gesture(trimGesture(leading: true))
                Spacer(minLength: 0)
                TrimHandle(height: height).gesture(trimGesture(leading: false))
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .help(Self.help(for: segment))
    }

    static func speedLabel(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    static func help(for segment: EditTimeline.Segment) -> String {
        "\(TransportBar.timecode(segment.sourceStart)) – \(TransportBar.timecode(segment.sourceEnd)) of the recording"
    }

    private func trimGesture(leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = segment.sourceStart
                    dragEnd = segment.sourceEnd
                    snapper = makeSnapper(.clip(segment.clipID), segment.speed)
                    session.beginGesture()
                    session.selection = .clip(segment.clipID)
                }
                let delta = geometry.time(value.translation.width) * segment.speed
                let duration = session.sourceDuration
                let id = segment.clipID
                if leading, let start = dragStart {
                    let target = snapper.snap(start + delta)
                    session.updateGesture { $0.trimClip(id: id, sourceStart: target, sourceDuration: duration) }
                } else if let end = dragEnd {
                    let target = snapper.snap(end + delta)
                    session.updateGesture { $0.trimClip(id: id, sourceEnd: target, sourceDuration: duration) }
                }
            }
            .onEnded { _ in
                session.endGesture()
                dragStart = nil
                dragEnd = nil
            }
    }
}

private struct ZoomBlockView: View {
    let session: ProjectSession
    let zoom: Zoom
    let geometry: TimelineGeometry
    let height: CGFloat
    let makeSnapper: (EditorSelection, Double) -> TimelineSnapper

    @State private var dragOrigin: Double?
    @State private var dragEnd: Double?
    @State private var snapper = TimelineSnapper(candidates: [], tolerance: 0)

    private var isSelected: Bool { session.selection == .zoom(zoom.id) }

    var body: some View {
        let timeline = session.timeline
        if let range = timeline.outputRange(sourceStart: zoom.start, sourceEnd: zoom.end) {
            let x = geometry.x(range.lowerBound)
            let width = max(geometry.x(range.upperBound - range.lowerBound), 6)
            let isSolid = zoom.userModified || isSelected
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSolid ? KettoTheme.manualZoom : KettoTheme.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isSolid ? Color.clear : KettoTheme.automaticZoom, lineWidth: KettoTheme.line)
                    )
                    .overlay(
                        // Selected: a 1pt inner line, so a selected manual zoom still reads apart from the others.
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(isSelected ? 0.85 : 0), lineWidth: KettoTheme.line)
                            .padding(2)
                    )
                Text(String(format: "%.1f×", zoom.scale))
                    .font(.system(size: 11, weight: isSolid ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSolid ? Color.white : KettoTheme.accentInk)
                    .padding(.leading, 9)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    TrimHandle(height: height, grip: isSolid ? Color.white.opacity(0.6) : KettoTheme.accentLine).gesture(trimGesture(leading: true))
                    Spacer(minLength: 0)
                    TrimHandle(height: height, grip: isSolid ? Color.white.opacity(0.6) : KettoTheme.accentLine).gesture(trimGesture(leading: false))
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { session.selection = .zoom(zoom.id) }
            .gesture(moveGesture)
            .offset(x: x)
            .help(zoom.userModified ? "Manual zoom" : "Automatic zoom")
        } else {
            // Inside a cut: a marker at the point where the cut happens, so the block can still be found.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 7, height: height)
                .overlay(Rectangle().fill(KettoTheme.accent).frame(width: KettoTheme.line))
                .offset(x: geometry.x(timeline.outputTime(forSource: zoom.start)) - 3)
                .contentShape(Rectangle())
                .onTapGesture { session.selection = .zoom(zoom.id) }
                .help("This zoom lies inside a cut")
        }
    }

    private var speed: Double {
        session.timeline.speed(atOutput: session.timeline.outputTime(forSource: zoom.start))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = zoom.start
                    snapper = makeSnapper(.zoom(zoom.id), speed)
                    session.beginGesture()
                    session.selection = .zoom(zoom.id)
                }
                guard let origin = dragOrigin else { return }
                let delta = geometry.time(value.translation.width) * speed
                let target = snapper.snapBlock(start: origin + delta, duration: zoom.duration)
                let limit = session.sourceDuration
                let id = zoom.id
                session.updateGesture { $0.moveZoom(id: id, toStart: target, limit: limit) }
            }
            .onEnded { _ in
                session.endGesture()
                dragOrigin = nil
            }
    }

    private func trimGesture(leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = zoom.start
                    dragEnd = zoom.end
                    snapper = makeSnapper(.zoom(zoom.id), speed)
                    session.beginGesture()
                    session.selection = .zoom(zoom.id)
                }
                let delta = geometry.time(value.translation.width) * speed
                let limit = session.sourceDuration
                let id = zoom.id
                if leading, let origin = dragOrigin {
                    let target = snapper.snap(origin + delta)
                    session.updateGesture { $0.trimZoom(id: id, start: target, limit: limit) }
                } else if let end = dragEnd {
                    let target = snapper.snap(end + delta)
                    session.updateGesture { $0.trimZoom(id: id, end: target, limit: limit) }
                }
            }
            .onEnded { _ in
                session.endGesture()
                dragOrigin = nil
                dragEnd = nil
            }
    }
}

private struct MaskBlockView: View {
    let session: ProjectSession
    let mask: Mask
    let geometry: TimelineGeometry
    let height: CGFloat
    let makeSnapper: (EditorSelection, Double) -> TimelineSnapper

    @State private var dragOrigin: Double?
    @State private var dragEnd: Double?
    @State private var snapper = TimelineSnapper(candidates: [], tolerance: 0)

    private var isSelected: Bool { session.selection == .mask(mask.id) }
    private var color: Color { mask.kind == .blur ? KettoTheme.blurMask : KettoTheme.highlightMask }
    private var isBlur: Bool { mask.kind == .blur }

    var body: some View {
        let timeline = session.timeline
        let end = mask.resolvedEnd(duration: session.sourceDuration)
        if let range = timeline.outputRange(sourceStart: mask.start, sourceEnd: max(end, mask.start + 0.05)) {
            let x = geometry.x(range.lowerBound)
            let width = max(geometry.x(range.upperBound - range.lowerBound), 6)
            ZStack(alignment: .leading) {
                // Blur is a lime block; highlight is a canvas block in an olive outline.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isBlur ? KettoTheme.blurMask : KettoTheme.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isBlur ? Color.clear : KettoTheme.highlightMask, lineWidth: KettoTheme.line)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(isBlur ? KettoTheme.onLime.opacity(isSelected ? 0.7 : 0) : KettoTheme.olive.opacity(isSelected ? 0.8 : 0), lineWidth: KettoTheme.line)
                            .padding(2)
                    )
                Text(isBlur ? "Blur" : "Highlight")
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isBlur ? Color(hex: 0x3F4D00) : KettoTheme.olive)
                    .padding(.leading, 9)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    TrimHandle(height: height, grip: isBlur ? Color(hex: 0x3F4D00).opacity(0.45) : KettoTheme.highlightMask).gesture(trimGesture(leading: true))
                    Spacer(minLength: 0)
                    if mask.end != nil {
                        TrimHandle(height: height, grip: isBlur ? Color(hex: 0x3F4D00).opacity(0.45) : KettoTheme.highlightMask).gesture(trimGesture(leading: false))
                    }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { session.selection = .mask(mask.id) }
            .gesture(moveGesture)
            .offset(x: x)
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 7, height: height)
                .overlay(Rectangle().fill(isBlur ? KettoTheme.olive : color).frame(width: KettoTheme.line))
                .offset(x: geometry.x(timeline.outputTime(forSource: mask.start)) - 3)
                .contentShape(Rectangle())
                .onTapGesture { session.selection = .mask(mask.id) }
        }
    }

    private var speed: Double {
        session.timeline.speed(atOutput: session.timeline.outputTime(forSource: mask.start))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = mask.start
                    dragEnd = mask.end
                    snapper = makeSnapper(.mask(mask.id), speed)
                    session.beginGesture()
                    session.selection = .mask(mask.id)
                }
                guard let origin = dragOrigin else { return }
                let delta = geometry.time(value.translation.width) * speed
                let length = (dragEnd ?? origin) - origin
                let start = max(0, snapper.snapBlock(start: origin + delta, duration: length))
                let id = mask.id
                session.updateGesture { doc in
                    doc.updateMask(id: id) { m in
                        m.start = start
                        if m.end != nil { m.end = start + length }
                    }
                }
            }
            .onEnded { _ in
                session.endGesture()
                dragOrigin = nil
                dragEnd = nil
            }
    }

    private func trimGesture(leading: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = mask.start
                    dragEnd = mask.end
                    snapper = makeSnapper(.mask(mask.id), speed)
                    session.beginGesture()
                    session.selection = .mask(mask.id)
                }
                let delta = geometry.time(value.translation.width) * speed
                let id = mask.id
                if leading, let origin = dragOrigin {
                    let end = dragEnd
                    let target = min(max(0, snapper.snap(origin + delta)), (end ?? .infinity) - 0.1)
                    session.updateGesture { doc in doc.updateMask(id: id) { $0.start = target } }
                } else if let end = dragEnd {
                    let start = dragOrigin ?? 0
                    let target = max(snapper.snap(end + delta), start + 0.1)
                    session.updateGesture { doc in doc.updateMask(id: id) { $0.end = target } }
                }
            }
            .onEnded { _ in
                session.endGesture()
                dragOrigin = nil
                dragEnd = nil
            }
    }
}
