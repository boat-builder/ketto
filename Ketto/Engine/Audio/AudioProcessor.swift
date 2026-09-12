import Foundation
@preconcurrency import AVFoundation

/// Produces the processed voice track the player and the exporter use when noise removal or normalisation is
/// on. The result is a derived file next to the source media (`derived/mic-nr1-norm1.caf`); `mic.caf` itself
/// is never rewritten, and the derived file is rebuilt from it whenever it is missing.
///
/// Three passes over the file, none of which holds more than a chunk in memory: learn the noise floor, write
/// the denoised track (measuring its loudness on the way), then apply the normalisation gain.
enum AudioProcessor {
    struct Options: Hashable, Sendable {
        var noiseRemoval: Bool
        var normalize: Bool

        init(noiseRemoval: Bool, normalize: Bool) {
            self.noiseRemoval = noiseRemoval
            self.normalize = normalize
        }

        init(_ audio: AudioSpec) {
            self.init(noiseRemoval: audio.noiseRemoval, normalize: audio.normalize)
        }

        /// True when the original file is what should play.
        var isIdentity: Bool { !noiseRemoval && !normalize }

        var fileName: String { "mic-nr\(noiseRemoval ? 1 : 0)-norm\(normalize ? 1 : 0).caf" }
    }

    enum ProcessingError: Error, LocalizedError {
        case unsupportedFormat

        var errorDescription: String? { "The voice track is in a format that cannot be processed." }
    }

    private static let chunkFrames: AVAudioFrameCount = 32_768

    /// Where the derived file for `options` lives.
    static func derivedURL(for bundle: RecordingBundle, options: Options) -> URL {
        bundle.derivedDirectory.appendingPathComponent(options.fileName)
    }

    /// Writes the processed track to `outputURL`. Synchronous and CPU-bound — run it off the main actor.
    static func process(micURL: URL, to outputURL: URL, options: Options) throws {
        guard !options.isIdentity else { return }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        let intermediateURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).stage")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: intermediateURL)
        }

        let input = try AVAudioFile(forReading: micURL)
        let format = input.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0 else { throw ProcessingError.unsupportedFormat }
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)

        // Pass 1: the noise floor (and, without noise removal, the loudness of the original).
        var loudness = LoudnessAccumulator(sampleRate: sampleRate)
        var profile: [Float]?
        if options.noiseRemoval {
            let learner = NoiseReducer()
            try forEachChunk(of: input) { buffer in
                learner.learn(mono(buffer, channels: channels))
            }
            learner.finishLearning()
            profile = learner.noiseProfile
        } else if options.normalize {
            try forEachChunk(of: input) { buffer in
                loudness.add(mono(buffer, channels: channels))
            }
        }

        // Pass 2: the denoised track, measured for normalisation. Scoped so the staged file is closed before
        // pass 3 reads it back.
        var stagedURL = micURL
        if let profile {
            let reducers = (0..<channels).map { _ -> NoiseReducer in
                let reducer = NoiseReducer()
                reducer.setNoiseProfile(profile)
                return reducer
            }
            do {
                let staged = try makeWriter(url: intermediateURL, format: format)
                input.framePosition = 0
                try forEachChunk(of: input) { buffer in
                    let count = Int(buffer.frameLength)
                    var processed: [[Float]] = []
                    for channel in 0..<channels {
                        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: count))
                        processed.append(reducers[channel].process(samples))
                    }
                    try write(processed, to: staged, format: format)
                    if options.normalize { loudness.add(monoOf(processed)) }
                }
                let tails = reducers.map { $0.flush() }
                try write(tails, to: staged, format: format)
                if options.normalize { loudness.add(monoOf(tails)) }
            }
            stagedURL = intermediateURL
        }

        // Pass 3: the gain.
        var gain: Float = 1
        if options.normalize {
            gain = LoudnessAnalyzer.normalizationGain(for: loudness.measurement())
        }
        try? FileManager.default.removeItem(at: outputURL)
        if abs(gain - 1) < 1e-3, stagedURL == intermediateURL {
            try FileManager.default.moveItem(at: intermediateURL, to: outputURL)
            return
        }
        // Scoped so both files are closed (AVAudioFile flushes on release) before the result is moved into place.
        do {
            let staged = try AVAudioFile(forReading: stagedURL)
            let writer = try makeWriter(url: temporaryURL, format: format)
            try forEachChunk(of: staged) { buffer in
                let count = Int(buffer.frameLength)
                if abs(gain - 1) >= 1e-3, let data = buffer.floatChannelData {
                    for channel in 0..<channels {
                        for i in 0..<count { data[channel][i] *= gain }
                    }
                }
                try writer.write(from: buffer)
            }
        }
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    }

    // MARK: - Helpers

    private static func makeWriter(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func forEachChunk(of file: AVAudioFile, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { throw ProcessingError.unsupportedFormat }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try body(buffer)
        }
    }

    private static func mono(_ buffer: AVAudioPCMBuffer, channels: Int) -> [Float] {
        let count = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData, count > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: count)) }
        var result = [Float](repeating: 0, count: count)
        let scale = 1 / Float(channels)
        for channel in 0..<channels {
            for i in 0..<count { result[i] += data[channel][i] * scale }
        }
        return result
    }

    private static func monoOf(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var result = [Float](repeating: 0, count: first.count)
        let scale = 1 / Float(channels.count)
        for samples in channels {
            for i in 0..<min(samples.count, result.count) { result[i] += samples[i] * scale }
        }
        return result
    }

    private static func write(_ channels: [[Float]], to file: AVAudioFile, format: AVAudioFormat) throws {
        guard let count = channels.first?.count, count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for (channel, samples) in channels.enumerated() where channel < Int(format.channelCount) {
            samples.withUnsafeBufferPointer { source in
                data[channel].update(from: source.baseAddress!, count: min(count, samples.count))
            }
        }
        try file.write(from: buffer)
    }
}
