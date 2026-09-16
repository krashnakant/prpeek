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

/// A single line in Unified / Inline diff presentation.
public struct UnifiedDiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
    public let text: String

    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
    }
}

/// One cell (left or right side) in a Side-by-Side diff presentation.
public struct SideBySideDiffCell: Sendable, Equatable {
    public let kind: DiffLineKind
    public let lineNumber: Int?
    public let text: String

    public static let empty = SideBySideDiffCell(kind: .context, lineNumber: nil, text: "")

    public init(kind: DiffLineKind, lineNumber: Int?, text: String) {
        self.kind = kind
        self.lineNumber = lineNumber
        self.text = text
    }
}

/// A paired row in Side-by-Side diff presentation.
public struct SideBySideDiffRow: Sendable, Equatable {
    public let isHunkHeader: Bool
    public let hunkHeaderText: String?
    public let left: SideBySideDiffCell
    public let right: SideBySideDiffCell

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

    /// Parse a unified diff patch string into lines for Inline display.
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
        return result
    }

    /// Parse a unified diff patch string into paired rows for Side-by-Side display.
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
                let left = i < pendingDeletions.count ? pendingDeletions[i] : .empty
                let right = i < pendingAdditions.count ? pendingAdditions[i] : .empty
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
