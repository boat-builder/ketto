import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Observation
import QuartzCore

/// Plays a `.ketto` bundle for the editor on the *edited* timeline: `screen.mov`, `mic.caf` and `system.caf`
/// are combined in an `AVMutableComposition` built by `CompositionBuilder` (cuts and speed applied there, the
/// audio mixed for monitoring only, never on disk). `camera.mov`, when present, plays in a second player on the
/// same clock. Decoded frames are pulled through `AVPlayerItemVideoOutput`s by the Metal preview on its
/// display link. All times exposed here are output (edited) seconds.
@Observable @MainActor
final class PreviewPlayer {
    /// Length of the edited timeline in seconds.
    private(set) var duration: Double = 0
    /// Playhead position in seconds, updated by the periodic observer and by seeks.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    /// True once the player item has produced its first frame.
    private(set) var hasProducedFrame = false
    private(set) var loadError: String?
    /// Length of `screen.mov` in seconds, known once the first load finished.
    private(set) var sourceDuration: Double = 0
    /// True when a camera track is loaded alongside the screen recording.
    private(set) var hasCamera = false
    /// True while a (re)load is in flight.
    private(set) var isLoading = false

    private let player = AVPlayer()
    private let cameraPlayer = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private let cameraOutput: AVPlayerItemVideoOutput
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var cameraItem: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var consecutiveMisses = 0
    @ObservationIgnored private var loadGeneration = 0

    init() {
        output = Self.makeOutput()
        cameraOutput = Self.makeOutput()
        for player in [player, cameraPlayer] {
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.sourceClock = CMClockGetHostTimeClock()
        }
        cameraPlayer.isMuted = true
    }

    private static func makeOutput() -> AVPlayerItemVideoOutput {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        output.suppressesPlayerRendering = true
        return output
    }

    /// Builds the compositions for `source` and installs them. Reloading keeps the playhead where it is (the
    /// caller maps the position onto the new timeline through `seekTo`) and resumes if it was playing.
    /// A load that is superseded by a newer one before it finishes is dropped.
    func load(_ source: PlaybackSource, seekTo time: Double? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        isLoading = true
        do {
            let media = try await CompositionBuilder.screenMedia(for: source)
            let camera = try await CompositionBuilder.cameraComposition(for: source)
            guard generation == loadGeneration else { return }

            item?.remove(output)
            cameraItem?.remove(cameraOutput)
            let item = AVPlayerItem(asset: media.composition)
            item.audioMix = media.audioMix
            item.audioTimePitchAlgorithm = .spectral
            item.add(output)
            self.item = item
            sourceDuration = media.sourceDuration
            let timelineDuration = source.timeline.outputDuration
            duration = timelineDuration > 0 ? timelineDuration : media.composition.duration.seconds
            player.replaceCurrentItem(with: item)
            installObservers(for: item)

            if let camera {
                let cameraItem = AVPlayerItem(asset: camera)
                cameraItem.add(cameraOutput)
                self.cameraItem = cameraItem
                cameraPlayer.replaceCurrentItem(with: cameraItem)
                hasCamera = true
            } else {
                cameraItem = nil
                cameraPlayer.replaceCurrentItem(with: nil)
                hasCamera = false
            }

            seek(to: time ?? currentTime)
            loadError = nil
            isLoading = false
            if wasPlaying { play() }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    private func installObservers(for item: AVPlayerItem) {
        removeObservers()
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isLoading else { return }
                self.currentTime = min(max(time.seconds, 0), max(self.duration, 0))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameraPlayer.pause()
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Tears the players down. The session calls this when the project closes.
    func invalidate() {
        pause()
        loadGeneration += 1
        removeObservers()
        item?.remove(output)
        cameraItem?.remove(cameraOutput)
        player.replaceCurrentItem(with: nil)
        cameraPlayer.replaceCurrentItem(with: nil)
        item = nil
        cameraItem = nil
        hasCamera = false
    }

    // MARK: - Transport

    func play() {
        guard item != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        if cameraItem != nil {
            // Both players start at the same host time so the camera never drifts against the screen.
            let startAt = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 25)
            player.setRate(1, time: .invalid, atHostTime: startAt)
            cameraPlayer.setRate(1, time: .invalid, atHostTime: startAt)
        } else {
            player.play()
        }
        isPlaying = true
    }

    func pause() {
        player.pause()
        cameraPlayer.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    /// Frame-accurate seek; the video outputs produce the exact frame for `seconds` once the seek completes.
    func seek(to seconds: Double) {
        let clamped = min(max(seconds.isFinite ? seconds : 0, 0), max(duration, 0))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: CompositionBuilder.timescale)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        if cameraItem != nil {
            cameraPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            cameraOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        }
    }

    func step(by frames: Int, fps: Double = 60) {
        pause()
        seek(to: currentTime + Double(frames) / max(fps, 1))
    }

    /// Scrubbing pauses playback for the duration of the drag and resumes afterwards.
    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        if isPlaying { pause() }
    }

    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrub { play() }
        resumeAfterScrub = false
    }

    // MARK: - Frames

    struct Frame {
        /// Item (output) time the displayed frame corresponds to, in seconds.
        var time: Double
        /// A newly decoded screen frame for `time`, or nil when the previously delivered frame is still current.
        var pixelBuffer: CVPixelBuffer?
        /// A newly decoded camera frame, or nil when the previous one is still current (or there is no camera).
        var cameraPixelBuffer: CVPixelBuffer?
    }

    /// Called from the preview's display link. Returns the item time to render and, when an output has a new
    /// frame for it, the decoded pixel buffer.
    func pollFrame(hostTime: CFTimeInterval) -> Frame {
        guard item != nil else { return Frame(time: currentTime, pixelBuffer: nil, cameraPixelBuffer: nil) }
        var itemTime = output.itemTime(forHostTime: hostTime)
        if !itemTime.isValid || itemTime.isIndefinite {
            itemTime = player.currentTime()
        }
        let seconds = itemTime.isValid && itemTime.isNumeric ? min(max(itemTime.seconds, 0), max(duration, 0)) : currentTime
        var frame = Frame(time: seconds, pixelBuffer: nil, cameraPixelBuffer: nil)
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            consecutiveMisses = 0
            if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                if !hasProducedFrame { hasProducedFrame = true }
                frame.pixelBuffer = buffer
            }
        } else {
            consecutiveMisses += 1
            // The output goes dormant when it thinks nobody is consuming frames; re-arm it after a quiet spell.
            if consecutiveMisses == 60 || (isPlaying && consecutiveMisses % 30 == 0) {
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
                if cameraItem != nil { cameraOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1) }
            }
        }
        if cameraItem != nil {
            var cameraTime = cameraOutput.itemTime(forHostTime: hostTime)
            if !cameraTime.isValid || cameraTime.isIndefinite { cameraTime = cameraPlayer.currentTime() }
            if cameraOutput.hasNewPixelBuffer(forItemTime: cameraTime) {
                frame.cameraPixelBuffer = cameraOutput.copyPixelBuffer(forItemTime: cameraTime, itemTimeForDisplay: nil)
            }
        }
        return frame
    }
}
