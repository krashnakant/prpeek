import Foundation

/// Typed errors the whole app maps off of. The failure-state UI keys on these
/// cases (plan: "typed error enum"). Equatable is compiler-synthesized — every
/// payload (Date?/Int/String) is itself Equatable.
public enum GitHubError: Error, Sendable, Equatable {
    case unauthorized                 // 401 -> re-auth
    case rateLimited(retryAfter: Date?)   // 403/429 secondary or primary limit
    case forbidden                    // 403 not rate-related (e.g. SAML/scope)
    /// A write GitHub understood and refused: not mergeable (405), head moved
    /// (409), bad reviewer (422). `message` is GitHub's own sentence — the only
    /// error whose text is worth showing verbatim.
    case rejected(status: Int, message: String)
    case server(status: Int)          // 5xx -> retry next tick
    case network                      // offline / URLError -> hold + cached
    case decoding(String)             // body didn't match the model
    case invalidResponse
}
