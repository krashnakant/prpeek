import XCTest
@testable import PRPeekCore

final class JSONStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "prpeek-test-\(UUID().uuidString)/state.json")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    }

    private func samplePR() -> PullRequest {
        PullRequest(id: "NODE1", number: 42, repoFullName: "me/repo", title: "Fix it",
                    htmlURL: URL(string: "https://github.com/me/repo/pull/42")!,
                    isDraft: false, author: "me", headSHA: "deadbeef",
                    ciState: .passing, waitingOnMe: true, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func test_missing_file_loads_empty() {
        let store = JSONStore(url: tmp)
        XCTAssertEqual(store.load(), .empty)
    }

    func test_roundtrip() throws {
        let store = JSONStore(url: tmp)
        var state = PRPeekState(filters: ["me/repo"], pullRequests: [samplePR()],
                                lastUpdated: Date(timeIntervalSince1970: 1_700_000_500))
        try store.save(state)
        let loaded = store.load()
        XCTAssertEqual(loaded, state)
        // mutate + save again (overwrite path)
        state.filters = []
        try store.save(state)
        XCTAssertEqual(store.load().filters, [])
    }

    func test_corrupt_file_recovers_to_empty_and_quarantines() throws {
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: tmp)
        let store = JSONStore(url: tmp)
        XCTAssertEqual(store.load(), .empty, "corrupt file must not crash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathExtension("corrupt").path),
                      "bad file should be quarantined")
    }

    func test_schema_mismatch_recovers_to_empty() throws {
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // valid JSON, wrong schemaVersion
        try Data(#"{"schemaVersion":999,"filters":[],"pullRequests":[]}"#.utf8).write(to: tmp)
        let store = JSONStore(url: tmp)
        XCTAssertEqual(store.load(), .empty, "future schema must recover, not crash")
    }
}
