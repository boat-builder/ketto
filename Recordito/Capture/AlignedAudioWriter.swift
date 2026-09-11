import Foundation
@preconcurrency import AVFoundation
import CoreMedia

/// Decides how each incoming audio buffer maps onto the recording timeline: silence is inserted for gaps and
/// leading frames are skipped for overlaps, so sample 0 of the file is exactly the recording's time base.
struct AudioAlignmentPlanner: Equatable, Sendable {
    struct Plan: Equatable, Sendable {
        /// Frames of silence to write before the buffer.
        var silenceFrames: Int
        /// Leading frames of the buffer to discard.
        var skipFrames: Int
    }

    let sampleRate: Double
    /// Timestamp jitter below this many frames is treated as contiguous.
    var toleranceFrames: Int
    /// Gaps larger than this are capped (something is badly wrong; keep the file bounded).
    var maxGapFrames: Int
    private(set) var writtenFrames: Int = 0

    init(sampleRate: Double, toleranceSeconds: Double = 0.002, maxGapSeconds: Double = 60) {
        self.sampleRate = sampleRate
        self.toleranceFrames = Int(toleranceSeconds * sampleRate)
        self.maxGapFrames = Int(maxGapSeconds * sampleRate)
    }

    /// Plans the write of a buffer that starts `offsetSeconds` after the time base and has `frameCount` frames.
    mutating func plan(offsetSeconds: Double, frameCount: Int) -> Plan {
        let startFrame = Int((offsetSeconds * sampleRate).rounded())
        let delta = startFrame - writtenFrames
        var plan = Plan(silenceFrames: 0, skipFrames: 0)
        if delta > toleranceFrames {
            plan.silenceFrames = min(delta, maxGapFrames)
        } else if delta < -toleranceFrames {
            plan.skipFrames = min(-delta, frameCount)
        }
        writtenFrames += plan.silenceFrames + max(0, frameCount - plan.skipFrames)
        return plan
    }
}

/// Writes PCM audio from `CMSampleBuffer`s into a CAF file aligned to the shared recording clock.
/// Buffers that arrive before the clock is established are held back and flushed once it is.
/// `append` must be called from a single serial queue.
final class AlignedAudioWriter: @unchecked Sendable {
    let url: URL
    private let clock: RecordingClock
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var planner: AudioAlignmentPlanner?
    private var pending: [CMSampleBuffer] = []
    private(set) var writtenFrames: Int = 0
    private(set) var receivedBuffers = 0
    private(set) var error: Error?

    private static let maxPending = 400

    init(url: URL, clock: RecordingClock) {
        self.url = url
        self.clock = clock
        try? FileManager.default.removeItem(at: url)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        receivedBuffers += 1
        guard let base = clock.base else {
            pending.append(sampleBuffer)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
            return
        }
        if !pending.isEmpty {
            let queued = pending
            pending.removeAll()
            for buffer in queued { write(buffer, base: base) }
        }
        write(sampleBuffer, base: base)
    }

    private func write(_ sampleBuffer: CMSampleBuffer, base: Double) {
        guard error == nil, let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let bufferFormat = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: bufferFormat.sampleRate,
                    AVNumberOfChannelsKey: bufferFormat.channelCount,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: bufferFormat.sampleRate, channels: bufferFormat.channelCount, interleaved: false)
                planner = AudioAlignmentPlanner(sampleRate: bufferFormat.sampleRate)
            }
            guard let file, let format, var planner else { return }
            let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frameCount > 0 else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let plan = planner.plan(offsetSeconds: pts.seconds - base, frameCount: frameCount)
            self.planner = planner
            if plan.silenceFrames > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(plan.silenceFrames)) {
                silence.frameLength = AVAudioFrameCount(plan.silenceFrames)
                for channel in 0..<Int(format.channelCount) {
                    silence.floatChannelData?[channel].update(repeating: 0, count: plan.silenceFrames)
                }
                try file.write(from: silence)
                writtenFrames += plan.silenceFrames
            }
            let keep = frameCount - plan.skipFrames
            guard keep > 0 else { return }
            guard let converted = Self.pcmBuffer(from: sampleBuffer, sourceFormat: bufferFormat, targetFormat: format, skipFrames: plan.skipFrames) else { return }
            try file.write(from: converted)
            writtenFrames += Int(converted.frameLength)
        } catch {
            self.error = error
        }
    }

    /// Copies the PCM payload of a sample buffer into a float32 non-interleaved buffer, dropping `skipFrames` leading frames.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer, sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat, skipFrames: Int) -> AVAudioPCMBuffer? {
        let frameCount = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let raw = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        raw.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: raw.mutableAudioBufferList)
        guard status == noErr else { return nil }
        let keep = frameCount - skipFrames
        guard keep > 0 else { return nil }
        var source = raw
        if sourceFormat.commonFormat != .pcmFormatFloat32 || sourceFormat.isInterleaved {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
                  let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
            do {
                try converter.convert(to: converted, from: raw)
            } catch {
                return nil
            }
            source = converted
        }
        guard skipFrames > 0 else { return source }
        guard let trimmed = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(keep)) else { return nil }
        trimmed.frameLength = AVAudioFrameCount(keep)
        for channel in 0..<Int(targetFormat.channelCount) {
            guard let src = source.floatChannelData?[channel], let dst = trimmed.floatChannelData?[channel] else { return nil }
            dst.update(from: src.advanced(by: skipFrames), count: keep)
        }
        return trimmed
    }

    /// Closes the file. Returns whether anything was written.
    @discardableResult
    func finish() -> Bool {
        pending.removeAll()
        let wrote = writtenFrames > 0
        file = nil
        if !wrote { try? FileManager.default.removeItem(at: url) }
        return wrote
    }
}
