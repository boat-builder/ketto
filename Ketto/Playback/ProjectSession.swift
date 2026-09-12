import Foundation
import CoreGraphics
import Observation

/// What the timeline and the inspector are focused on.
enum EditorSelection: Equatable, Sendable {
    case zoom(String)
    case clip(String)
    case mask(String)
}

/// An open project in the editor: the bundle, its documents, the composer that turns them into frames, and the
/// preview player. Every change to `edit` rebuilds the composer immediately, autosaves `edit.json` shortly
/// after, and reloads the player when the edited timeline or the audio decisions changed. Changes are undoable:
/// `edit` assignments made in quick succession (a slider drag) coalesce into one step, `apply` is always one
/// step, and `beginGesture` / `endGesture` bracket a timeline drag into one step.
@Observable @MainActor
final class ProjectSession {
    enum AudioProcessingState: Equatable {
        case idle
        case running
        case failed(String)
    }

    let bundle: RecordingBundle
    let events: EventsDocument
    let source: SourceInfo
    let player: PreviewPlayer
    private(set) var composer: FrameComposer
    /// Set when the last autosave failed; cleared by the next successful one.
    private(set) var saveError: String?
    var selection: EditorSelection?
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var micWaveform: Waveform?
    private(set) var systemWaveform: Waveform?
    private(set) var filmstrip: Filmstrip?
    private(set) var audioProcessing: AudioProcessingState = .idle
    /// Timeline zoom in points per second of output time; 0 fits the whole edit to the window.
    var timelinePixelsPerSecond: Double = 0
    /// The zoom that fits the whole edit, reported by the timeline so menu commands can zoom relative to it.
    @ObservationIgnored var timelineFitPixelsPerSecond: Double = 0
    /// While editing the crop the preview shows the whole recording with the crop rectangle over it.
    private(set) var isEditingCrop = false
    private(set) var cropComposer: FrameComposer?

    private struct ZoomTimelineKey: Equatable {
        var zooms: [Zoom]
        var framing: ZoomFraming
        var cursorParameters: CursorSmoothingParameters
        var sourceDuration: Double
    }

    /// Backing storage for `edit`; observed through the `edit` accessor.
    private var editStorage: EditDocument
    @ObservationIgnored private var cursorTrack: CursorTrack
    @ObservationIgnored private var cursorTrackParameters: CursorSmoothingParameters
    @ObservationIgnored private var zoomTimelineCache: (key: ZoomTimelineKey, timeline: ZoomTimeline)?
    @ObservationIgnored private var undoStack: [EditDocument] = []
    @ObservationIgnored private var redoStack: [EditDocument] = []
    @ObservationIgnored private var gestureSnapshot: EditDocument?
    @ObservationIgnored private var lastCoalescedChange: TimeInterval = -1
    @ObservationIgnored private var cropAtEditStart: CropSpec?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var regenerateTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var filmstripTask: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var processedMicURL: URL?
    @ObservationIgnored private var processedOptions: AudioProcessor.Options?
    @ObservationIgnored private var mediaSourceDuration: Double = 0
    @ObservationIgnored private var loadedSource: PlaybackSource?

    private static let undoLimit = 200
    /// `edit` assignments closer together than this coalesce into one undo step.
    private static let coalesceInterval: TimeInterval = 0.8

    init(bundle: RecordingBundle) throws {
        self.bundle = bundle
        let events = try bundle.readEvents()
        let edit = bundle.readEdit()
        let source = SourceInfo(display: events.display)
        let parameters = FrameComposer.cursorParameters(for: edit)
        let track = CursorSmoother.smooth(events: events, parameters: parameters)
        let framing = FrameComposer.framing(edit: edit, source: source)
        let zoomTimeline = FrameComposer.makeZoomTimeline(edit: edit, events: events, source: source, cursorTrack: track, framing: framing)
        self.events = events
        self.source = source
        self.editStorage = edit
        self.cursorTrack = track
        self.cursorTrackParameters = parameters
        self.zoomTimelineCache = (ZoomTimelineKey(zooms: FrameComposer.activeZooms(in: edit), framing: framing, cursorParameters: parameters, sourceDuration: 0), zoomTimeline)
        self.composer = FrameComposer(edit: edit, events: events, source: source, cursorTrack: track, cameraAvailable: bundle.hasCameraTrack, zoomTimeline: zoomTimeline)
        self.player = PreviewPlayer()
        startLoading()
    }

    // MARK: - Documents

    /// The edit document. Assigning rebuilds the composer, schedules an autosave and records an undo step
    /// (coalesced with other assignments made within `coalesceInterval`).
    var edit: EditDocument {
        get { editStorage }
        set { commit(newValue, coalescing: true) }
    }

    /// Applies one undoable change.
    func apply(_ body: (inout EditDocument) -> Void) {
        var doc = editStorage
        body(&doc)
        commit(doc, coalescing: false)
    }

    /// Length of the edited timeline in seconds.
    var duration: Double { composer.duration }
    /// Length of the recording in seconds.
    var sourceDuration: Double { composer.sourceDuration }
    var timeline: EditTimeline { composer.timeline }
    var hasCameraTrack: Bool { bundle.hasCameraTrack }

    /// The composer the live preview draws: the crop editor's while the crop is being edited.
    var previewComposer: FrameComposer { isEditingCrop ? (cropComposer ?? composer) : composer }

    /// The processed voice track, when the audio options call for one and it has been produced.
    var processedVoiceURL: URL? {
        processedOptions == AudioProcessor.Options(editStorage.audio) ? processedMicURL : nil
    }

    /// Zooms the timeline in (`factor` > 1) or out around its current level.
    func zoomTimeline(by factor: Double) {
        let fit = max(timelineFitPixelsPerSecond, 1)
        let current = timelinePixelsPerSecond > 0 ? timelinePixelsPerSecond : fit
        let next = min(current * factor, TimelineGeometry.maximumPixelsPerSecond)
        timelinePixelsPerSecond = next <= fit * 1.001 ? 0 : next
    }

    /// The source time under the playhead.
    var playheadSourceTime: Double { composer.sourceTime(forOutput: player.currentTime) }

    var selectedZoom: Zoom? {
        guard case .zoom(let id) = selection else { return nil }
        return editStorage.zooms.first { $0.id == id }
    }

    var selectedClip: Clip? {
        guard case .clip(let id) = selection else { return nil }
        return editStorage.resolvedClips(sourceDuration: sourceDuration).first { $0.id == id }
    }

    var selectedMask: Mask? {
        guard case .mask(let id) = selection else { return nil }
        return editStorage.masks.first { $0.id == id }
    }

    private func commit(_ newValue: EditDocument, coalescing: Bool) {
        guard newValue != editStorage else { return }
        if gestureSnapshot == nil {
            let now = ProcessInfo.processInfo.systemUptime
            let coalesce = coalescing && now - lastCoalescedChange < Self.coalesceInterval && !undoStack.isEmpty
            if !coalesce { pushUndo(editStorage) }
            lastCoalescedChange = coalescing ? now : -1
        }
        replaceEdit(newValue)
    }

    /// Installs a document without touching the undo stacks.
    private func replaceEdit(_ newValue: EditDocument) {
        let old = editStorage
        let previousTimeline = composer.timeline
        editStorage = newValue
        rebuildComposer()
        scheduleSave()
        if composer.timeline != previousTimeline || old.audio != newValue.audio {
            schedulePlayerReload()
        }
        if AudioProcessor.Options(old.audio) != AudioProcessor.Options(newValue.audio) {
            updateAudioProcessing()
        }
    }

    private func rebuildComposer() {
        let edit = editStorage
        let parameters = FrameComposer.cursorParameters(for: edit)
        if parameters != cursorTrackParameters {
            cursorTrack = CursorSmoother.smooth(events: events, parameters: parameters)
            cursorTrackParameters = parameters
        }
        let framing = FrameComposer.framing(edit: edit, source: source)
        let key = ZoomTimelineKey(zooms: FrameComposer.activeZooms(in: edit), framing: framing, cursorParameters: parameters, sourceDuration: mediaSourceDuration)
        let zoomTimeline: ZoomTimeline
        if let cache = zoomTimelineCache, cache.key == key {
            zoomTimeline = cache.timeline
        } else {
            zoomTimeline = FrameComposer.makeZoomTimeline(edit: edit, events: events, source: source, cursorTrack: cursorTrack, framing: framing, sourceDuration: mediaSourceDuration)
            zoomTimelineCache = (key, zoomTimeline)
        }
        composer = FrameComposer(edit: edit, events: events, source: source, cursorTrack: cursorTrack, cameraAvailable: bundle.hasCameraTrack, zoomTimeline: zoomTimeline, sourceDuration: mediaSourceDuration)
        if isEditingCrop { rebuildCropComposer() }
    }

    // MARK: - Undo

    private func pushUndo(_ document: EditDocument) {
        undoStack.append(document)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
        updateUndoState()
    }

    private func updateUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        endGesture()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(editStorage)
        lastCoalescedChange = -1
        replaceEdit(previous)
        updateUndoState()
    }

    func redo() {
        endGesture()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(editStorage)
        lastCoalescedChange = -1
        replaceEdit(next)
        updateUndoState()
    }

    /// Starts a drag: every `updateGesture` until `endGesture` becomes a single undo step.
    func beginGesture() {
        guard gestureSnapshot == nil else { return }
        gestureSnapshot = editStorage
    }

    func updateGesture(_ body: (inout EditDocument) -> Void) {
        if gestureSnapshot == nil { beginGesture() }
        var doc = editStorage
        body(&doc)
        commit(doc, coalescing: false)
    }

    func endGesture() {
        guard let snapshot = gestureSnapshot else { return }
        gestureSnapshot = nil
        if snapshot != editStorage { pushUndo(snapshot) }
        lastCoalescedChange = -1
    }

    // MARK: - Zooms

    /// Re-runs auto-zoom generation for the current framing and intensity. User-modified zooms are preserved.
    func regenerateZooms() {
        regenerateTask?.cancel()
        regenerateTask = nil
        var doc = editStorage
        doc.zooms = regeneratedZooms(for: doc)
        commit(doc, coalescing: true)
    }

    private func regeneratedZooms(for doc: EditDocument) -> [Zoom] {
        let generator = AutoZoomGenerator(parameters: AutoZoomParameters(intensity: doc.autoZoom.intensity))
        return generator.generate(events: events, existing: doc.zooms, framing: FrameComposer.framing(edit: doc, source: source))
    }

    /// Updates the intensity immediately (so the inspector tracks the slider) and regenerates shortly after the
    /// slider settles, in the same undo step.
    func setZoomIntensity(_ intensity: Double) {
        var doc = editStorage
        doc.autoZoom.intensity = intensity
        edit = doc
        regenerateTask?.cancel()
        regenerateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.regenerateZooms()
        }
    }

    /// Adds a manual zoom at the playhead, aimed at the cursor, and selects it.
    func addZoomAtPlayhead() {
        let t = playheadSourceTime
        let target = composer.cursorPosition(atSource: t) ?? SIMD2(0.5, 0.5)
        let scale = composer.framing.attenuated(scale: AutoZoomParameters(intensity: editStorage.autoZoom.intensity).zoomScale)
        var added: Zoom?
        apply { doc in
            var start = t
            if let covering = doc.zooms.first(where: { $0.start <= start && $0.end > start }) { start = covering.end }
            let nextStart = doc.zooms.map(\.start).filter { $0 > start }.min() ?? .infinity
            let duration = min(3, max(nextStart - start, EditDocument.minimumZoomDuration))
            added = doc.addZoom(start: start, duration: duration, target: target, scale: scale)
        }
        if let added { selection = .zoom(added.id) }
    }

    // MARK: - Masks

    /// Adds a mask in the middle of the current view, starting at the playhead, and selects it.
    func addMask(kind: MaskKind) {
        let t = playheadSourceTime
        let viewport = composer.zoomTimeline.viewport(at: t)
        let rect = CGRect(
            x: viewport.center.x - viewport.size.x * 0.15, y: viewport.center.y - viewport.size.y * 0.15,
            width: viewport.size.x * 0.3, height: viewport.size.y * 0.3
        )
        var added: Mask?
        apply { doc in added = doc.addMask(kind: kind, rect: rect, start: t) }
        if let added { selection = .mask(added.id) }
    }

    // MARK: - Main track

    /// Splits the clip under the playhead and selects the right half.
    func splitAtPlayhead() {
        let t = playheadSourceTime
        let duration = sourceDuration
        var halves: (left: String, right: String)?
        apply { doc in halves = doc.splitClip(atSource: t, sourceDuration: duration) }
        if let halves { selection = .clip(halves.right) }
    }

    func joinSelectedClipWithNext() {
        guard case .clip(let id) = selection else { return }
        let duration = sourceDuration
        apply { doc in doc.joinClipWithNext(id: id, sourceDuration: duration) }
    }

    func setClipSpeed(id: String, speed: Double) {
        let duration = sourceDuration
        apply { doc in doc.setClipSpeed(id: id, speed: speed, sourceDuration: duration) }
    }

    /// Deletes whatever is selected: a zoom, a mask or a clip (which becomes a cut).
    func deleteSelection() {
        guard let selection else { return }
        let duration = sourceDuration
        apply { doc in
            switch selection {
            case .zoom(let id): doc.deleteZoom(id: id)
            case .mask(let id): doc.deleteMask(id: id)
            case .clip(let id): doc.deleteClip(id: id, sourceDuration: duration)
            }
        }
        self.selection = nil
    }

    // MARK: - Canvas and crop

    /// Applies an aspect preset and re-optimises the automatic zooms for it.
    func applyCanvasPreset(_ name: String) {
        apply { doc in
            doc.applyCanvasPreset(name)
            doc.zooms = regeneratedZooms(for: doc)
        }
    }

    func setFraming(_ framing: FramingMode) {
        apply { doc in
            doc.canvas.framing = framing
            doc.zooms = regeneratedZooms(for: doc)
        }
    }

    func beginCropEditing() {
        guard !isEditingCrop else { return }
        player.pause()
        cropAtEditStart = editStorage.crop
        isEditingCrop = true
        rebuildCropComposer()
    }

    /// Leaves crop editing; when the crop changed, the automatic zooms are re-optimised for it.
    func endCropEditing() {
        guard isEditingCrop else { return }
        endGesture()
        isEditingCrop = false
        cropComposer = nil
        if let before = cropAtEditStart, before != editStorage.crop {
            var doc = editStorage
            doc.zooms = regeneratedZooms(for: doc)
            commit(doc, coalescing: false)
        }
        cropAtEditStart = nil
    }

    func resetCrop() {
        apply { doc in
            doc.crop = .full
            doc.zooms = regeneratedZooms(for: doc)
        }
    }

    private func rebuildCropComposer() {
        var doc = editStorage
        doc.crop = .full
        doc.canvas.framing = .fit
        doc.zooms = []
        cropComposer = FrameComposer(edit: doc, events: events, source: source, cursorTrack: cursorTrack, cameraAvailable: false, sourceDuration: mediaSourceDuration)
    }

    // MARK: - Playback

    private var playbackSource: PlaybackSource {
        PlaybackSource(bundle: bundle, timeline: composer.timeline, audio: editStorage.audio, micURL: processedMicURL)
    }

    private func startLoading() {
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadPlayer()
        }
        let micURL = bundle.hasMicTrack ? bundle.micURL : nil
        let systemURL = bundle.hasSystemAudioTrack ? bundle.systemAudioURL : nil
        analysisTask = Task { [weak self] in
            let mic = await Self.loadWaveform(micURL)
            let system = await Self.loadWaveform(systemURL)
            guard let self, !Task.isCancelled else { return }
            self.micWaveform = mic
            self.systemWaveform = system
        }
        let screenURL = bundle.screenURL
        let duration = events.duration
        filmstripTask = Task { [weak self] in
            await FilmstripLoader.load(url: screenURL, duration: duration, height: 96) { strip in
                Task { @MainActor in self?.filmstrip = strip }
            }
        }
        updateAudioProcessing()
    }

    private nonisolated static func loadWaveform(_ url: URL?) async -> Waveform? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) { try? WaveformLoader.load(url: url) }.value
    }

    private func schedulePlayerReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.reloadPlayer()
        }
    }

    /// Loads the player with the current source, keeping the playhead on the same recording moment when the
    /// timeline changed underneath it.
    private func reloadPlayer() async {
        let source = playbackSource
        guard source != loadedSource else { return }
        var target: Double?
        if let previous = loadedSource?.timeline, previous != source.timeline {
            target = source.timeline.outputTime(forSource: previous.sourceTime(forOutput: player.currentTime))
        }
        loadedSource = source
        await player.load(source, seekTo: target)
        if player.sourceDuration > mediaSourceDuration + 1e-3 {
            mediaSourceDuration = player.sourceDuration
            let previousTimeline = composer.timeline
            rebuildComposer()
            if composer.timeline != previousTimeline { schedulePlayerReload() }
        }
    }

    // MARK: - Audio processing

    private func updateAudioProcessing() {
        let options = AudioProcessor.Options(editStorage.audio)
        guard bundle.hasMicTrack, !options.isIdentity else {
            audioTask?.cancel()
            audioTask = nil
            if case .running = audioProcessing { audioProcessing = .idle }
            if processedMicURL != nil {
                processedMicURL = nil
                processedOptions = nil
                schedulePlayerReload()
            }
            return
        }
        if processedOptions == options, processedMicURL != nil { return }
        let url = AudioProcessor.derivedURL(for: bundle, options: options)
        if FileManager.default.fileExists(atPath: url.path) {
            processedMicURL = url
            processedOptions = options
            audioProcessing = .idle
            schedulePlayerReload()
            return
        }
        audioTask?.cancel()
        audioProcessing = .running
        let micURL = bundle.micURL
        audioTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
                do {
                    try AudioProcessor.process(micURL: micURL, to: url, options: options)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled, AudioProcessor.Options(self.editStorage.audio) == options else { return }
            switch result {
            case .success:
                self.processedMicURL = url
                self.processedOptions = options
                self.audioProcessing = .idle
                self.schedulePlayerReload()
            case .failure(let error):
                self.audioProcessing = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    /// Writes `edit.json` if there are unsaved changes.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        do {
            try bundle.write(edit: editStorage)
            isDirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Flushes pending work and releases the player. Call before discarding the session.
    func close() {
        regenerateTask?.cancel()
        loadTask?.cancel()
        reloadTask?.cancel()
        analysisTask?.cancel()
        filmstripTask?.cancel()
        audioTask?.cancel()
        saveNow()
        player.invalidate()
    }
}
