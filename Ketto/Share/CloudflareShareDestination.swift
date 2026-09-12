import Foundation
import os

struct UploadProgress: Equatable, Sendable {
    var bytesSent: Int64
    var totalBytes: Int64

    static let zero = UploadProgress(bytesSent: 0, totalBytes: 0)

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesSent) / Double(totalBytes))
    }
}

/// Splits a file into the equal-sized parts an R2 multipart upload requires; only the last part may be shorter.
struct PartitionPlan: Equatable, Sendable {
    struct Part: Equatable, Sendable {
        /// 1-based, as the Worker and R2 number them.
        let number: Int
        let offset: Int64
        let length: Int
    }

    let fileSize: Int64
    let partSize: Int
    let parts: [Part]

    init(fileSize: Int64, partSize: Int) throws {
        guard fileSize > 0 else { throw PartitionError.emptyFile }
        guard partSize > 0 else { throw PartitionError.invalidPartSize(partSize) }
        var parts: [Part] = []
        var offset: Int64 = 0
        while offset < fileSize {
            let length = Int(min(Int64(partSize), fileSize - offset))
            parts.append(Part(number: parts.count + 1, offset: offset, length: length))
            offset += Int64(length)
        }
        guard parts.count <= 10_000 else { throw PartitionError.tooManyParts(parts.count) }
        self.fileSize = fileSize
        self.partSize = partSize
        self.parts = parts
    }
}

enum PartitionError: Error, LocalizedError, Equatable {
    case emptyFile
    case invalidPartSize(Int)
    case tooManyParts(Int)

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "The exported file is empty."
        case .invalidPartSize(let size): return "The backend asked for an impossible part size (\(size))."
        case .tooManyParts(let count): return "The file would need \(count) parts; the limit is 10,000."
        }
    }
}

/// Uploads a finished export to the user's Worker and returns the share link.
///
/// Parts are read one at a time, so memory stays at one part whatever the file size. A part that fails on the
/// network or with a 5xx is retried with backoff; anything else aborts the upload so nothing half-finished lingers
/// (the bucket's lifecycle rule would clean it up within a day anyway). Cancelling the task does the same.
struct CloudflareShareDestination: PublishDestination {
    let client: ShareBackendClient
    var maxAttempts = 3
    var retryDelay: Duration = .seconds(2)
    /// Byte-level progress, richer than the protocol's fraction. Throttled to roughly 200 reports per upload.
    var onUploadProgress: (@Sendable (UploadProgress) -> Void)?

    init(client: ShareBackendClient, onUploadProgress: (@Sendable (UploadProgress) -> Void)? = nil) {
        self.client = client
        self.onUploadProgress = onUploadProgress
    }

    var displayName: String { "Share link via \(client.connection.displayName)" }

    func authenticate() async throws {
        _ = try await client.status()
    }

    func upload(_ file: URL, metadata: VideoMetadata, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileSize = try Self.size(of: file)
        let upload = try await withRetry {
            try await client.createUpload(title: metadata.title, filename: file.lastPathComponent, size: fileSize)
        }
        let plan = try PartitionPlan(fileSize: fileSize, partSize: upload.partSize)
        let gate = ProgressGate(total: fileSize, step: max(fileSize / 200, 256 * 1024))
        let report: @Sendable (Int64) -> Void = { sent in
            guard let snapshot = gate.admit(sent) else { return }
            progress(snapshot.fraction)
            onUploadProgress?(snapshot)
        }
        report(0)
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var uploaded: [UploadedPart] = []
            uploaded.reserveCapacity(plan.parts.count)
            var completedBytes: Int64 = 0
            for part in plan.parts {
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(part.offset))
                guard let data = try handle.read(upToCount: part.length), data.count == part.length else {
                    throw ShareBackendError.fileUnreadable(file)
                }
                let base = completedBytes
                let result = try await withRetry {
                    try await client.uploadPart(data, partNumber: part.number, in: upload) { sent in report(base + sent) }
                }
                uploaded.append(result)
                completedBytes += Int64(part.length)
                report(completedBytes)
            }
            try Task.checkCancellation()
            let parts = uploaded
            let video = try await withRetry { try await client.completeUpload(upload, parts: parts) }
            return video.url
        } catch {
            // Best effort, and deliberately outside the current task: an abort request issued from a cancelled task
            // would itself be cancelled before it left the machine.
            let client = self.client
            Task.detached { try? await client.abortUpload(upload) }
            throw error
        }
    }

    private func withRetry<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as ShareBackendError where error.isRetryable && attempt < maxAttempts {
                try await Task.sleep(for: retryDelay * (1 << (attempt - 1)))
                attempt += 1
            }
        }
    }

    private static func size(of file: URL) throws -> Int64 {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw ShareBackendError.fileUnreadable(file)
        }
        return Int64(size)
    }
}

/// Lets a progress report through when enough bytes have moved since the last one, plus the first and the last.
/// Never lets progress run backwards, which a retried part would otherwise do.
private final class ProgressGate: Sendable {
    private let total: Int64
    private let step: Int64
    private let last = OSAllocatedUnfairLock<Int64>(initialState: -1)

    init(total: Int64, step: Int64) {
        self.total = total
        self.step = step
    }

    func admit(_ sent: Int64) -> UploadProgress? {
        let bytes = min(max(sent, 0), total)
        let admitted: Bool = last.withLock { last in
            guard bytes > last else { return false }
            guard bytes == 0 || bytes == total || bytes - max(last, 0) >= step else { return false }
            last = bytes
            return true
        }
        return admitted ? UploadProgress(bytesSent: bytes, totalBytes: total) : nil
    }
}
