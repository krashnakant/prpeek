import XCTest
@testable import PRPeekCore

/// Hand fake (decision 3C: Transport fake for non-client units). Returns a
/// scripted body per call so we can drive device-flow poll-state sequences.
final class FakeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(Int, Data)]
    init(_ responses: [(Int, Data)]) { self.queue = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, data): (Int, Data) = lock.withLock {
            queue.isEmpty ? (200, Data()) : queue.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, http)
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

/// Reference box so the @Sendable onCode closure can hand a value back to the test.
final class CodeBox: @unchecked Sendable {
    private let lock = NSLock(); private var c: DeviceCodeResponse?
    func set(_ x: DeviceCodeResponse) { lock.withLock { c = x } }
    var value: DeviceCodeResponse? { lock.withLock { c } }
}

final class AuthTests: XCTestCase {

    func test_requestDeviceCode_parses_fields() async throws {
        let body = json(#"{"device_code":"DC","user_code":"WXYZ-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
        let flow = DeviceFlowAuth(transport: FakeTransport([(200, body)]), clientID: "cid")
        let resp = try await flow.requestDeviceCode(scope: "repo read:org")
        XCTAssertEqual(resp, DeviceCodeResponse(deviceCode: "DC", userCode: "WXYZ-1234",
                                                verificationURI: "https://github.com/login/device",
                                                verificationURIComplete: nil,
                                                interval: 5, expiresIn: 900))
    }

    func test_pollOnce_states() async throws {
        func poll(_ b: String) async throws -> DevicePollResult {
            try await DeviceFlowAuth(transport: FakeTransport([(200, json(b))]), clientID: "cid")
                .pollOnce(deviceCode: "DC")
        }
        let pending = try await poll(#"{"error":"authorization_pending"}"#)
        XCTAssertEqual(pending, .pending)
        let slow = try await poll(#"{"error":"slow_down","interval":10}"#)
        XCTAssertEqual(slow, .slowDown)
        let denied = try await poll(#"{"error":"access_denied"}"#)
        XCTAssertEqual(denied, .denied)
        let expired = try await poll(#"{"error":"expired_token"}"#)
        XCTAssertEqual(expired, .expired)
        let ok = try await poll(#"{"access_token":"gho_abc","token_type":"bearer","scope":"repo"}"#)
        XCTAssertEqual(ok, .token("gho_abc"))
    }

    func test_authorize_loops_through_pending_to_token() async throws {
        let code = #"{"device_code":"DC","user_code":"AAAA-BBBB","verification_uri":"https://github.com/login/device","verification_uri_complete":"https://github.com/login/device?user_code=AAAA-BBBB","expires_in":900,"interval":1}"#
        let flow = DeviceFlowAuth(transport: FakeTransport([
            (200, json(code)),
            (200, json(#"{"error":"authorization_pending"}"#)),
            (200, json(#"{"error":"slow_down"}"#)),
            (200, json(#"{"access_token":"gho_ok"}"#)),
        ]), clientID: "cid")

        let box = CodeBox()
        let token = try await flow.authorize(scope: "repo",
            onCode: { c in box.set(c) },
            sleep: { _ in })   // no real delay
        XCTAssertEqual(token, "gho_ok")
        XCTAssertEqual(box.value?.userCode, "AAAA-BBBB")
        XCTAssertEqual(box.value?.bestVerificationURL?.absoluteString,
                       "https://github.com/login/device?user_code=AAAA-BBBB")
    }

    func test_authorize_throws_on_denied() async throws {
        let flow = DeviceFlowAuth(transport: FakeTransport([
            (200, json(#"{"device_code":"DC","user_code":"X","verification_uri":"u","expires_in":900,"interval":1}"#)),
            (200, json(#"{"error":"access_denied"}"#)),
        ]), clientID: "cid")
        do {
            _ = try await flow.authorize(scope: "repo", onCode: { _ in }, sleep: { _ in })
            XCTFail("expected denied")
        } catch DeviceFlowAuth.DeviceFlowError.denied {
            // ok
        }
    }

    func test_currentUser_parses_login_and_node_id() async throws {
        let body = json(#"{"login":"octocat","node_id":"U_kgD","id":1}"#)
        let client = GitHubClient(transport: FakeTransport([(200, body)]), token: "t")
        let user = try await client.currentUser()
        XCTAssertEqual(user, GitHubUser(login: "octocat", nodeID: "U_kgD"))
    }

    func test_inMemoryTokenStore_save_read_delete() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.read())
        try store.save("gho_xyz")          // PAT-paste path stores the same way
        XCTAssertEqual(try store.read(), "gho_xyz")
        try store.delete()
        XCTAssertNil(try store.read())
    }
}
