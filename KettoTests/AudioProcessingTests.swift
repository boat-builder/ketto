import XCTest
@testable import Ketto

final class AudioProcessingTests: XCTestCase {
    func testFFTRoundTripAndPeakBin() {
        let n = 256
        let fft = FFT(size: n)
        var real = (0..<n).map { Float(sin(2 * Double.pi * 16 * Double($0) / Double(n))) }
        var imag = [Float](repeating: 0, count: n)
        let original = real
        fft.forward(real: &real, imag: &imag)
        var peakBin = 0
        var peak: Float = 0
        for k in 0..<n / 2 {
            let magnitude = (real[k] * real[k] + imag[k] * imag[k]).squareRoot()
            if magnitude > peak { peak = magnitude; peakBin = k }
        }
        XCTAssertEqual(peakBin, 16)
        XCTAssertEqual(peak, Float(n) / 2, accuracy: 1e-2)
        fft.inverse(real: &real, imag: &imag)
        for i in 0..<n {
            XCTAssertEqual(real[i], original[i], accuracy: 1e-4)
            XCTAssertEqual(imag[i], 0, accuracy: 1e-4)
        }
    }

    func testFFTMatchesNaiveDFT() {
        let n = 32
        let fft = FFT(size: n)
        var rng = SystemRandomNumberGenerator()
        let input = (0..<n).map { _ in Float.random(in: -1...1, using: &rng) }
        var real = input
        var imag = [Float](repeating: 0, count: n)
        fft.forward(real: &real, imag: &imag)
        for k in 0..<n {
            var sumRe = 0.0, sumIm = 0.0
            for j in 0..<n {
                let angle = -2 * Double.pi * Double(k * j) / Double(n)
                sumRe += Double(input[j]) * cos(angle)
                sumIm += Double(input[j]) * sin(angle)
            }
            XCTAssertEqual(Double(real[k]), sumRe, accuracy: 1e-3)
            XCTAssertEqual(Double(imag[k]), sumIm, accuracy: 1e-3)
        }
    }

    func testNoiseReducerPassesSignalThroughUnchangedWithoutNoise() {
        let reducer = NoiseReducer()
        reducer.setNoiseProfile([Float](repeating: 0, count: reducer.parameters.bins))
        let input = (0..<20_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        var output = reducer.process(Array(input[0..<7000]))
        output += reducer.process(Array(input[7000...]))
        output += reducer.flush()
        XCTAssertEqual(output.count, input.count)
        var maxError: Float = 0
        for i in 0..<input.count { maxError = max(maxError, abs(output[i] - input[i])) }
        XCTAssertLessThan(maxError, 1e-3, "overlap-add must reconstruct the input exactly")
    }

    func testNoiseReducerImprovesSignalToNoise() {
        let sampleRate = 48_000.0
        let seconds = 3.0
        let count = Int(sampleRate * seconds)
        var generator = SplitMix64(seed: 42)
        let noise = (0..<count).map { _ in Float(generator.nextUniform() * 2 - 1) * 0.05 }
        var tone = [Float](repeating: 0, count: count)
        // A voice-like burst: 300 Hz tone with harmonics, present for the middle second only.
        for i in Int(sampleRate)..<Int(2 * sampleRate) {
            let t = Double(i) / sampleRate
            tone[i] = Float(0.4 * sin(2 * .pi * 300 * t) + 0.2 * sin(2 * .pi * 600 * t) + 0.1 * sin(2 * .pi * 900 * t))
        }
        let mixed = zip(tone, noise).map { $0 + $1 }

        let reducer = NoiseReducer()
        reducer.learn(mixed)
        reducer.finishLearning()
        var output = reducer.process(mixed)
        output += reducer.flush()
        XCTAssertEqual(output.count, mixed.count)

        func power(_ samples: ArraySlice<Float>) -> Double {
            samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))
        }
        // Noise-only region: much quieter after processing.
        let quietBefore = power(mixed[0..<Int(sampleRate * 0.9)])
        let quietAfter = power(output[0..<Int(sampleRate * 0.9)])
        XCTAssertLessThan(quietAfter, quietBefore * 0.1, "noise floor should drop by at least 10 dB")
        // Signal region: level largely preserved.
        let loudBefore = power(mixed[Int(sampleRate * 1.2)..<Int(sampleRate * 1.8)])
        let loudAfter = power(output[Int(sampleRate * 1.2)..<Int(sampleRate * 1.8)])
        XCTAssertGreaterThan(loudAfter, loudBefore * 0.6, "the voice must survive")
    }

    func testLoudnessGainTargetsLevelAndRespectsPeaks() {
        let sampleRate = 48_000.0
        var quiet = [Float](repeating: 0, count: Int(sampleRate * 4))
        for i in 0..<quiet.count where i > Int(sampleRate) && i < Int(sampleRate * 3) {
            quiet[i] = Float(0.05 * sin(2 * .pi * 440 * Double(i) / sampleRate)) // about -29 dBFS RMS
        }
        let measurement = LoudnessAnalyzer.measure(quiet, sampleRate: sampleRate)
        XCTAssertGreaterThan(measurement.gatedBlocks, 0)
        XCTAssertEqual(measurement.rmsDB, -29, accuracy: 1.0, "silence is gated out of the measurement")
        let gain = LoudnessAnalyzer.normalizationGain(for: measurement)
        let resulting = measurement.rmsDB + 20 * log10(gain)
        XCTAssertEqual(resulting, LoudnessAnalyzer.targetRMSDB, accuracy: 1.0)
        XCTAssertLessThanOrEqual(measurement.peakDB + 20 * log10(gain), LoudnessAnalyzer.peakCeilingDB + 1e-3)

        let silence = LoudnessAnalyzer.measure([Float](repeating: 0, count: 48_000), sampleRate: sampleRate)
        XCTAssertEqual(silence.gatedBlocks, 0)
        XCTAssertEqual(LoudnessAnalyzer.normalizationGain(for: silence), 1)

        let hot = (0..<48_000).map { Float(0.99 * sin(2 * .pi * 440 * Double($0) / sampleRate)) }
        let hotGain = LoudnessAnalyzer.normalizationGain(for: LoudnessAnalyzer.measure(hot, sampleRate: sampleRate))
        XCTAssertLessThan(hotGain, 1, "a loud track is turned down")
    }
}

/// Deterministic random numbers for the audio tests.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
