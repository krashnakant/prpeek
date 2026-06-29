import Foundation

/// Typed errors the whole app maps off of. The failure-state UI keys on these
/// cases (plan: "typed error enum"). `.notModified` is internal control flow.
public enum GitHubError: Error, Sendable, Equatable {
    case unauthorized                 // 401 -> re-auth
    case rateLimited(retryAfter: Date?)   // 403/429 secondary or primary limit
    case forbidden                    // 403 not rate-related (e.g. SAML/scope)
    case server(status: Int)          // 5xx -> retry next tick
    case network                      // offline / URLError -> hold + cached
    case decoding(String)             // body didn't match the model
    case notModified                  // 304 -> caller returns cached (internal)
    case invalidResponse

    public static func == (lhs: GitHubError, rhs: GitHubError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.network, .network),
             (.notModified, .notModified),
             (.invalidResponse, .invalidResponse):
            return true
        case let (.rateLimited(a), .rateLimited(b)): return a == b
        case let (.server(a), .server(b)): return a == b
        case let (.decoding(a), .decoding(b)): return a == b
        default: return false
        }
    }
}
