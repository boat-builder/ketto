import Foundation
import Observation

/// An open project in the editor: the bundle, its documents, the composer that turns them into frames, and the
/// preview player. Every change to `edit` rebuilds the composer immediately and autosaves `edit.json` shortly after.
@Observable @MainActor
final class ProjectSession {
    let bundle: RecordingBundle
    let events: EventsDocument
    let source: SourceInfo
    let player: PreviewPlayer
    private(set) var composer: FrameComposer
    /// Set when the last autosave failed; cleared by the next successful one.
    private(set) var saveError: String?

    /// Backing storage for `edit`; observed through the `edit` accessor.
    private var editStorage: EditDocument
    @ObservationIgnored private var cursorTrack: CursorTrack
    @ObservationIgnored private var cursorTrackParameters: CursorSmoothingParameters
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var regenerateTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isDirty = false

    init(bundle: RecordingBundle) throws {
        self.bundle = bundle
        let events = try bundle.readEvents()
        let edit = bundle.readEdit()
        let source = SourceInfo(display: events.display)
        let parameters = FrameComposer.cursorParameters(for: edit)
        let track = CursorSmoother.smooth(events: events, parameters: parameters)
        self.events = events
        self.source = source
        self.editStorage = edit
        self.cursorTrack = track
        self.cursorTrackParameters = parameters
        self.composer = FrameComposer(edit: edit, events: events, source: source, cursorTrack: track)
        self.player = PreviewPlayer()
        loadTask = Task { [player, bundle] in
            await player.load(bundle: bundle)
        }
    }

    /// The edit document. Assigning rebuilds the composer and schedules an autosave.
    var edit: EditDocument {
        get { editStorage }
        set {
            guard newValue != editStorage else { return }
            editStorage = newValue
            rebuildComposer()
            scheduleSave()
        }
    }

    var duration: Double { max(events.duration, player.duration) }

    private func rebuildComposer() {
        let parameters = FrameComposer.cursorParameters(for: editStorage)
        if parameters != cursorTrackParameters {
            cursorTrack = CursorSmoother.smooth(events: events, parameters: parameters)
            cursorTrackParameters = parameters
        }
        composer = FrameComposer(edit: editStorage, events: events, source: source, cursorTrack: cursorTrack)
    }

    // MARK: - Zooms

    /// Re-runs auto-zoom generation with the document's current intensity. User-modified zooms are preserved.
    func regenerateZooms() {
        regenerateTask?.cancel()
        regenerateTask = nil
        var doc = editStorage
        let generator = AutoZoomGenerator(parameters: AutoZoomParameters(intensity: doc.autoZoom.intensity))
        doc.zooms = generator.generate(events: events, existing: doc.zooms)
        edit = doc
    }

    /// Updates the intensity immediately (so the inspector tracks the slider) and regenerates shortly after the
    /// slider settles.
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
        saveNow()
        player.invalidate()
    }
}
