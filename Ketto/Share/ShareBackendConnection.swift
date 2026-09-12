import Foundation
import Security

/// Where shared videos go: the origin of the user's Worker plus the bearer token that lets this app write to it.
/// The token never leaves the machine except inside the Worker's own secret, so every Ketto that holds it shares
/// the same bucket and nothing else can write there.
struct ShareBackendConnection: Equatable, Sendable {
    let baseURL: URL
    let token: String

    init(baseURL: URL, token: String) throws {
        self.baseURL = try Self.normalize(baseURL)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw ShareBackendConnectionError.invalidToken
        }
        self.token = trimmed
    }

    /// Accepts `share.example.com`, `https://share.example.com/`, or `http://localhost:8787` for a local Worker.
    init(urlText: String, token: String) throws {
        try self.init(baseURL: try Self.parseBaseURL(urlText), token: token)
    }

    var host: String { baseURL.host(percentEncoded: false) ?? "" }

    /// `share.example.com`, or `localhost:8787` for a development server.
    var displayName: String {
        if let port = baseURL.port { return "\(host):\(port)" }
        return host
    }

    static func parseBaseURL(_ text: String) throws -> URL {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw ShareBackendConnectionError.invalidURL(text) }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate) else { throw ShareBackendConnectionError.invalidURL(text) }
        return try normalize(url)
    }

    /// Keeps scheme, host and port only. Only HTTPS is accepted, except for a development server on this machine:
    /// the token is a bearer token, so it must never travel in the clear.
    static func normalize(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            throw ShareBackendConnectionError.invalidURL(url.absoluteString)
        }
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(host)
        switch scheme {
        case "https":
            break
        case "http" where isLocal:
            break
        case "http":
            throw ShareBackendConnectionError.insecureURL(url.absoluteString)
        default:
            throw ShareBackendConnectionError.invalidURL(url.absoluteString)
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        guard let normalized = components.url else { throw ShareBackendConnectionError.invalidURL(url.absoluteString) }
        return normalized
    }
}

enum ShareBackendConnectionError: Error, LocalizedError, Equatable {
    case invalidURL(String)
    case insecureURL(String)
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .invalidURL(let text):
            return "\u{201C}\(text)\u{201D} is not a backend address. Enter the domain the setup command used, like share.example.com."
        case .insecureURL:
            return "The backend address must use HTTPS."
        case .invalidToken:
            return "The token is missing or contains spaces."
        }
    }
}

// MARK: - Persistence

/// Keeps the token somewhere safer than a preferences file. The Keychain in the app; memory in tests.
protocol ShareTokenStore: Sendable {
    func token(for account: String) throws -> String?
    /// `nil` removes the item.
    func setToken(_ token: String?, for account: String) throws
}

struct KeychainTokenStore: ShareTokenStore {
    var service = "cc.ketto.share"

    func token(for account: String) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func setToken(_ token: String?, for account: String) throws {
        let query = baseQuery(for: account)
        let removed = SecItemDelete(query as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw KeychainError(status: removed) }
        guard let token else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrLabel as String] = "Ketto sharing token"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain refused the sharing token: \(message)"
    }
}

final class InMemoryTokenStore: ShareTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    init() {}

    func token(for account: String) throws -> String? {
        lock.withLock { tokens[account] }
    }

    func setToken(_ token: String?, for account: String) throws {
        lock.withLock { tokens[account] = token }
    }
}

/// Persists the connection: the address in `UserDefaults`, the token in the token store. The Keychain is only
/// consulted once an address is stored, so a user who never sets up sharing never sees a Keychain prompt.
@MainActor
struct ShareBackendStore {
    static let urlKey = "shareBackendURL"

    private let defaults: UserDefaults
    private let tokens: any ShareTokenStore

    init(defaults: UserDefaults = .standard, tokens: any ShareTokenStore = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokens = tokens
    }

    func load() throws -> ShareBackendConnection? {
        guard let text = defaults.string(forKey: Self.urlKey), let url = URL(string: text) else { return nil }
        guard let token = try tokens.token(for: Self.account(for: url)) else { return nil }
        return try ShareBackendConnection(baseURL: url, token: token)
    }

    func save(_ connection: ShareBackendConnection) throws {
        try tokens.setToken(connection.token, for: Self.account(for: connection.baseURL))
        defaults.set(connection.baseURL.absoluteString, forKey: Self.urlKey)
    }

    func clear() throws {
        if let text = defaults.string(forKey: Self.urlKey), let url = URL(string: text) {
            try tokens.setToken(nil, for: Self.account(for: url))
        }
        defaults.removeObject(forKey: Self.urlKey)
    }

    /// One Keychain item per backend address, so a development server and the real one never overwrite each other.
    static func account(for url: URL) -> String {
        url.absoluteString
    }
}
