import Foundation
import Security

// MARK: - Identity

/// `GET /user` — the authenticated user. login + node_id drive "waiting on me".
public struct GitHubUser: Codable, Sendable, Equatable {
    public let login: String
    public let nodeID: String
    enum CodingKeys: String, CodingKey { case login; case nodeID = "node_id" }
}

public extension GitHubClient {
    func currentUser() async throws -> GitHubUser {
        try await getValue(GitHubUser.self, path: "/user")
    }
}

// MARK: - Token storage

/// Seam over the Keychain so tests use an in-memory fake (never touch the real
/// Keychain). Both the device-flow token and a pasted PAT land here.
public protocol TokenStore: Sendable {
    func read() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    public init(_ token: String? = nil) { self.token = token }
    public func read() throws -> String? { lock.withLock { token } }
    public func save(_ token: String) throws { lock.withLock { self.token = token } }
    public func delete() throws { lock.withLock { token = nil } }
}

/// Real Keychain-backed store (generic password).
public struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String
    public init(service: String = "PRPeek", account: String = "github-token") {
        self.service = service; self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() throws -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public enum KeychainError: Error, Equatable { case status(OSStatus) }
}

// MARK: - OAuth device flow

public struct DeviceCodeResponse: Codable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    /// When present, this URL pre-fills the user code — open it and the user just
    /// clicks Authorize (no manual paste).
    public let verificationURIComplete: String?
    public let interval: Int
    public let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case interval
        case expiresIn = "expires_in"
    }
    /// Best URL to open: the pre-filled one if GitHub gave it, else the plain page.
    public var bestVerificationURL: URL? {
        URL(string: verificationURIComplete ?? verificationURI)
    }
}

/// Result of one poll of the access-token endpoint. The full poll loop sleeps
/// `interval` between `.pending`/`.slowDown` — kept separate so `pollOnce` is a
/// pure, fast unit test.
public enum DevicePollResult: Sendable, Equatable {
    case pending
    case slowDown
    case token(String)
    case denied
    case expired
}

/// Device flow against github.com (NOT api.github.com). No client secret needed —
/// device flow is designed for clients that can't keep one.
public struct DeviceFlowAuth: Sendable {
    public static let codeURL = URL(string: "https://github.com/login/device/code")!
    public static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let grantType = "urn:ietf:params:oauth:grant-type:device_code"

    let transport: Transport
    let clientID: String
    public init(transport: Transport, clientID: String) {
        self.transport = transport; self.clientID = clientID
    }

    public func requestDeviceCode(scope: String) async throws -> DeviceCodeResponse {
        let body = form(["client_id": clientID, "scope": scope])
        let data = try await postJSON(Self.codeURL, body: body)
        return try decode(DeviceCodeResponse.self, data)
    }

    /// Full device-flow handshake: request a code, hand it to `onCode` (UI shows
    /// it / opens the URL), then poll until authorized. `sleep` is injectable so
    /// the whole loop is unit-testable with no real delay. Honors `slow_down` and
    /// the code's expiry. Returns the access token or throws (denied/expired).
    public func authorize(
        scope: String,
        onCode: @Sendable (DeviceCodeResponse) -> Void,
        sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> String {
        let code = try await requestDeviceCode(scope: scope)
        onCode(code)
        var intervalSecs = max(1, code.interval)
        let maxAttempts = max(1, code.expiresIn / intervalSecs)
        for _ in 0..<maxAttempts {
            try await sleep(UInt64(intervalSecs) * 1_000_000_000)
            switch try await pollOnce(deviceCode: code.deviceCode) {
            case .token(let t): return t
            case .pending: continue
            case .slowDown: intervalSecs += 5
            case .denied: throw DeviceFlowError.denied
            case .expired: throw DeviceFlowError.expired
            }
        }
        throw DeviceFlowError.expired
    }

    public enum DeviceFlowError: Error, Equatable { case denied, expired }

    public func pollOnce(deviceCode: String) async throws -> DevicePollResult {
        let body = form(["client_id": clientID,
                         "device_code": deviceCode,
                         "grant_type": Self.grantType])
        let data = try await postJSON(Self.tokenURL, body: body)
        let resp = try decode(TokenResponse.self, data)
        if let token = resp.accessToken { return .token(token) }
        switch resp.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default: throw GitHubError.decoding("device flow: \(resp.error ?? "unknown")")
        }
    }

    // MARK: helpers
    private struct TokenResponse: Codable {
        let accessToken: String?
        let error: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case error }
    }

    private func form(_ pairs: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }

    private func postJSON(_ url: URL, body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        let (data, http) = try await transport.send(req)
        guard (200...299).contains(http.statusCode) else {
            throw GitHubError.server(status: http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubError.decoding("device flow body: \(error)") }
    }
}
