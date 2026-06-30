import Foundation

/// The seam every network call goes through.
/// - GitHubClient integration tests inject a `URLSessionTransport` backed by a
///   URLSession whose `URLProtocol` is stubbed (decision 3C: real request code).
/// - Poller/Classifier unit tests inject a hand-written fake (decision 3C).
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport. Wraps a URLSession so tests can pass a session with a
/// custom URLProtocol registered.
public struct URLSessionTransport: Transport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubError.invalidResponse
            }
            return (data, http)
        } catch is URLError {
            // offline / timeout / DNS / etc -> the app's "hold + show cached" path
            throw GitHubError.network
        }
    }
}
