import Foundation

/// One video on the backend, as `GET /api/videos` and a completed upload describe it.
struct SharedVideo: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let title: String
    let size: Int64
    let uploaded: Date
    /// When the bucket's lifecycle rule will remove it; the sweep runs daily, so this is "about".
    let expires: Date
    let url: URL
}

/// A multipart upload the Worker has opened. `partSize` is the Worker's choice and must be used verbatim: R2
/// requires every part except the last to be exactly the same size.
struct UploadSession: Equatable, Sendable, Decodable {
    let id: String
    let uploadId: String
    let partSize: Int
}

struct UploadedPart: Equatable, Sendable, Codable {
    let partNumber: Int
    let etag: String
}

struct ShareBackendStatus: Equatable, Sendable, Decodable {
    let ok: Bool
    let api: Int
    let bucket: String?
}

enum ShareBackendError: Error, LocalizedError, Equatable {
    /// 401: the token is wrong for this Worker.
    case unauthorized
    /// 503: the Worker is deployed but `wrangler secret put` has not run yet.
    case notConfigured
    /// The Worker speaks another API version than this build of the app.
    case incompatible(api: Int)
    case server(status: Int, message: String)
    case invalidResponse
    case unreachable(String)
    case fileUnreadable(URL)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The backend rejected the sharing token. Reconnect in Settings \u{203A} Sharing."
        case .notConfigured:
            return "The backend has no token yet. Let the setup finish, then try again."
        case .incompatible(let api):
            return "The backend runs API version \(api) but this Ketto expects \(ShareBackendClient.apiVersion). Set up sharing again from Settings \u{203A} Sharing."
        case .server(let status, let message):
            return "The backend answered \(status): \(message)"
        case .invalidResponse:
            return "The backend sent a reply Ketto could not read."
        case .unreachable(let reason):
            return "Could not reach the backend: \(reason)"
        case .fileUnreadable(let url):
            return "\(url.lastPathComponent) could not be read for upload."
        }
    }

    /// Worth another attempt: the network hiccuped or the Worker had a transient problem. Anything the app can fix
    /// by changing the request is not.
    var isRetryable: Bool {
        switch self {
        case .unreachable: return true
        case .server(let status, _): return status >= 500
        default: return false
        }
    }
}

/// Talks to the Worker in `Resources/CloudflareBackend/worker.js`, one method per route. The contract lives in
/// the header of that file.
struct ShareBackendClient: Sendable {
    static let apiVersion = 1

    let connection: ShareBackendConnection
    let session: URLSession

    init(connection: ShareBackendConnection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    /// Verifies the token and that the Worker speaks this app's API version.
    func status() async throws -> ShareBackendStatus {
        let status: ShareBackendStatus = try await send(try request("GET", "/api/status"))
        guard status.api == Self.apiVersion else { throw ShareBackendError.incompatible(api: status.api) }
        return status
    }

    func createUpload(title: String, filename: String, size: Int64, contentType: String = "video/mp4") async throws -> UploadSession {
        let body = try JSONEncoder().encode(CreateUploadRequest(title: title, filename: filename, size: size, contentType: contentType))
        return try await send(try request("POST", "/api/uploads", body: body))
    }

    /// Sends one part. `onBytesSent` reports the running byte count of this part while it is in flight.
    func uploadPart(_ data: Data, partNumber: Int, in upload: UploadSession, onBytesSent: (@Sendable (Int64) -> Void)? = nil) async throws -> UploadedPart {
        var request = try request("PUT", "\(Self.uploadPath(upload))/\(partNumber)")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = onBytesSent.map { UploadProgressDelegate(onBytesSent: $0) }
        let (data, response) = try await perform { try await session.upload(for: request, from: data, delegate: delegate) }
        return try Self.decode(UploadedPart.self, from: data, response: response)
    }

    func completeUpload(_ upload: UploadSession, parts: [UploadedPart]) async throws -> SharedVideo {
        let body = try JSONEncoder().encode(CompleteUploadRequest(parts: parts))
        return try await send(try request("POST", "\(Self.uploadPath(upload))/complete", body: body))
    }

    func abortUpload(_ upload: UploadSession) async throws {
        _ = try await sendRaw(try request("DELETE", Self.uploadPath(upload)))
    }

    func listVideos() async throws -> [SharedVideo] {
        let list: VideoList = try await send(try request("GET", "/api/videos"))
        return list.videos
    }

    func deleteVideo(id: String) async throws {
        _ = try await sendRaw(try request("DELETE", "/api/videos/\(id)"))
    }

    // MARK: - Plumbing

    private static func uploadPath(_ upload: UploadSession) -> String {
        let encodedUploadID = upload.uploadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? upload.uploadId
        return "/api/uploads/\(upload.id)/\(encodedUploadID)"
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: connection.baseURL)?.absoluteURL else {
            throw ShareBackendError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await sendRaw(request)
        return try Self.decode(T.self, from: data, response: response)
    }

    private func sendRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await perform { try await session.data(for: request) }
    }

    /// Maps transport failures to `ShareBackendError`, a cancelled task to `CancellationError`, and non-2xx
    /// statuses to the matching error case.
    private func perform(_ operation: () async throws -> (Data, URLResponse)) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await operation()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw ShareBackendError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ShareBackendError.invalidResponse }
        try Self.check(http, data: data)
        return (data, http)
    }

    static func check(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw ShareBackendError.unauthorized
        case 503:
            throw ShareBackendError.notConfigured
        default:
            let message = errorMessage(in: data) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw ShareBackendError.server(status: response.statusCode, message: message)
        }
    }

    private static func errorMessage(in data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, response: HTTPURLResponse) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw ShareBackendError.invalidResponse
        }
    }

    /// The Worker writes dates with JavaScript's `toISOString()`, which always carries milliseconds.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date \(text)"))
            }
            return date
        }
        return decoder
    }

    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// Forwards `URLSession`'s upload progress for one part.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onBytesSent: @Sendable (Int64) -> Void

    init(onBytesSent: @escaping @Sendable (Int64) -> Void) {
        self.onBytesSent = onBytesSent
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onBytesSent(totalBytesSent)
    }
}

private struct CreateUploadRequest: Encodable {
    let title: String
    let filename: String
    let size: Int64
    let contentType: String
}

private struct CompleteUploadRequest: Encodable {
    let parts: [UploadedPart]
}

private struct VideoList: Decodable {
    let videos: [SharedVideo]
}

private struct ErrorBody: Decodable {
    let error: String
}
