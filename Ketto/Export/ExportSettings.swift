import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// The file an export produces.
enum ExportContainer: String, CaseIterable, Identifiable, Sendable {
    case mp4, mov, gif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .gif: return "GIF"
        }
    }

    var pathExtension: String { rawValue }

    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .gif: return .gif
        }
    }

    /// The AVFoundation file type; nil for GIF, which ImageIO writes.
    var fileType: AVFileType? {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        case .gif: return nil
        }
    }

    var isMovie: Bool { self != .gif }
}

enum ExportCodec: String, CaseIterable, Identifiable, Sendable {
    case h264, hevc, proRes422

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .proRes422: return "ProRes 422"
        }
    }

    var videoCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422: return .proRes422
        }
    }

    /// ProRes only lives in QuickTime files.
    func isAvailable(in container: ExportContainer) -> Bool {
        switch container {
        case .mp4: return self != .proRes422
        case .mov: return true
        case .gif: return false
        }
    }
}

/// One-click configurations for the common destinations.
enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
    case web, social, handoff, gif, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .web: return "Web"
        case .social: return "Social"
        case .handoff: return "Hand-off"
        case .gif: return "GIF"
        case .custom: return "Custom"
        }
    }

    var summary: String {
        switch self {
        case .web: return "MP4, H.264, 1080p at 60 fps. Plays everywhere."
        case .social: return "MP4, H.264, 1080p at 30 fps, higher bitrate. For Instagram, TikTok, X and LinkedIn — pair it with a 9:16, 1:1 or 4:5 canvas."
        case .handoff: return "MOV, ProRes 422 at 60 fps. Large, lossless-quality files for a video editor."
        case .gif: return "Animated GIF, 640 px wide at 15 fps, looping."
        case .custom: return "Your own combination of format, codec, size and frame rate."
        }
    }

    func settings(canvas: CanvasSpec) -> ExportSettings {
        switch self {
        case .web:
            return ExportSettings.preset(.hd1080, fps: 60, canvas: canvas)
        case .social:
            var settings = ExportSettings.preset(.hd1080, fps: 30, canvas: canvas)
            settings.quality = 1.5
            return settings
        case .handoff:
            var settings = ExportSettings.preset(.hd1080, fps: 60, canvas: canvas)
            settings.container = .mov
            settings.codec = .proRes422
            return settings
        case .gif:
            return ExportSettings.gif(width: 640, fps: 15, canvas: canvas)
        case .custom:
            return ExportSettings.preset(.hd1080, fps: 60, canvas: canvas)
        }
    }
}

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
    static let gifFrameRates = [10, 15, 20]
    static let gifWidths = [320, 480, 640, 800, 960]

    var width: Int
    var height: Int
    var fps: Int
    var container: ExportContainer
    var codec: ExportCodec
    /// Bitrate multiplier for the lossy codecs: 1 is the default, 2 doubles it.
    var quality: Double
    /// GIFs loop forever when set.
    var loop: Bool

    init(width: Int, height: Int, fps: Int, container: ExportContainer = .mp4, codec: ExportCodec = .h264, quality: Double = 1, loop: Bool = true) {
        self.width = max(16, width - width % 2)
        self.height = max(16, height - height % 2)
        self.fps = max(1, fps)
        self.container = container
        self.codec = codec.isAvailable(in: container) ? codec : .h264
        self.quality = min(max(quality.isFinite ? quality : 1, 0.25), 3)
        self.loop = loop
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

    /// A GIF `width` pixels wide at the canvas aspect ratio.
    static func gif(width: Int, fps: Int, canvas: CanvasSpec) -> ExportSettings {
        let aspect = max(canvas.aspectRatio, 0.01)
        return ExportSettings(width: width, height: Int((Double(width) / aspect).rounded()), fps: fps, container: .gif, codec: .h264, quality: 1, loop: true)
    }

    var sizeDescription: String { "\(width) × \(height)" }

    var formatDescription: String {
        switch container {
        case .gif: return "GIF"
        default: return "\(codec.displayName) · AAC · \(container.displayName)"
        }
    }

    /// Roughly 0.09 bits per pixel per frame for H.264 (0.065 for HEVC, which is about as good at two thirds
    /// of the rate), times `quality`, between 2 and 80 Mbps. ProRes has a fixed rate the encoder chooses.
    var videoBitrate: Int {
        let pixelsPerSecond = Double(width * height) * Double(fps)
        let bitsPerPixel = codec == .hevc ? 0.065 : 0.09
        return Int(min(max(pixelsPerSecond * bitsPerPixel * quality, 2_000_000), 80_000_000))
    }

    static let audioSampleRate = 48_000
    static let audioChannels = 2
    static let audioBitrate = 192_000

    var videoOutputSettings: [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.videoCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] as [String: Any],
        ]
        switch codec {
        case .h264:
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        case .hevc:
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        case .proRes422:
            break
        }
        return settings
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
        let seconds = max(duration, 0)
        switch container {
        case .gif:
            // Screen content compresses well as a GIF, but 256 colours per frame add up: about a quarter byte per pixel.
            return Int64(Double(width * height) * Double(fps) * seconds * 0.25)
        default:
            let videoRate: Double
            switch codec {
            case .proRes422: videoRate = Double(width * height) * Double(fps) * 1.6 // ~ProRes 422 at these sizes
            default: videoRate = Double(videoBitrate)
            }
            return Int64((videoRate + Double(Self.audioBitrate)) / 8 * seconds)
        }
    }
}
