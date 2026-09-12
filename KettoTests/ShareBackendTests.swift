import XCTest
import os
@testable import Ketto

// MARK: - Partition plan

final class PartitionPlanTests: XCTestCase {
    func testSplitsIntoEqualPartsWithAShorterTail() throws {
        let plan = try PartitionPlan(fileSize: 100, partSize: 32)
        XCTAssertEqual(plan.parts.map(\.length), [32, 32, 32, 4])
        XCTAssertEqual(plan.parts.map(\.offset), [0, 32, 64, 96])
        XCTAssertEqual(plan.parts.map(\.number), [1, 2, 3, 4])
    }

    func testExactMultipleHasNoTail() throws {
        XCTAssertEqual(try PartitionPlan(fileSize: 64, partSize: 32).parts.map(\.length), [32, 32])
    }

    func testSmallFileIsASinglePart() throws {
        XCTAssertEqual(try PartitionPlan(fileSize: 10, partSize: 32).parts.map(\.length), [10])
    }

    func testEmptyFileIsRejected() {
        XCTAssertThrowsError(try PartitionPlan(fileSize: 0, partSize: 32))
        XCTAssertThrowsError(try PartitionPlan(fileSize: 10, partSize: 0))
    }
}

// MARK: - Connection

final class ShareBackendConnectionTests: XCTestCase {
    func testBareHostBecomesHTTPS() throws {
        let connection = try ShareBackendConnection(urlText: " Share.Example.com ", token: "abc")
        XCTAssertEqual(connection.baseURL.absoluteString, "https://share.example.com")
        XCTAssertEqual(connection.displayName, "share.example.com")
        XCTAssertEqual(connection.token, "abc")
    }

    func testPathQueryAndTrailingSlashAreDropped() throws {
        let connection = try ShareBackendConnection(urlText: "https://share.example.com/v/abc?x=1", token: "t")
        XCTAssertEqual(connection.baseURL.absoluteString, "https://share.example.com")
    }

    func testPlainHTTPIsRejectedExceptOnThisMachine() throws {
        XCTAssertThrowsError(try ShareBackendConnection(urlText: "http://share.example.com", token: "t"))
        let local = try ShareBackendConnection(urlText: "http://localhost:8787", token: "t")
        XCTAssertEqual(local.baseURL.absoluteString, "http://localhost:8787")
        XCTAssertEqual(local.displayName, "localhost:8787")
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try ShareBackendConnection(urlText: "", token: "t"))
        XCTAssertThrowsError(try ShareBackendConnection(urlText: "ftp://x.example.com", token: "t"))
    }

    func testTokenMustBeOneWord() {
        XCTAssertThrowsError(try ShareBackendConnection(urlText: "share.example.com", token: "  "))
        XCTAssertThrowsError(try ShareBackendConnection(urlText: "share.example.com", token: "a b"))
    }
}

// MARK: - Store

@MainActor
final class ShareBackendStoreTests: XCTestCase {
    func testRoundTripAndClear() throws {
        let suite = "cc.ketto.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = InMemoryTokenStore()
        let store = ShareBackendStore(defaults: defaults, tokens: tokens)
        XCTAssertNil(try store.load())

        let connection = try ShareBackendConnection(urlText: "share.example.com", token: "secret")
        try store.save(connection)
        XCTAssertEqual(try store.load(), connection)
        XCTAssertEqual(try tokens.token(for: "https://share.example.com"), "secret")

        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNil(try tokens.token(for: "https://share.example.com"))
    }

    func testMissingTokenMeansNotConnected() throws {
        let suite = "cc.ketto.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://share.example.com", forKey: ShareBackendStore.urlKey)
        let store = ShareBackendStore(defaults: defaults, tokens: InMemoryTokenStore())
        XCTAssertNil(try store.load())
    }
}

// MARK: - Setup bundle

final class ShareSetupBundleTests: XCTestCase {
    func testDomainValidation() throws {
        XCTAssertEqual(try ShareSetupBundle.validateDomain("  HTTPS://Share.Example.com/ "), "share.example.com")
        XCTAssertEqual(try ShareSetupBundle.validateDomain("example.com"), "example.com")
        XCTAssertEqual(try ShareSetupBundle.validateDomain("a-b.c1.example.co.uk"), "a-b.c1.example.co.uk")
        for bad in ["", "example", "-bad.example.com", "bad-.example.com", "a b.example.com", "share.example.com/path", ".example.com", "share..example.com"] {
            XCTAssertThrowsError(try ShareSetupBundle.validateDomain(bad), bad)
        }
    }

    func testTokenIs64LowercaseHexCharacters() {
        let token = ShareSetupBundle.makeToken()
        XCTAssertEqual(token.count, 64)
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertNotEqual(token, ShareSetupBundle.makeToken())
    }

    func testWritesTheSetupFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ketto-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = String(repeating: "a", count: 64)
        let bundle = try ShareSetupBundle(domain: "share.example.com", token: token, directory: directory)
        try bundle.write()

        let config = try JSONDecoder().decode(WranglerConfig.self, from: Data(contentsOf: directory.appendingPathComponent("wrangler.json")))
        XCTAssertEqual(config, WranglerConfig.ketto(domain: "share.example.com", bucket: "ketto-videos", worker: "ketto-share"))
        XCTAssertEqual(config.routes, [WranglerConfig.Route(pattern: "share.example.com", customDomain: true)])
        XCTAssertFalse(config.workersDev)
        XCTAssertEqual(config.main, "worker.js")
        XCTAssertEqual(config.r2Buckets, [WranglerConfig.R2Bucket(binding: "VIDEOS", bucketName: "ketto-videos")])
        XCTAssertEqual(config.vars["BUCKET_NAME"], "ketto-videos")

        let env = try String(contentsOf: directory.appendingPathComponent("config.env"), encoding: .utf8)
        XCTAssertEqual(env, "KETTO_DOMAIN=share.example.com\nKETTO_BUCKET=ketto-videos\nKETTO_WORKER=ketto-share\n")

        XCTAssertEqual(try String(contentsOf: bundle.secretURL, encoding: .utf8), token)
        let permissions = try FileManager.default.attributesOfItem(atPath: bundle.secretURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundle.scriptURL.path))
        XCTAssertTrue(try String(contentsOf: bundle.scriptURL, encoding: .utf8).hasPrefix("#!/bin/bash"))
        let worker = try String(contentsOf: directory.appendingPathComponent("worker.js"), encoding: .utf8)
        XCTAssertTrue(worker.contains("const API_VERSION = \(ShareBackendClient.apiVersion);"))

        XCTAssertEqual(ShareSetupBundle.pending(in: directory), bundle)
        bundle.removeSecret()
        XCTAssertNil(ShareSetupBundle.pending(in: directory))
    }

    /// The wrangler commands the prompt gives the agent; `setup.sh` must run the same ones (see the next test).
    private static let setupCommands = [
        "wrangler r2 bucket create ketto-videos",
        "wrangler r2 bucket lifecycle add ketto-videos ketto-expire --expire-days 3 --abort-multipart-days 1 --force",
        "wrangler deploy",
        "wrangler secret put KETTO_TOKEN < secret.txt",
    ]

    func testPromptNamesTheFolderAndTheStepsButNeverTheToken() throws {
        let directory = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Ketto/Cloudflare", isDirectory: true)
        let token = String(repeating: "b", count: 64)
        let bundle = try ShareSetupBundle(domain: "share.example.com", token: token, directory: directory)
        let prompt = bundle.prompt

        XCTAssertTrue(prompt.contains("\n  /Users/someone/Library/Application Support/Ketto/Cloudflare\n"))
        XCTAssertEqual(bundle.scriptCommand, "bash \"/Users/someone/Library/Application Support/Ketto/Cloudflare/setup.sh\"")
        XCTAssertTrue(prompt.contains("`\(bundle.scriptCommand)`"))
        for expected in Self.setupCommands + [
            "custom domain share.example.com",
            "`curl -s https://share.example.com/`",
            "{\"service\":\"ketto-share\",\"api\":\(ShareBackendClient.apiVersion)}",
        ] {
            XCTAssertTrue(prompt.contains(expected), expected)
        }
        XCTAssertFalse(prompt.contains(token), "the token stays in secret.txt, out of the clipboard and the agent's transcript")
        XCTAssertFalse(prompt.contains("$HOME"), "paths are absolute so the agent's file tools can use them")

        XCTAssertEqual(bundle.baseURL.absoluteString, "https://share.example.com")
        XCTAssertEqual(try bundle.connection().token, token)
    }

    /// The prompt and the bundled script describe the same setup: every command the prompt gives the agent is one
    /// the script runs, with the bucket name filled in.
    func testPromptCommandsMatchTheScript() throws {
        let scriptURL = try XCTUnwrap(ShareSetupBundle.resourceURL(named: "setup.sh", in: .main))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
            .replacingOccurrences(of: "\"$KETTO_BUCKET\"", with: ShareSetupBundle.bucketName)
            .replacingOccurrences(of: "< ./secret.txt", with: "< secret.txt")
        for command in Self.setupCommands {
            XCTAssertTrue(script.contains(command), command)
        }
    }
}

// MARK: - Stub transport

/// Routes every request of a test `URLSession` to an in-memory stand-in for the Worker.
final class StubURLProtocol: URLProtocol {
    struct Recorded: Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data
    }

    typealias Handler = @Sendable (Recorded) -> (status: Int, body: Data)

    private static let handler = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let recorded = OSAllocatedUnfairLock(initialState: [Recorded]())

    static func install(_ handler: @escaping Handler) -> URLSession {
        self.handler.withLock { $0 = handler }
        recorded.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [Recorded] { recorded.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream { body = Self.drain(stream) }
        let recorded = Recorded(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        Self.recorded.withLock { $0.append(recorded) }
        let (status, data) = Self.handler.withLock { $0 }?(recorded) ?? (500, Data())
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The Worker's behaviour, as far as the client and destination tests need it: multipart bookkeeping plus knobs
/// to make parts fail.
final class FakeWorker: @unchecked Sendable {
    static let videoID = "abcdefghijklmnopqrstuvwxyz"
    static let uploadID = "up+1/2=?"
    static let link = "https://share.example.com/v/\(videoID)"

    let partSize: Int
    private let lock = NSLock()
    private var parts: [Int: Data] = [:]
    private var completedParts: [UploadedPart]?
    private var wasAborted = false
    /// Part numbers that answer 502 the first time they are sent.
    var flakyParts: Set<Int> = []
    /// Part numbers that always answer 400.
    var rejectedParts: Set<Int> = []
    var onPart: (@Sendable (Int) -> Void)?

    init(partSize: Int) {
        self.partSize = partSize
    }

    var completed: [UploadedPart]? { lock.withLock { completedParts } }
    var aborted: Bool { lock.withLock { wasAborted } }
    var receivedBytes: Data {
        lock.withLock { parts.keys.sorted().reduce(into: Data()) { $0.append(parts[$1] ?? Data()) } }
    }

    func handle(_ request: StubURLProtocol.Recorded) -> (status: Int, body: Data) {
        guard let url = URL(string: request.url) else { return (500, Data()) }
        let path = url.path(percentEncoded: true)
        let encodedUploadID = Self.uploadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let uploadPrefix = "/api/uploads/\(Self.videoID)/\(encodedUploadID)"
        let video: [String: Any] = [
            "id": Self.videoID, "title": "Demo", "size": 70,
            "uploaded": "2026-09-12T10:00:00.000Z", "expires": "2026-09-15T10:00:00.000Z", "url": Self.link,
        ]
        switch (request.method, path) {
        case ("GET", "/api/status"):
            return (200, json(["ok": true, "api": 1, "bucket": "ketto-videos"]))
        case ("POST", "/api/uploads"):
            return (201, json(["id": Self.videoID, "uploadId": Self.uploadID, "partSize": partSize]))
        case ("PUT", let partPath) where partPath.hasPrefix(uploadPrefix + "/"):
            let number = Int(partPath.dropFirst(uploadPrefix.count + 1)) ?? 0
            return lock.withLock {
                onPart?(number)
                if rejectedParts.contains(number) { return (400, json(["error": "bad part"])) }
                if flakyParts.remove(number) != nil { return (502, json(["error": "flaky"])) }
                parts[number] = request.body
                return (200, json(["partNumber": number, "etag": "etag-\(number)"]))
            }
        case ("POST", uploadPrefix + "/complete"):
            let payload = try? JSONDecoder().decode(CompleteBody.self, from: request.body)
            lock.withLock { completedParts = payload?.parts }
            return (201, json(video))
        case ("DELETE", uploadPrefix):
            lock.withLock { wasAborted = true }
            return (204, Data())
        case ("GET", "/api/videos"):
            return (200, json(["videos": [video]]))
        case ("DELETE", "/api/videos/\(Self.videoID)"):
            return (204, Data())
        default:
            return (404, json(["error": "Not found"]))
        }
    }

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }

    private struct CompleteBody: Decodable {
        let parts: [UploadedPart]
    }
}

// MARK: - Client

final class ShareBackendClientTests: XCTestCase {
    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) throws -> ShareBackendClient {
        let session = StubURLProtocol.install(handler)
        return ShareBackendClient(connection: try ShareBackendConnection(urlText: "share.example.com", token: "tok"), session: session)
    }

    func testStatusSendsTheTokenAndChecksTheAPIVersion() async throws {
        let worker = FakeWorker(partSize: 32)
        let client = try makeClient { worker.handle($0) }
        let status = try await client.status()
        XCTAssertEqual(status, ShareBackendStatus(ok: true, api: 1, bucket: "ketto-videos"))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, "https://share.example.com/api/status")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok")
    }

    func testIncompatibleAPIVersionIsReported() async throws {
        let client = try makeClient { _ in (200, Data(#"{"ok":true,"api":2,"bucket":null}"#.utf8)) }
        await assertThrows(.incompatible(api: 2)) { _ = try await client.status() }
    }

    func testErrorStatusesMapToErrors() async throws {
        let unauthorized = try makeClient { _ in (401, Data(#"{"error":"Unauthorized"}"#.utf8)) }
        await assertThrows(.unauthorized) { _ = try await unauthorized.listVideos() }
        let notConfigured = try makeClient { _ in (503, Data()) }
        await assertThrows(.notConfigured) { _ = try await notConfigured.status() }
        let broken = try makeClient { _ in (500, Data(#"{"error":"boom"}"#.utf8)) }
        await assertThrows(.server(status: 500, message: "boom")) { _ = try await broken.listVideos() }
        let garbage = try makeClient { _ in (200, Data("<html>".utf8)) }
        await assertThrows(.invalidResponse) { _ = try await garbage.listVideos() }
    }

    func testListVideosDecodesDates() async throws {
        let worker = FakeWorker(partSize: 32)
        let client = try makeClient { worker.handle($0) }
        let videos = try await client.listVideos()
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].id, FakeWorker.videoID)
        XCTAssertEqual(videos[0].title, "Demo")
        XCTAssertEqual(videos[0].size, 70)
        XCTAssertEqual(videos[0].uploaded, ShareBackendClient.parseDate("2026-09-12T10:00:00.000Z"))
        XCTAssertEqual(videos[0].expires.timeIntervalSince(videos[0].uploaded), 3 * 24 * 3600)
        XCTAssertEqual(videos[0].url.absoluteString, FakeWorker.link)
    }

    func testDeleteVideoAcceptsNoContent() async throws {
        let worker = FakeWorker(partSize: 32)
        let client = try makeClient { worker.handle($0) }
        try await client.deleteVideo(id: FakeWorker.videoID)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url, "https://share.example.com/api/videos/\(FakeWorker.videoID)")
    }

    private func assertThrows(_ expected: ShareBackendError, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as ShareBackendError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}

// MARK: - Destination

final class CloudflareShareDestinationTests: XCTestCase {
    private let contents = Data((0..<70).map { UInt8($0) })
    private var fileURL: URL?

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ketto-share-\(UUID().uuidString).mp4")
        try contents.write(to: url)
        fileURL = url
    }

    override func tearDownWithError() throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func makeDestination(_ worker: FakeWorker) throws -> CloudflareShareDestination {
        let session = StubURLProtocol.install { worker.handle($0) }
        let client = ShareBackendClient(connection: try ShareBackendConnection(urlText: "share.example.com", token: "tok"), session: session)
        var destination = CloudflareShareDestination(client: client)
        destination.retryDelay = .milliseconds(1)
        return destination
    }

    func testUploadsInPartsAndReturnsTheLink() async throws {
        let file = try XCTUnwrap(fileURL)
        let worker = FakeWorker(partSize: 32)
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        let destination = try makeDestination(worker)

        let link = try await destination.upload(file, metadata: VideoMetadata(title: "Demo")) { fraction in
            fractions.withLock { $0.append(fraction) }
        }

        XCTAssertEqual(link.absoluteString, FakeWorker.link)
        let puts = StubURLProtocol.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.map(\.body.count), [32, 32, 6])
        XCTAssertEqual(puts.map(\.url), (1...3).map { "https://share.example.com/api/uploads/\(FakeWorker.videoID)/up%2B1%2F2%3D%3F/\($0)" })
        XCTAssertEqual(puts.first?.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(worker.receivedBytes, contents)
        XCTAssertEqual(worker.completed, (1...3).map { UploadedPart(partNumber: $0, etag: "etag-\($0)") })
        XCTAssertFalse(worker.aborted)

        let create = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(create.method, "POST")
        XCTAssertEqual(create.url, "https://share.example.com/api/uploads")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        XCTAssertEqual(payload["title"] as? String, "Demo")
        XCTAssertEqual(payload["size"] as? Int, 70)
        XCTAssertEqual(payload["contentType"] as? String, "video/mp4")

        let reported = fractions.withLock { $0 }
        XCTAssertEqual(reported.first, 0)
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted())
    }

    func testRetriesAPartAfterAServerError() async throws {
        let file = try XCTUnwrap(fileURL)
        let worker = FakeWorker(partSize: 32)
        worker.flakyParts = [2]
        let destination = try makeDestination(worker)
        _ = try await destination.upload(file, metadata: VideoMetadata(title: "Demo"), progress: { _ in })
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.method == "PUT" }.count, 4)
        XCTAssertEqual(worker.receivedBytes, contents)
        XCTAssertFalse(worker.aborted)
    }

    func testGivesUpOnAClientErrorAndAborts() async throws {
        let file = try XCTUnwrap(fileURL)
        let worker = FakeWorker(partSize: 32)
        worker.rejectedParts = [2]
        let destination = try makeDestination(worker)
        do {
            _ = try await destination.upload(file, metadata: VideoMetadata(title: "Demo"), progress: { _ in })
            XCTFail("Expected the upload to fail")
        } catch let error as ShareBackendError {
            XCTAssertEqual(error, .server(status: 400, message: "bad part"))
        }
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.method == "PUT" }.count, 2)
        XCTAssertNil(worker.completed)
        try await waitUntil { worker.aborted }
    }

    func testCancellationStopsTheUploadAndAborts() async throws {
        let file = try XCTUnwrap(fileURL)
        let worker = FakeWorker(partSize: 32)
        let destination = try makeDestination(worker)
        let uploadTask = OSAllocatedUnfairLock<Task<URL, Error>?>(initialState: nil)
        worker.onPart = { number in
            if number == 2 { uploadTask.withLock { $0 }?.cancel() }
        }
        let task = Task {
            try await destination.upload(file, metadata: VideoMetadata(title: "Demo"), progress: { _ in })
        }
        uploadTask.withLock { $0 = task }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertNil(worker.completed)
        try await waitUntil { worker.aborted }
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool, timeout: Duration = .seconds(2), file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("Timed out waiting for the condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
