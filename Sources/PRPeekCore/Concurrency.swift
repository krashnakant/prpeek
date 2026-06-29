import Foundation

/// Order-preserving concurrent map with a hard in-flight cap. The cap is what
/// keeps the per-PR check-runs fan-out from tripping GitHub's secondary/burst
/// limit (plan: concurrency cap ≤4-6).
func mapConcurrent<T: Sendable, R: Sendable>(
    _ items: [T], limit: Int,
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    guard !items.isEmpty else { return [] }
    let lim = max(1, limit)
    return try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for i in 0..<min(lim, items.count) {
            let item = items[i]
            group.addTask { (i, try await transform(item)) }
            next = i + 1
        }
        while let (idx, value) = try await group.next() {
            results[idx] = value
            if next < items.count {
                let i = next, item = items[i]
                group.addTask { (i, try await transform(item)) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}
