import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// What the player and the exporter play: the media files and the edited timeline laid over them. One value
/// describes both, so the preview and the export cannot disagree about cuts, speed or volumes.
struct PlaybackSource: Equatable, Sendable {
    var screenURL: URL
    /// The voice track — the processed derived file when noise removal or normalisation is on.
    var micURL: URL?
    var systemAudioURL: URL?
    var cameraURL: URL?
    var timeline: EditTimeline
    var micVolume: Double
    var systemVolume: Double

    init(bundle: RecordingBundle, timeline: EditTimeline, audio: AudioSpec, micURL: URL? = nil) {
        screenURL = bundle.screenURL
        self.micURL = micURL ?? (bundle.hasMicTrack ? bundle.micURL : nil)
        systemAudioURL = bundle.hasSystemAudioTrack ? bundle.systemAudioURL : nil
        cameraURL = bundle.hasCameraTrack ? bundle.cameraURL : nil
        self.timeline = timeline
        micVolume = min(max(audio.micVolume, 0), 2)
        systemVolume = min(max(audio.systemVolume, 0), 2)
    }
}

/// Builds `AVMutableComposition`s that play the *edited* timeline: every clip of the recording is inserted at
/// its output position and retimed for its speed. `screen.mov`, the audio tracks and `camera.mov` all go
/// through `insert(track:trackRange:into:timeline:)`, so they stay aligned with each other and with what
/// `FrameComposer` draws for the same output time.
enum CompositionBuilder {
    /// Composition timescale. Divides every frame rate the app records or exports and the audio sample rate.
    static let timescale: CMTimeScale = 48_000

    struct ScreenMedia {
        let composition: AVMutableComposition
        let audioMix: AVAudioMix?
        var hasAudio: Bool { audioMix != nil }
        /// Length of `screen.mov` in seconds.
        let sourceDuration: Double
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds.isFinite ? seconds : 0), preferredTimescale: timescale)
    }

    /// `screen.mov` plus the audio tracks, cut and retimed per the timeline; volumes applied through the mix.
    static func screenMedia(for source: PlaybackSource) async throws -> ScreenMedia {
        let screenAsset = AVURLAsset(url: source.screenURL)
        guard let videoTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw RecordingBundleError.missingScreenRecording(source.screenURL)
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let assetDuration = try await screenAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingBundleError.missingScreenRecording(source.screenURL)
        }
        let sourceDuration = assetDuration.isNumeric ? assetDuration.seconds : videoRange.end.seconds
        let timeline = source.timeline.segments.isEmpty ? EditTimeline.identity(duration: sourceDuration) : source.timeline
        try insert(track: videoTrack, trackRange: videoRange, into: compositionVideo, timeline: timeline)

        var parameters: [AVMutableAudioMixInputParameters] = []
        for (url, volume) in [(source.micURL, source.micVolume), (source.systemAudioURL, source.systemVolume)] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let range = try await track.load(.timeRange)
            guard range.duration.seconds > 0,
                  let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try insert(track: track, trackRange: range, into: compositionAudio, timeline: timeline)
            let input = AVMutableAudioMixInputParameters(track: compositionAudio)
            input.setVolume(Float(volume), at: .zero)
            parameters.append(input)
        }
        var audioMix: AVMutableAudioMix?
        if !parameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = parameters
            audioMix = mix
        }
        return ScreenMedia(composition: composition, audioMix: audioMix, sourceDuration: sourceDuration)
    }

    /// `camera.mov` on the same output timeline, or nil when the recording has no camera track.
    static func cameraComposition(for source: PlaybackSource) async throws -> AVMutableComposition? {
        guard let url = source.cameraURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let range = try await track.load(.timeRange)
        guard range.duration.seconds > 0 else { return nil }
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let timeline = source.timeline.segments.isEmpty ? EditTimeline.identity(duration: range.end.seconds) : source.timeline
        try insert(track: track, trackRange: range, into: compositionTrack, timeline: timeline)
        return composition
    }

    /// Lays the timeline's segments of `track` end to end on `compositionTrack`, retiming the ones whose speed
    /// is not 1. Parts of a segment the track does not cover (an audio file shorter than the video, a camera
    /// that started late) become empty edits, so the tracks never drift against each other.
    static func insert(track: AVAssetTrack, trackRange: CMTimeRange, into compositionTrack: AVMutableCompositionTrack, timeline: EditTimeline) throws {
        let trackStart = trackRange.start.seconds
        let trackEnd = trackRange.end.seconds
        var currentEnd = CMTime.zero
        for segment in timeline.segments {
            let start = max(segment.sourceStart, trackStart)
            let end = min(segment.sourceEnd, trackEnd)
            guard end - start > 1e-4 else { continue }
            let outputStart = segment.outputStart + (start - segment.sourceStart) / segment.speed
            let at = time(outputStart)
            if at > currentEnd + CMTime(value: 1, timescale: timescale) {
                compositionTrack.insertEmptyTimeRange(CMTimeRange(start: currentEnd, end: at))
            }
            let sourceRange = CMTimeRange(start: time(start), end: time(end))
            try compositionTrack.insertTimeRange(sourceRange, of: track, at: at)
            var outputDuration = sourceRange.duration
            if abs(segment.speed - 1) > 1e-6 {
                outputDuration = time((end - start) / segment.speed)
                compositionTrack.scaleTimeRange(CMTimeRange(start: at, duration: sourceRange.duration), toDuration: outputDuration)
            }
            currentEnd = at + outputDuration
        }
    }
}
