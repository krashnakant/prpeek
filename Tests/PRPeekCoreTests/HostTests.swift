import XCTest
@testable import PRPeekCore

final class HostTests: XCTestCase {
    func test_blank_and_dotcom_use_public_api() {
        for h in ["", "  ", "github.com", "api.github.com", "GitHub.com"] {
            XCTAssertEqual(GitHubClient.apiBase(forHost: h), GitHubClient.dotComBase, "host: \(h)")
            XCTAssertEqual(GitHubClient.webBase(forHost: h).absoluteString, "https://github.com")
        }
    }

    func test_ghes_host_maps_to_api_v3_and_web_host() {
        XCTAssertEqual(GitHubClient.apiBase(forHost: "github.acme.com").absoluteString,
                       "https://github.acme.com/api/v3")
        XCTAssertEqual(GitHubClient.webBase(forHost: "github.acme.com").absoluteString,
                       "https://github.acme.com")
        // case + whitespace normalized
        XCTAssertEqual(GitHubClient.apiBase(forHost: "  GitHub.ACME.com ").absoluteString,
                       "https://github.acme.com/api/v3")
    }
}
