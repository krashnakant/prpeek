import Foundation

/// Atomic JSON persistence for `PRPeekState`.
/// Contract: `load()` NEVER throws — a missing, corrupt, or wrong-schema file
/// recovers to `.empty` (and stashes the bad file as `.corrupt` for forensics).
/// Even a solo app corrupts its own cache during iteration; recovery is the rule.
public struct JSONStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// ~/Library/Application Support/PRPeek/state.json
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "PRPeek/state.json")
    }

    public func load() -> PRPeekState {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            let state = try JSONDecoder.github.decode(PRPeekState.self, from: data)
            // Older caches are migrated by the caller (`PRPeekState.migrate`), which
            // keys off `schemaVersion`. A NEWER one was written by a build we don't
            // understand — that's the only unrecoverable case.
            guard state.schemaVersion <= PRPeekState.currentSchema else {
                quarantine(reason: "schema \(state.schemaVersion)")
                return .empty
            }
            return state
        } catch {
            quarantine(reason: "decode")
            return .empty
        }
    }

    public func save(_ state: PRPeekState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic) // atomic = no half-written file on crash
    }

    private func quarantine(reason: String) {
        let bad = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
    }
}
