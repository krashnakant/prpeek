import Foundation

/// Status of a file in a pull request diff.
public enum FileStatus: String, Sendable, Equatable, Codable {
    case added
    case removed
    case modified
    case renamed
    case copied
    case changed
    case unchanged
    case unknown

    public init(fromRaw: String) {
        self = FileStatus(rawValue: fromRaw.lowercased()) ?? .unknown
    }

    public var displayLabel: String {
        switch self {
        case .added: return "ADDED"
        case .removed: return "DELETED"
        case .modified: return "MODIFIED"
        case .renamed: return "RENAMED"
        case .copied: return "COPIED"
        default: return rawValue.uppercased()
        }
    }

    public var symbol: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .renamed: return "arrow.2.squarepath"
        case .copied: return "doc.on.doc"
        default: return "doc.text"
        }
    }
}

/// A changed file in a Pull Request.
public struct PullRequestFile: Sendable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let previousFilename: String?
    public let status: FileStatus
    public let additions: Int
    public let deletions: Int
    public let changes: Int
    public let patch: String?
    public let blobURL: URL?
    public let rawURL: URL?

    public init(id: String, filename: String, previousFilename: String? = nil,
                status: FileStatus, additions: Int, deletions: Int, changes: Int,
                patch: String?, blobURL: URL? = nil, rawURL: URL? = nil) {
        self.id = id
        self.filename = filename
        self.previousFilename = previousFilename
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.changes = changes
        self.patch = patch
        self.blobURL = blobURL
        self.rawURL = rawURL
    }
}

// MARK: - Diff Parsing Models

public enum DiffLineKind: Sendable, Equatable {
    case hunkHeader
    case context
    case addition
    case deletion
    case comment
}

/// A sub-string token within a line, annotated with whether it represents an intra-line modification.
public struct DiffToken: Sendable, Equatable {
    public let text: String
    public let isChanged: Bool

    public init(text: String, isChanged: Bool) {
        self.text = text
        self.isChanged = isChanged
    }
}

/// A single line in Unified / Inline diff presentation.
public struct UnifiedDiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String
    public var tokens: [DiffToken]?

    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String, tokens: [DiffToken]? = nil) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
        self.tokens = tokens
    }
}

/// One cell (left or right side) in a Side-by-Side diff presentation.
public struct SideBySideDiffCell: Sendable, Equatable {
    public let kind: DiffLineKind
    public let lineNumber: Int?
    public let text: String
    public var tokens: [DiffToken]?

    public static let empty = SideBySideDiffCell(kind: .context, lineNumber: nil, text: "", tokens: nil)

    public init(kind: DiffLineKind, lineNumber: Int?, text: String, tokens: [DiffToken]? = nil) {
        self.kind = kind
        self.lineNumber = lineNumber
        self.text = text
        self.tokens = tokens
    }
}

/// A paired row in Side-by-Side diff presentation.
public struct SideBySideDiffRow: Sendable, Equatable {
    public let isHunkHeader: Bool
    public let hunkHeaderText: String?
    public var left: SideBySideDiffCell
    public var right: SideBySideDiffCell

    public init(isHunkHeader: Bool, hunkHeaderText: String?, left: SideBySideDiffCell, right: SideBySideDiffCell) {
        self.isHunkHeader = isHunkHeader
        self.hunkHeaderText = hunkHeaderText
        self.left = left
        self.right = right
    }
}

// MARK: - Diff Parser

public enum DiffParser {
    public static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        guard let secondRange = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) else {
            return nil
        }
        let inner = line[line.index(line.startIndex, offsetBy: 2)..<secondRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let parts = inner.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return nil }

        var oldStart = 1, oldCount = 1
        var newStart = 1, newCount = 1

        for part in parts {
            if part.hasPrefix("-") {
                let nums = part.dropFirst().split(separator: ",")
                if let s = nums.first.flatMap({ Int($0) }) { oldStart = s }
                if nums.count > 1, let c = Int(nums[1]) { oldCount = c }
            } else if part.hasPrefix("+") {
                let nums = part.dropFirst().split(separator: ",")
                if let s = nums.first.flatMap({ Int($0) }) { newStart = s }
                if nums.count > 1, let c = Int(nums[1]) { newCount = c }
            }
        }
        return (oldStart, oldCount, newStart, newCount)
    }

    /// Split a line into code tokens (words/numbers, whitespace, punctuation) for fine-grained delta highlighting.
    public static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        enum CharKind { case word, space, symbol }
        var currentKind: CharKind?

        for scalar in text.unicodeScalars {
            let kind: CharKind
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                kind = .word
            } else if CharacterSet.whitespaces.contains(scalar) {
                kind = .space
            } else {
                kind = .symbol
            }

            if let ck = currentKind, (ck != kind || kind == .symbol) {
                if !current.isEmpty { tokens.append(current) }
                current = String(scalar)
            } else {
                current.append(String(scalar))
            }
            currentKind = kind
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Compute intra-line token difference via Longest Common Subsequence (LCS).
    public static func computeWordDelta(oldText: String, newText: String) -> (oldTokens: [DiffToken], newTokens: [DiffToken]) {
        let a = tokenize(oldText)
        let b = tokenize(newText)
        let m = a.count
        let n = b.count

        if m == 0 {
            return ([], b.map { DiffToken(text: $0, isChanged: true) })
        }
        if n == 0 {
            return (a.map { DiffToken(text: $0, isChanged: true) }, [])
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if a[i] == b[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var commonA = Set<Int>()
        var commonB = Set<Int>()
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                commonA.insert(i - 1)
                commonB.insert(j - 1)
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        let oldTokens = a.indices.map { DiffToken(text: a[$0], isChanged: !commonA.contains($0)) }
        let newTokens = b.indices.map { DiffToken(text: b[$0], isChanged: !commonB.contains($0)) }
        return (oldTokens, newTokens)
    }

    /// Parse a unified diff patch string into lines for Inline display, with intra-line token highlighting.
    public static func parseUnified(patch: String?) -> [UnifiedDiffLine] {
        guard let patch, !patch.isEmpty else { return [] }
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var result: [UnifiedDiffLine] = []
        var currentOldLine = 1
        var currentNewLine = 1

        for line in lines {
            if line.hasPrefix("@@") {
                if let header = parseHunkHeader(line) {
                    currentOldLine = header.oldStart == 0 && header.oldCount == 0 ? 1 : header.oldStart
                    currentNewLine = header.newStart == 0 && header.newCount == 0 ? 1 : header.newStart
                }
                result.append(UnifiedDiffLine(kind: .hunkHeader, oldLineNumber: nil, newLineNumber: nil, text: line))
            } else if line.hasPrefix("+") {
                let text = String(line.dropFirst())
                result.append(UnifiedDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: currentNewLine, text: text))
                currentNewLine += 1
            } else if line.hasPrefix("-") {
                let text = String(line.dropFirst())
                result.append(UnifiedDiffLine(kind: .deletion, oldLineNumber: currentOldLine, newLineNumber: nil, text: text))
                currentOldLine += 1
            } else if line.hasPrefix("\\") {
                result.append(UnifiedDiffLine(kind: .comment, oldLineNumber: nil, newLineNumber: nil, text: line))
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                result.append(UnifiedDiffLine(kind: .context, oldLineNumber: currentOldLine, newLineNumber: currentNewLine, text: text))
                currentOldLine += 1
                currentNewLine += 1
            }
        }

        // Intra-line pairing pass for inline diffs:
        // When a deletion is immediately followed by an addition (or pairs within contiguous change blocks)
        var idx = 0
        while idx < result.count {
            if result[idx].kind == .deletion {
                let delStart = idx
                while idx < result.count && result[idx].kind == .deletion { idx += 1 }
                let delEnd = idx
                let addStart = idx
                while idx < result.count && result[idx].kind == .addition { idx += 1 }
                let addEnd = idx

                let delCount = delEnd - delStart
                let addCount = addEnd - addStart
                let pairs = min(delCount, addCount)
                for p in 0..<pairs {
                    let dIdx = delStart + p
                    let aIdx = addStart + p
                    let delta = computeWordDelta(oldText: result[dIdx].text, newText: result[aIdx].text)
                    result[dIdx].tokens = delta.oldTokens
                    result[aIdx].tokens = delta.newTokens
                }
            } else {
                idx += 1
            }
        }

        return result
    }

    /// Parse a unified diff patch string into paired rows for Side-by-Side display, with intra-line token highlighting.
    public static func parseSideBySide(patch: String?) -> [SideBySideDiffRow] {
        guard let patch, !patch.isEmpty else { return [] }
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var result: [SideBySideDiffRow] = []
        var currentOldLine = 1
        var currentNewLine = 1

        var pendingDeletions: [SideBySideDiffCell] = []
        var pendingAdditions: [SideBySideDiffCell] = []

        func flushPending() {
            guard !pendingDeletions.isEmpty || !pendingAdditions.isEmpty else { return }
            let maxCount = max(pendingDeletions.count, pendingAdditions.count)
            for i in 0..<maxCount {
                var left = i < pendingDeletions.count ? pendingDeletions[i] : .empty
                var right = i < pendingAdditions.count ? pendingAdditions[i] : .empty

                if left.kind == .deletion && right.kind == .addition {
                    let delta = computeWordDelta(oldText: left.text, newText: right.text)
                    left.tokens = delta.oldTokens
                    right.tokens = delta.newTokens
                }

                result.append(SideBySideDiffRow(isHunkHeader: false, hunkHeaderText: nil, left: left, right: right))
            }
            pendingDeletions.removeAll()
            pendingAdditions.removeAll()
        }

        for line in lines {
            if line.hasPrefix("@@") {
                flushPending()
                if let header = parseHunkHeader(line) {
                    currentOldLine = header.oldStart == 0 && header.oldCount == 0 ? 1 : header.oldStart
                    currentNewLine = header.newStart == 0 && header.newCount == 0 ? 1 : header.newStart
                }
                result.append(SideBySideDiffRow(isHunkHeader: true, hunkHeaderText: line, left: .empty, right: .empty))
            } else if line.hasPrefix("-") {
                if !pendingAdditions.isEmpty { flushPending() }
                let text = String(line.dropFirst())
                pendingDeletions.append(SideBySideDiffCell(kind: .deletion, lineNumber: currentOldLine, text: text))
                currentOldLine += 1
            } else if line.hasPrefix("+") {
                let text = String(line.dropFirst())
                pendingAdditions.append(SideBySideDiffCell(kind: .addition, lineNumber: currentNewLine, text: text))
                currentNewLine += 1
            } else if line.hasPrefix("\\") {
                flushPending()
                result.append(SideBySideDiffRow(isHunkHeader: false, hunkHeaderText: nil,
                                                left: SideBySideDiffCell(kind: .comment, lineNumber: nil, text: line),
                                                right: SideBySideDiffCell(kind: .comment, lineNumber: nil, text: line)))
            } else {
                flushPending()
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                result.append(SideBySideDiffRow(
                    isHunkHeader: false, hunkHeaderText: nil,
                    left: SideBySideDiffCell(kind: .context, lineNumber: currentOldLine, text: text),
                    right: SideBySideDiffCell(kind: .context, lineNumber: currentNewLine, text: text)
                ))
                currentOldLine += 1
                currentNewLine += 1
            }
        }
        flushPending()
        return result
    }
}

// MARK: - Wire DTOs & Client Extension

struct PullRequestFileDTO: Decodable, Sendable {
    let sha: String?
    let filename: String
    let status: String
    let additions: Int
    let deletions: Int
    let changes: Int
    let patch: String?
    let blobURL: URL?
    let rawURL: URL?
    let previousFilename: String?

    enum CodingKeys: String, CodingKey {
        case sha, filename, status, additions, deletions, changes, patch
        case blobURL = "blob_url"
        case rawURL = "raw_url"
        case previousFilename = "previous_filename"
    }

    var toFile: PullRequestFile {
        PullRequestFile(
            id: sha ?? filename,
            filename: filename,
            previousFilename: previousFilename,
            status: FileStatus(fromRaw: status),
            additions: additions,
            deletions: deletions,
            changes: changes,
            patch: patch,
            blobURL: blobURL,
            rawURL: rawURL
        )
    }
}

public extension GitHubClient {
    /// Fetch the list of changed files for a pull request, with additions, deletions,
    /// and git diff patch per file.
    func pullRequestFiles(owner: String, repo: String, number: Int) async throws -> [PullRequestFile] {
        let dtos: [PullRequestFileDTO] = try await getCollection(path: "/repos/\(owner)/\(repo)/pulls/\(number)/files")
        return dtos.map(\.toFile)
    }
}
