import Foundation

/// The one method every endpoint rides on (plan: "one conditional-request
/// method"). An actor: serializes ETag-cache + rate-limit state, keeps network
/// off the main thread. Returns Sendable DTOs only — nothing crosses back to the
/// UI except plain Codable values.
public actor GitHubClient {
    public static let dotComBase = URL(string: "https://api.github.com")!

    /// REST API base. github.com -> api.github.com; GHES -> https://HOST/api/v3.
    public static func apiBase(forHost host: String) -> URL {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty || h == "github.com" || h == "api.github.com" { return dotComBase }
        return URL(string: "https://\(h)/api/v3") ?? dotComBase
    }
    /// Web base (device-flow + browser links). github.com -> github.com; GHES -> HOST.
    public static func webBase(forHost host: String) -> URL {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty || h == "github.com" || h == "api.github.com" { return URL(string: "https://github.com")! }
        return URL(string: "https://\(h)") ?? URL(string: "https://github.com")!
    }

    public let baseURL: URL
    private let transport: Transport
    private var token: String?
    /// url string -> (etag, last 200 body). Backs conditional requests; 304 ->
    /// return cached body without burning the primary rate limit.
    private var etagCache: [String: (etag: String, data: Data)]
    private var etagOrder: [String] = []          // FIFO for bounded eviction
    private let etagCap = 600                      // cap: check-runs keyed by head SHA grow forever otherwise

    public init(transport: Transport, token: String? = nil,
                baseURL: URL = GitHubClient.dotComBase,
                etagCache: [String: (etag: String, data: Data)] = [:]) {
        self.transport = transport
        self.token = token
        self.baseURL = baseURL
        self.etagCache = etagCache
        self.etagOrder = Array(etagCache.keys)
    }

    /// Changing the token (sign out / switch account) MUST flush the ETag cache:
    /// the search URL is byte-identical across accounts, so a stale `If-None-Match`
    /// could 304 the previous account's body back. Account-scoped correctness.
    public func setToken(_ token: String?) {
        if token != self.token { etagCache.removeAll(); etagOrder.removeAll() }
        self.token = token
    }

    /// Bounded insert: cap memory over a weeks-long session.
    private func storeETag(_ key: String, etag: String, data: Data) {
        if etagCache[key] == nil {
            etagOrder.append(key)
            if etagOrder.count > etagCap {
                let oldest = etagOrder.removeFirst()
                etagCache.removeValue(forKey: oldest)
            }
        }
        etagCache[key] = (etag, data)
    }

    // MARK: - Public typed reads

    /// Decode a single resource (e.g. GET /user).
    public func getValue<T: Decodable & Sendable>(_ type: T.Type = T.self,
                                                  path: String) async throws -> T {
        let url = baseURL.appending(path: path)
        let (data, _) = try await rawGet(url: url)
        return try decode(T.self, from: data, url: url)
    }

    /// Decode a paginated array endpoint (e.g. /orgs/{org}/repos), following
    /// `Link: rel="next"` to the end. Each page is conditional (per-URL ETag).
    public func getCollection<T: Decodable & Sendable>(_ type: T.Type = T.self,
                                                       path: String) async throws -> [T] {
        var url: URL? = baseURL.appending(path: path)
        var out: [T] = []
        while let current = url {
            let (data, http) = try await rawGet(url: current)
            out.append(contentsOf: try decode([T].self, from: data, url: current))
            url = Self.nextLink(from: http)
        }
        return out
    }

    /// Search endpoints wrap results in `{ "items": [...] }`. Paginate via Link,
    /// stop at `maxItems` (GitHub Search hard-caps at 1000). `pathAndQuery`
    /// includes the `?q=...` — caller pre-encodes it.
    public func getSearchItems<Item: Decodable & Sendable>(_ type: Item.Type = Item.self,
                                                           pathAndQuery: String,
                                                           maxItems: Int = 1000) async throws -> [Item] {
        var url: URL? = URL(string: baseURL.absoluteString + pathAndQuery)
        var out: [Item] = []
        while let current = url, out.count < maxItems {
            let (data, http) = try await rawGet(url: current)
            let page = try decode(SearchPage<Item>.self, from: data, url: current)
            out.append(contentsOf: page.items)
            url = Self.nextLink(from: http)
        }
        return Array(out.prefix(maxItems))
    }

    /// Raw conditional GET. Maps status -> typed errors; on 304 returns the
    /// cached body paired with the live response (for Link/rate-limit headers).
    func rawGet(url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let cached = etagCache[url.absoluteString] {
            req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, http) = try await transport.send(req)

        switch http.statusCode {
        case 200:
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                storeETag(url.absoluteString, etag: etag, data: data)
            }
            return (data, http)
        case 304:
            guard let cached = etagCache[url.absoluteString] else {
                throw GitHubError.invalidResponse // 304 with no cache = bug upstream
            }
            return (cached.data, http)
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            throw Self.rateLimitOrForbidden(http)
        default:                       // 5xx and any other unexpected status
            throw GitHubError.server(status: http.statusCode)
        }
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, url: URL) throws -> T {
        do { return try JSONDecoder.github.decode(T.self, from: data) }
        catch { throw GitHubError.decoding("\(url.path): \(error)") }
    }

    /// 403/429 is overloaded on GitHub: secondary-rate-limit vs a plain forbidden
    /// (missing scope, SAML). Distinguish by the rate headers.
    static func rateLimitOrForbidden(_ http: HTTPURLResponse) -> GitHubError {
        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let hasRetryAfter = http.value(forHTTPHeaderField: "Retry-After") != nil
        if remaining == 0 || hasRetryAfter {
            return .rateLimited(retryAfter: retryAfterDate(http))
        }
        return .forbidden
    }

    /// Prefer `Retry-After` (seconds); fall back to `X-RateLimit-Reset` (epoch).
    static func retryAfterDate(_ http: HTTPURLResponse) -> Date? {
        if let ra = http.value(forHTTPHeaderField: "Retry-After"), let secs = TimeInterval(ra) {
            return Date().addingTimeInterval(secs)
        }
        if let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset"), let epoch = TimeInterval(reset) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    /// Parse `Link: <url>; rel="next", <url>; rel="last"` -> the next URL.
    static func nextLink(from http: HTTPURLResponse) -> URL? {
        guard let header = http.value(forHTTPHeaderField: "Link") else { return nil }
        for part in header.split(separator: ",") {
            let segs = part.split(separator: ";")
            guard segs.count >= 2 else { continue }
            let urlPart = segs[0].trimmingCharacters(in: .whitespaces)
            let relPart = segs[1].trimmingCharacters(in: .whitespaces)
            if relPart == "rel=\"next\"",
               urlPart.hasPrefix("<"), urlPart.hasSuffix(">") {
                return URL(string: String(urlPart.dropFirst().dropLast()))
            }
        }
        return nil
    }
}

extension JSONDecoder {
    /// GitHub timestamps are ISO8601; snake_case mapped via explicit CodingKeys
    /// in the DTOs (so we don't silently mangle fields).
    static let github: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
