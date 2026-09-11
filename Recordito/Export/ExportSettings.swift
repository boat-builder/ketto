import Foundation
@preconcurrency import AVFoundation

/// Output format for an export. Presets keep the canvas aspect ratio and pick the width from the height.
struct ExportSettings: Equatable, Hashable, Sendable {
    enum Resolution: String, CaseIterable, Identifiable, Sendable {
        case hd1080 = "1080p"
        case qhd1440 = "1440p"
        case uhd4K = "4K"

        var id: String { rawValue }

        /// Output height in pixels for a landscape canvas (the shorter side for portrait canvases).
        var shortSide: Int {
            switch self {
            case .hd1080: return 1080
            case .qhd1440: return 1440
            case .uhd4K: return 2160
            }
        }

        var displayName: String {
            switch self {
            case .hd1080: return "1080p"
            case .qhd1440: return "1440p"
            case .uhd4K: return "4K"
            }
        }
    }

    static let frameRates = [30, 60]

    var width: Int
    var height: Int
    var fps: Int

    init(width: Int, height: Int, fps: Int) {
        self.width = max(16, width - width % 2)
        self.height = max(16, height - height % 2)
        self.fps = max(1, fps)
    }

    /// A preset sized to the canvas aspect ratio: 1080p on a 16:9 canvas is 1920×1080, on a 9:16 canvas 1080×1920.
    static func preset(_ resolution: Resolution, fps: Int, canvas: CanvasSpec) -> ExportSettings {
        let aspect = max(canvas.aspectRatio, 0.01)
        if aspect >= 1 {
            let height = resolution.shortSide
            return ExportSettings(width: Int((Double(height) * aspect).rounded()), height: height, fps: fps)
        } else {
            let width = resolution.shortSide
            return ExportSettings(width: width, height: Int((Double(width) / aspect).rounded()), fps: fps)
        }
    }

    var sizeDescription: String { "\(width) × \(height)" }

    /// H.264 High profile at roughly 0.09 bits per pixel per frame, between 2 and 60 Mbps.
    var videoBitrate: Int {
        let pixelsPerSecond = Double(width * height) * Double(fps)
        return Int(min(max(pixelsPerSecond * 0.09, 2_000_000), 60_000_000))
    }

    static let audioSampleRate = 48_000
    static let audioChannels = 2
    static let audioBitrate = 192_000

    var videoOutputSettings: [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] as [String: Any],
        ]
    }

    static var audioOutputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannels,
            AVEncoderBitRateKey: audioBitrate,
        ]
    }

    /// Uncompressed intermediate format the audio mix output vends to the AAC encoder.
    static var audioDecodeSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Rough size estimate for the export sheet, in bytes.
    func estimatedFileSize(duration: Double) -> Int64 {
        Int64((Double(videoBitrate) + Double(Self.audioBitrate)) / 8 * max(duration, 0))
    }
}
