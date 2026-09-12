import Foundation

struct NoiseReducerParameters: Equatable, Sendable {
    /// STFT frame length in samples (power of two).
    var frameSize = 1024
    /// Hop between frames in samples. `frameSize / 4` keeps the overlap-add constant with a Hann window.
    var hop = 256
    /// How far a bin judged to be pure noise is pulled down, in dB.
    var maxAttenuationDB: Float = 22
    /// Which percentile of the observed per-bin magnitudes counts as the noise floor.
    var noisePercentile: Double = 0.3
    /// Safety factor on the estimated floor: a little over-subtraction beats musical noise.
    var noiseOverestimate: Float = 1.6
    /// Per-frame gain smoothing when a bin's gain rises (signal returning) and falls (noise only).
    var attack: Float = 0.7
    var release: Float = 0.3
    /// 0 = no change, 1 = full reduction.
    var strength: Float = 1

    init() {}

    var bins: Int { frameSize / 2 + 1 }
}

/// Spectral-gate background noise removal, the classic two-pass approach: learn a per-frequency noise floor
/// from the quiet parts of the track, then attenuate every STFT bin according to how far it rises above that
/// floor. Runs on the mic track alone (which is the reason the audio is never pre-mixed) and never touches
/// the recording on disk: the result is written to a derived file the player and exporter read instead.
///
/// Streaming: feed `learn(_:)` the whole track (or enough of it), call `finishLearning()`, then feed the
/// track again through `process(_:)` and finish with `flush()`. Output length equals input length.
final class NoiseReducer {
    let parameters: NoiseReducerParameters
    private let fft: FFT
    private let window: [Float]
    private let overlapAddGain: Float

    private var reservoir: [[Float]] = []
    private var learnStride = 1
    private var learnFrameIndex = 0
    private var learnPending: [Float] = []
    private static let reservoirCapacity = 2048

    private(set) var noiseProfile: [Float]?

    private var pending: [Float]
    private var overlap: [Float]
    private var previousGain: [Float]
    private var inputCount = 0
    private var outputCount = 0
    private var outputSkip: Int

    init(parameters: NoiseReducerParameters = NoiseReducerParameters()) {
        self.parameters = parameters
        let n = parameters.frameSize
        fft = FFT(size: n)
        // sqrt-Hann on both analysis and synthesis, so the product is a Hann window.
        var window = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            window[i] = Float(hann.squareRoot())
        }
        self.window = window
        // Normalisation of the overlap-add: the sum of window² over all hops that touch a sample.
        var sum = Float(0)
        var offset = 0
        while offset < n {
            sum += window[offset] * window[offset]
            offset += parameters.hop
        }
        overlapAddGain = sum > 0 ? 1 / sum : 1
        let delay = n - parameters.hop
        pending = [Float](repeating: 0, count: delay)
        overlap = [Float](repeating: 0, count: n)
        previousGain = [Float](repeating: 1, count: parameters.bins)
        outputSkip = delay
    }

    // MARK: - Learning

    /// Accumulates magnitude spectra for the noise estimate. Frames are subsampled as the track grows so
    /// memory stays bounded whatever the length.
    func learn(_ samples: [Float]) {
        learnPending.append(contentsOf: samples)
        let n = parameters.frameSize
        var offset = 0
        while offset + n <= learnPending.count {
            if learnFrameIndex % learnStride == 0 {
                if reservoir.count >= Self.reservoirCapacity {
                    reservoir = stride(from: 0, to: reservoir.count, by: 2).map { reservoir[$0] }
                    learnStride *= 2
                }
                if learnFrameIndex % learnStride == 0 {
                    reservoir.append(magnitudes(of: Array(learnPending[offset..<offset + n])))
                }
            }
            learnFrameIndex += 1
            offset += parameters.hop
        }
        if offset > 0 { learnPending.removeFirst(offset) }
    }

    /// Turns the accumulated spectra into the per-bin noise floor.
    func finishLearning() {
        learnPending.removeAll()
        let bins = parameters.bins
        guard !reservoir.isEmpty else {
            noiseProfile = [Float](repeating: 0, count: bins)
            return
        }
        var profile = [Float](repeating: 0, count: bins)
        var column = [Float](repeating: 0, count: reservoir.count)
        let rank = min(max(Int(Double(reservoir.count - 1) * parameters.noisePercentile), 0), reservoir.count - 1)
        for k in 0..<bins {
            for (i, frame) in reservoir.enumerated() { column[i] = frame[k] }
            column.sort()
            profile[k] = column[rank]
        }
        noiseProfile = profile
        reservoir.removeAll()
    }

    /// Uses a known floor instead of learning one.
    func setNoiseProfile(_ profile: [Float]) {
        precondition(profile.count == parameters.bins)
        noiseProfile = profile
    }

    // MARK: - Processing

    /// Processes samples, returning the output produced so far. Output lags input by `frameSize - hop`
    /// samples until `flush()`.
    func process(_ samples: [Float]) -> [Float] {
        inputCount += samples.count
        pending.append(contentsOf: samples)
        return drain(padded: false)
    }

    /// Processes what is left and returns the tail, so that total output length equals total input length.
    func flush() -> [Float] {
        pending.append(contentsOf: [Float](repeating: 0, count: parameters.frameSize))
        var out = drain(padded: true)
        let expected = inputCount - outputCount
        if expected < out.count { out.removeLast(out.count - max(expected, 0)) }
        outputCount += out.count
        return out
    }

    private func drain(padded: Bool) -> [Float] {
        let n = parameters.frameSize
        let hop = parameters.hop
        var out: [Float] = []
        var offset = 0
        while offset + n <= pending.count {
            let frame = Array(pending[offset..<offset + n])
            let processed = processFrame(frame)
            for i in 0..<n { overlap[i] += processed[i] }
            // The first `hop` samples of the accumulator are complete.
            if outputSkip >= hop {
                outputSkip -= hop
            } else {
                let start = outputSkip
                outputSkip = 0
                out.append(contentsOf: overlap[start..<hop])
            }
            overlap.removeFirst(hop)
            overlap.append(contentsOf: [Float](repeating: 0, count: hop))
            offset += hop
        }
        if offset > 0 { pending.removeFirst(offset) }
        if !padded {
            let remaining = inputCount - outputCount
            if out.count > remaining { out.removeLast(out.count - max(remaining, 0)) }
            outputCount += out.count
        }
        return out
    }

    private func magnitudes(of frame: [Float]) -> [Float] {
        let n = parameters.frameSize
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for i in 0..<n { real[i] = frame[i] * window[i] }
        fft.forward(real: &real, imag: &imag)
        let bins = parameters.bins
        var result = [Float](repeating: 0, count: bins)
        for k in 0..<bins { result[k] = (real[k] * real[k] + imag[k] * imag[k]).squareRoot() }
        return result
    }

    private func processFrame(_ frame: [Float]) -> [Float] {
        let n = parameters.frameSize
        let bins = parameters.bins
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for i in 0..<n { real[i] = frame[i] * window[i] }
        fft.forward(real: &real, imag: &imag)

        let profile = noiseProfile ?? [Float](repeating: 0, count: bins)
        let floorGain = pow(10, -parameters.maxAttenuationDB / 20)
        var gains = [Float](repeating: 1, count: bins)
        for k in 0..<bins {
            let magnitude = (real[k] * real[k] + imag[k] * imag[k]).squareRoot()
            let noise = profile[k] * parameters.noiseOverestimate
            var gain: Float = 1
            if noise > 0 {
                let snr = max(magnitude - noise, 0) / noise
                gain = max(snr / (snr + 1), floorGain)
            }
            gain = 1 - (1 - gain) * parameters.strength
            let previous = previousGain[k]
            gain = gain > previous ? previous + (gain - previous) * parameters.attack : previous + (gain - previous) * parameters.release
            previousGain[k] = gain
            gains[k] = gain
        }
        // Smooth across neighbouring bins to avoid isolated tonal artefacts.
        var smoothed = gains
        if bins >= 3 {
            for k in 1..<bins - 1 { smoothed[k] = 0.25 * gains[k - 1] + 0.5 * gains[k] + 0.25 * gains[k + 1] }
        }
        for k in 0..<bins {
            real[k] *= smoothed[k]
            imag[k] *= smoothed[k]
            let mirror = n - k
            if mirror < n, mirror > k {
                real[mirror] *= smoothed[k]
                imag[mirror] *= smoothed[k]
            }
        }
        fft.inverse(real: &real, imag: &imag)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = real[i] * window[i] * overlapAddGain }
        return out
    }
}
