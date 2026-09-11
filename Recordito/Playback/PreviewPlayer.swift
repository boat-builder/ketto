import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Observation
import QuartzCore

/// Plays a `.recordito` bundle for the editor: `screen.mov` plus `mic.caf` and `system.caf` are combined in an
/// `AVMutableComposition` at playback time (the audio is mixed for monitoring only, never on disk).
/// Decoded frames are pulled through an `AVPlayerItemVideoOutput` by the Metal preview on its display link.
@Observable @MainActor
final class PreviewPlayer {
    /// Length of the video track in seconds.
    private(set) var duration: Double = 0
    /// Playhead position in seconds, updated by the periodic observer and by seeks.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    /// True once the player item has produced its first frame.
    private(set) var hasProducedFrame = false
    private(set) var loadError: String?

    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var consecutiveMisses = 0

    init() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        output.suppressesPlayerRendering = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// Builds the composition and installs it in the player. Safe to call once per bundle.
    func load(bundle: RecordingBundle) async {
        do {
            let composition = AVMutableComposition()
            let screenAsset = AVURLAsset(url: bundle.screenURL)
            let videoTracks = try await screenAsset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { throw RecordingBundleError.missingScreenRecording(bundle.url) }
            let videoDuration = try await screenAsset.load(.duration)
            guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RecordingBundleError.missingScreenRecording(bundle.url)
            }
            try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)

            for url in [bundle.micURL, bundle.systemAudioURL] where FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let audioDuration = try await asset.load(.duration)
                let length = CMTimeMinimum(audioDuration, videoDuration)
                guard length.seconds > 0,
                      let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
            }

            let item = AVPlayerItem(asset: composition)
            item.add(output)
            self.item = item
            duration = videoDuration.seconds
            player.replaceCurrentItem(with: item)
            installObservers(for: item)
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func installObservers(for item: AVPlayerItem) {
        removeObservers()
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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

    /// Tears the player down. The session calls this when the project closes.
    func invalidate() {
        pause()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        item = nil
    }

    // MARK: - Transport

    func play() {
        guard item != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying { pause() } else { play() }
    }

    /// Frame-accurate seek; the video output produces the exact frame for `seconds` once the seek completes.
    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTime = clamped
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
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
        /// Item time the displayed frame corresponds to, in seconds.
        var time: Double
        /// A newly decoded frame for `time`, or nil when the previously delivered frame is still current.
        var pixelBuffer: CVPixelBuffer?
    }

    /// Called from the preview's display link. Returns the item time to render and, when the output has a new
    /// frame for it, the decoded pixel buffer.
    func pollFrame(hostTime: CFTimeInterval) -> Frame {
        guard item != nil else { return Frame(time: currentTime, pixelBuffer: nil) }
        var itemTime = output.itemTime(forHostTime: hostTime)
        if !itemTime.isValid || itemTime.isIndefinite {
            itemTime = player.currentTime()
        }
        let seconds = itemTime.isValid && itemTime.isNumeric ? min(max(itemTime.seconds, 0), max(duration, 0)) : currentTime
        if output.hasNewPixelBuffer(forItemTime: itemTime) {
            consecutiveMisses = 0
            if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                if !hasProducedFrame { hasProducedFrame = true }
                return Frame(time: seconds, pixelBuffer: buffer)
            }
        } else {
            consecutiveMisses += 1
            // The output goes dormant when it thinks nobody is consuming frames; re-arm it after a quiet spell.
            if consecutiveMisses == 60 || (isPlaying && consecutiveMisses % 30 == 0) {
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.1)
            }
        }
        return Frame(time: seconds, pixelBuffer: nil)
    }
}
