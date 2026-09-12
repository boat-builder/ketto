import Foundation
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia

/// Peak levels of an audio file in fixed buckets of source time, for drawing a waveform.
struct Waveform: Equatable, Sendable {
    let bucketsPerSecond: Double
    /// Peak magnitude (0–1) per bucket.
    let peaks: [Float]

    static let empty = Waveform(bucketsPerSecond: 50, peaks: [])

    var duration: Double { Double(peaks.count) / bucketsPerSecond }

    /// The peak in the bucket containing source time `t`, or 0 outside the file.
    func peak(at t: Double) -> Float {
        guard !peaks.isEmpty, t >= 0 else { return 0 }
        let index = Int(t * bucketsPerSecond)
        return index < peaks.count ? peaks[index] : 0
    }

    /// The highest peak over a source-time range, for columns that cover several buckets.
    func peak(from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty, end > start else { return peak(at: start) }
        let first = max(0, Int(start * bucketsPerSecond))
        let last = min(peaks.count - 1, Int(end * bucketsPerSecond))
        guard first <= last else { return 0 }
        var result: Float = 0
        for i in first...last { result = max(result, peaks[i]) }
        return result
    }
}

enum WaveformLoader {
    /// Reads the whole file once, in chunks, and keeps the per-bucket peak over all channels. Synchronous —
    /// run it off the main actor.
    static func load(url: URL, bucketsPerSecond: Double = 50) throws -> Waveform {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let framesPerBucket = max(1, Int(sampleRate / max(bucketsPerSecond, 1)))
        let totalFrames = Int(file.length)
        var peaks = [Float](repeating: 0, count: max(0, (totalFrames + framesPerBucket - 1) / framesPerBucket))
        guard totalFrames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            return Waveform(bucketsPerSecond: bucketsPerSecond, peaks: peaks)
        }
        let channels = Int(format.channelCount)
        var position = 0
        while position < totalFrames {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            if let data = buffer.floatChannelData {
                for frame in 0..<count {
                    var magnitude: Float = 0
                    for channel in 0..<channels { magnitude = max(magnitude, abs(data[channel][frame])) }
                    let bucket = (position + frame) / framesPerBucket
                    if bucket < peaks.count, magnitude > peaks[bucket] { peaks[bucket] = min(magnitude, 1) }
                }
            }
            position += count
        }
        return Waveform(bucketsPerSecond: bucketsPerSecond, peaks: peaks)
    }
}

/// One filmstrip thumbnail. `CGImage` is immutable, so sharing it between the loader and the timeline is safe.
struct Thumbnail: @unchecked Sendable {
    let image: CGImage
}

/// Thumbnails of the recording at a fixed interval of source time, for the timeline's filmstrip.
struct Filmstrip: Sendable {
    let interval: Double
    /// `images[i]` shows source time `i * interval`; nil while it has not been generated.
    let images: [Thumbnail?]

    static let empty = Filmstrip(interval: 1, images: [])

    /// The thumbnail nearest to source time `t`, or the closest earlier one that exists.
    func image(at t: Double) -> Thumbnail? {
        guard !images.isEmpty else { return nil }
        var index = min(max(Int((t / interval).rounded()), 0), images.count - 1)
        while index >= 0 {
            if let image = images[index] { return image }
            index -= 1
        }
        return nil
    }

    /// Chooses an interval that keeps the count near `targetCount`, never finer than 0.5 s.
    static func interval(forDuration duration: Double, targetCount: Int = 120) -> Double {
        guard duration > 0 else { return 1 }
        let raw = duration / Double(max(targetCount, 1))
        let steps = [0.5, 1, 2, 3, 5, 10, 15, 20, 30, 60, 120, 300]
        return steps.first { $0 >= raw } ?? steps.last!
    }
}

enum FilmstripLoader {
    /// Generates thumbnails `height` pixels tall, delivering the filmstrip as it fills so the timeline can draw
    /// what exists. `progress` is called on the caller's task; the final call carries every image.
    static func load(url: URL, duration: Double, height: Int, targetCount: Int = 120, progress: @Sendable (Filmstrip) -> Void) async {
        let interval = Filmstrip.interval(forDuration: duration, targetCount: targetCount)
        let count = max(1, Int((duration / interval).rounded(.down)) + 1)
        var images = [Thumbnail?](repeating: nil, count: count)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: max(interval / 2, 0.25), preferredTimescale: 600)
        let times = (0..<count).map { CMTime(seconds: Double($0) * interval, preferredTimescale: 600) }
        var delivered = 0
        for await result in generator.images(for: times) {
            guard !Task.isCancelled else { return }
            let index = Int((result.requestedTime.seconds / interval).rounded())
            if index >= 0, index < count, let image = try? result.image {
                images[index] = Thumbnail(image: image)
            }
            delivered += 1
            if delivered % 8 == 0 { progress(Filmstrip(interval: interval, images: images)) }
        }
        progress(Filmstrip(interval: interval, images: images))
    }
}
