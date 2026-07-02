import PRPeekCore

/// Per-PR lazy cache: fetch a value for a PR once, cache it, dedup in-flight
/// loads, and discard a result whose session epoch moved (account switch).
/// One mechanism for both review comments and commits — the single-flight,
/// nil-vs-empty sentinel, and epoch-discard logic live here, not twice.
@MainActor
final class PerPRLazyCache<Value> {
    private var values: [String: Value] = [:]
    private var loading: Set<String> = []
    /// nil from fetch = failure — NOT cached, so the next `load` retries.
    private let fetch: @Sendable (_ owner: String, _ repo: String, _ number: Int) async -> Value?

    init(fetch: @escaping @Sendable (String, String, Int) async -> Value?) { self.fetch = fetch }

    /// nil = not loaded yet; non-nil = loaded (may be empty).
    func value(for pr: PullRequest) -> Value? { values[pr.id] }
    func isLoading(_ pr: PullRequest) -> Bool { loading.contains(pr.id) }
    func reset() { values.removeAll(); loading.removeAll() }

    /// Load once. `epoch` is snapshot now and re-read after the fetch; if it moved
    /// (account switch) the result is dropped. `onReload` fires on a kept result.
    func load(_ pr: PullRequest, epoch: @escaping @autoclosure () -> Int,
              onReload: @escaping (String) -> Void) {
        guard values[pr.id] == nil, !loading.contains(pr.id) else { return }
        loading.insert(pr.id)
        let id = pr.id, (owner, repo) = pr.ownerRepo, number = pr.number, started = epoch()
        Task { [weak self] in
            guard let self else { return }
            let v = await self.fetch(owner, repo, number)
            // Account switched mid-flight: reset() already cleared `loading`; don't
            // touch it here or we'd break a new same-id load's in-flight dedup.
            guard started == epoch() else { return }
            self.loading.remove(id)
            guard let v else { onReload(id); return }   // fetch failed: no cache, retry next open
            self.values[id] = v
            onReload(id)
        }
    }
}
