import Foundation
import Security

/// The `wrangler.json` for the user's Worker. Written by the app so the domain, bucket and Worker name are filled
/// in; `WorkerTests/wrangler.jsonc` mirrors it for local runs.
struct WranglerConfig: Codable, Equatable, Sendable {
    struct Route: Codable, Equatable, Sendable {
        var pattern: String
        var customDomain: Bool

        enum CodingKeys: String, CodingKey {
            case pattern
            case customDomain = "custom_domain"
        }
    }

    struct R2Bucket: Codable, Equatable, Sendable {
        var binding: String
        var bucketName: String

        enum CodingKeys: String, CodingKey {
            case binding
            case bucketName = "bucket_name"
        }
    }

    var name: String
    var main: String
    var compatibilityDate: String
    var workersDev: Bool
    var vars: [String: String]
    var routes: [Route]
    var r2Buckets: [R2Bucket]

    enum CodingKeys: String, CodingKey {
        case name, main, vars, routes
        case compatibilityDate = "compatibility_date"
        case workersDev = "workers_dev"
        case r2Buckets = "r2_buckets"
    }

    static func ketto(domain: String, bucket: String, worker: String) -> WranglerConfig {
        WranglerConfig(
            name: worker,
            main: "worker.js",
            compatibilityDate: ShareSetupBundle.compatibilityDate,
            workersDev: false,
            vars: ["BUCKET_NAME": bucket],
            routes: [Route(pattern: domain, customDomain: true)],
            r2Buckets: [R2Bucket(binding: "VIDEOS", bucketName: bucket)]
        )
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Everything the setup command needs, written to one folder that `setup.sh` runs from: the Worker source and
/// script from the app bundle, plus the generated `wrangler.json`, `config.env` and `secret.txt`.
struct ShareSetupBundle: Equatable, Sendable {
    static let workerName = "ketto-share"
    static let bucketName = "ketto-videos"
    /// Keep in step with `WorkerTests/wrangler.jsonc`.
    static let compatibilityDate = "2026-08-01"
    static let bundledFiles = ["worker.js", "setup.sh"]

    let directory: URL
    let domain: String
    let token: String

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Ketto/Cloudflare", isDirectory: true)
    }

    init(domain: String, token: String = makeToken(), directory: URL = defaultDirectory) throws {
        self.domain = try Self.validateDomain(domain)
        self.token = token
        self.directory = directory
    }

    /// The domain is validated, so this always parses.
    var baseURL: URL { URL(string: "https://\(domain)")! }
    var scriptURL: URL { directory.appendingPathComponent("setup.sh") }
    var secretURL: URL { directory.appendingPathComponent("secret.txt") }

    func connection() throws -> ShareBackendConnection {
        try ShareBackendConnection(baseURL: baseURL, token: token)
    }

    /// The one line the user runs. `$HOME` stands in for the home directory so the command reads the same on every
    /// machine, and the quotes cope with the space in "Application Support".
    var command: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = scriptURL.path
        if path.hasPrefix(home + "/") { path = "$HOME" + path.dropFirst(home.count) }
        return "bash \"\(path)\""
    }

    /// Lower-cases, strips a scheme and trailing slashes, and insists on a real hostname with at least two labels.
    static func validateDomain(_ text: String) throws -> String {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where candidate.hasPrefix(prefix) {
            candidate.removeFirst(prefix.count)
        }
        while candidate.hasSuffix("/") { candidate.removeLast() }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isValidLabel) else { throw ShareSetupError.invalidDomain(text) }
        return candidate
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// 256 random bits as 64 hex characters.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the folder. Existing files are replaced, so generating again after a failed run is safe.
    func write(resources bundle: Bundle = .main) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in Self.bundledFiles {
            guard let source = Self.resourceURL(named: name, in: bundle) else { throw ShareSetupError.missingResource(name) }
            let target = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: source, to: target)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let config = WranglerConfig.ketto(domain: domain, bucket: Self.bucketName, worker: Self.workerName)
        try config.encoded().write(to: directory.appendingPathComponent("wrangler.json"), options: .atomic)
        let env = "KETTO_DOMAIN=\(domain)\nKETTO_BUCKET=\(Self.bucketName)\nKETTO_WORKER=\(Self.workerName)\n"
        try Data(env.utf8).write(to: directory.appendingPathComponent("config.env"), options: .atomic)
        if fileManager.fileExists(atPath: secretURL.path) { try fileManager.removeItem(at: secretURL) }
        guard fileManager.createFile(atPath: secretURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ShareSetupError.cannotWrite(secretURL)
        }
    }

    /// Removes the token file once the app holds the token in the Keychain, or when the setup is abandoned.
    func removeSecret() {
        try? FileManager.default.removeItem(at: secretURL)
    }

    /// A setup generated earlier and not finished: `config.env` and `secret.txt` are still in the folder.
    static func pending(in directory: URL = defaultDirectory) -> ShareSetupBundle? {
        guard let env = try? String(contentsOf: directory.appendingPathComponent("config.env"), encoding: .utf8),
              let token = try? String(contentsOf: directory.appendingPathComponent("secret.txt"), encoding: .utf8) else {
            return nil
        }
        let prefix = "KETTO_DOMAIN="
        guard let line = env.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let domain = String(line.dropFirst(prefix.count))
        return try? ShareSetupBundle(domain: domain, token: token.trimmingCharacters(in: .whitespacesAndNewlines), directory: directory)
    }

    /// The synchronized folder group copies resources flat into the bundle; the subdirectory forms are fallbacks in
    /// case that ever changes.
    static func resourceURL(named name: String, in bundle: Bundle) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return bundle.url(forResource: base, withExtension: ext)
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "CloudflareBackend")
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Resources/CloudflareBackend")
    }
}

enum ShareSetupError: Error, LocalizedError, Equatable {
    case invalidDomain(String)
    case missingResource(String)
    case cannotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .invalidDomain(let text):
            return "\u{201C}\(text)\u{201D} is not a domain name. Enter something like share.example.com, without a path."
        case .missingResource(let name):
            return "This build of Ketto is missing \(name); reinstall it."
        case .cannotWrite(let url):
            return "Could not write \(url.path)."
        }
    }
}
