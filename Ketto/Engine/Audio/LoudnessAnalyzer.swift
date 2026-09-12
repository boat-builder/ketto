import Foundation

struct LoudnessMeasurement: Equatable, Sendable {
    /// Mean level of the parts of the track that carry signal, in dBFS.
    var rmsDB: Float
    /// Highest sample magnitude, in dBFS.
    var peakDB: Float
    /// Number of 400 ms blocks that passed the gate. Zero means silence.
    var gatedBlocks: Int

    static let silence = LoudnessMeasurement(rmsDB: -100, peakDB: -100, gatedBlocks: 0)
}

/// Streaming loudness measurement: 400 ms blocks, an absolute gate that ignores silence and a relative gate
/// that ignores pauses, so a track that is mostly quiet still measures the voice rather than the room.
struct LoudnessAccumulator: Sendable {
    let sampleRate: Double
    private let blockSize: Int
    private var blockSum: Double = 0
    private var blockCount = 0
    private var blockPowers: [Double] = []
    private var peak: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = max(sampleRate, 1)
        self.blockSize = max(1, Int(self.sampleRate * 0.4))
    }

    mutating func add(_ samples: [Float]) {
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            blockSum += Double(sample) * Double(sample)
            blockCount += 1
            if blockCount == blockSize {
                blockPowers.append(blockSum / Double(blockCount))
                blockSum = 0
                blockCount = 0
            }
        }
    }

    func measurement(absoluteGateDB: Double = -55, relativeGateDB: Double = -12) -> LoudnessMeasurement {
        var powers = blockPowers
        if blockCount > blockSize / 4 { powers.append(blockSum / Double(blockCount)) }
        let absoluteGate = pow(10, absoluteGateDB / 10)
        let loud = powers.filter { $0 > absoluteGate }
        guard !loud.isEmpty else {
            return LoudnessMeasurement(rmsDB: -100, peakDB: peak > 0 ? 20 * log10(peak) : -100, gatedBlocks: 0)
        }
        let mean = loud.reduce(0, +) / Double(loud.count)
        let relativeGate = mean * pow(10, relativeGateDB / 10)
        let gated = loud.filter { $0 > relativeGate }
        let power = gated.isEmpty ? mean : gated.reduce(0, +) / Double(gated.count)
        return LoudnessMeasurement(
            rmsDB: Float(10 * log10(max(power, 1e-12))),
            peakDB: peak > 0 ? 20 * log10(peak) : -100,
            gatedBlocks: gated.isEmpty ? loud.count : gated.count
        )
    }
}

enum LoudnessAnalyzer {
    /// Level a normalised voice track is brought to, in dBFS (gated RMS).
    static let targetRMSDB: Float = -18
    /// Peaks are never allowed above this after gain, in dBFS.
    static let peakCeilingDB: Float = -1
    static let gainRange: ClosedRange<Float> = 0.25...8

    static func measure(_ samples: [Float], sampleRate: Double) -> LoudnessMeasurement {
        var accumulator = LoudnessAccumulator(sampleRate: sampleRate)
        accumulator.add(samples)
        return accumulator.measurement()
    }

    /// The linear gain that brings a track to the target level without clipping. 1 for silence.
    static func normalizationGain(for measurement: LoudnessMeasurement) -> Float {
        guard measurement.gatedBlocks > 0 else { return 1 }
        let wanted = pow(10, (targetRMSDB - measurement.rmsDB) / 20)
        let ceiling = pow(10, (peakCeilingDB - measurement.peakDB) / 20)
        let gain = min(wanted, ceiling)
        guard gain.isFinite else { return 1 }
        return min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }
}
