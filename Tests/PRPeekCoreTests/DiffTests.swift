import XCTest
@testable import PRPeekCore

final class DiffTests: XCTestCase {
    func test_parse_hunk_header() {
        let h1 = DiffParser.parseHunkHeader("@@ -10,6 +10,8 @@ func test()")
        XCTAssertEqual(h1?.oldStart, 10)
        XCTAssertEqual(h1?.oldCount, 6)
        XCTAssertEqual(h1?.newStart, 10)
        XCTAssertEqual(h1?.newCount, 8)

        let h2 = DiffParser.parseHunkHeader("@@ -42 +42 @@")
        XCTAssertEqual(h2?.oldStart, 42)
        XCTAssertEqual(h2?.oldCount, 1)
        XCTAssertEqual(h2?.newStart, 42)
        XCTAssertEqual(h2?.newCount, 1)

        let h3 = DiffParser.parseHunkHeader("@@ -0,0 +1,50 @@")
        XCTAssertEqual(h3?.oldStart, 0)
        XCTAssertEqual(h3?.oldCount, 0)
        XCTAssertEqual(h3?.newStart, 1)
        XCTAssertEqual(h3?.newCount, 50)
    }

    func test_parse_unified_diff() {
        let patch = """
        @@ -1,4 +1,5 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         print(a)
        \\ No newline at end of file
        """

        let lines = DiffParser.parseUnified(patch: patch)
        XCTAssertEqual(lines.count, 7)

        XCTAssertEqual(lines[0].kind, .hunkHeader)

        XCTAssertEqual(lines[1].kind, .context)
        XCTAssertEqual(lines[1].oldLineNumber, 1)
        XCTAssertEqual(lines[1].newLineNumber, 1)
        XCTAssertEqual(lines[1].text, "let a = 1")

        XCTAssertEqual(lines[2].kind, .deletion)
        XCTAssertEqual(lines[2].oldLineNumber, 2)
        XCTAssertNil(lines[2].newLineNumber)
        XCTAssertEqual(lines[2].text, "let b = 2")

        XCTAssertEqual(lines[3].kind, .addition)
        XCTAssertNil(lines[3].oldLineNumber)
        XCTAssertEqual(lines[3].newLineNumber, 2)
        XCTAssertEqual(lines[3].text, "let b = 3")

        XCTAssertEqual(lines[4].kind, .addition)
        XCTAssertNil(lines[4].oldLineNumber)
        XCTAssertEqual(lines[4].newLineNumber, 3)
        XCTAssertEqual(lines[4].text, "let c = 4")

        XCTAssertEqual(lines[5].kind, .context)
        XCTAssertEqual(lines[5].oldLineNumber, 3)
        XCTAssertEqual(lines[5].newLineNumber, 4)
        XCTAssertEqual(lines[5].text, "print(a)")

        XCTAssertEqual(lines[6].kind, .comment)
        XCTAssertNil(lines[6].oldLineNumber)
        XCTAssertNil(lines[6].newLineNumber)
    }

    func test_parse_side_by_side_diff() {
        let patch = """
        @@ -10,3 +10,4 @@
         header
        -oldOne
        -oldTwo
        +newOne
         footer
        """

        let rows = DiffParser.parseSideBySide(patch: patch)
        // 1 hunkHeader + 1 context ("header") + 2 paired lines + 1 context ("footer") = 5 rows
        XCTAssertEqual(rows.count, 5)

        XCTAssertTrue(rows[0].isHunkHeader)

        // Context "header"
        XCTAssertEqual(rows[1].left.kind, .context)
        XCTAssertEqual(rows[1].left.lineNumber, 10)
        XCTAssertEqual(rows[1].left.text, "header")
        XCTAssertEqual(rows[1].right.kind, .context)
        XCTAssertEqual(rows[1].right.lineNumber, 10)
        XCTAssertEqual(rows[1].right.text, "header")

        // First changed row: oldOne vs newOne
        XCTAssertEqual(rows[2].left.kind, .deletion)
        XCTAssertEqual(rows[2].left.lineNumber, 11)
        XCTAssertEqual(rows[2].left.text, "oldOne")
        XCTAssertEqual(rows[2].right.kind, .addition)
        XCTAssertEqual(rows[2].right.lineNumber, 11)
        XCTAssertEqual(rows[2].right.text, "newOne")

        // Second changed row: oldTwo vs empty
        XCTAssertEqual(rows[3].left.kind, .deletion)
        XCTAssertEqual(rows[3].left.lineNumber, 12)
        XCTAssertEqual(rows[3].left.text, "oldTwo")
        XCTAssertEqual(rows[3].right, .empty)

        // Context "footer"
        XCTAssertEqual(rows[4].left.kind, .context)
        XCTAssertEqual(rows[4].left.lineNumber, 13)
        XCTAssertEqual(rows[4].left.text, "footer")
        XCTAssertEqual(rows[4].right.kind, .context)
        XCTAssertEqual(rows[4].right.lineNumber, 12)
        XCTAssertEqual(rows[4].right.text, "footer")
    }

    func test_file_dto_decoding_and_mapping() throws {
        let json = """
        [
          {
            "sha": "abc1234",
            "filename": "Sources/App.swift",
            "status": "modified",
            "additions": 14,
            "deletions": 2,
            "changes": 16,
            "blob_url": "https://github.com/octo/repo/blob/head/Sources/App.swift",
            "raw_url": "https://github.com/octo/repo/raw/head/Sources/App.swift",
            "patch": "@@ -1,2 +1,3 @@\\n context\\n-old\\n+new\\n+another"
          }
        ]
        """.data(using: .utf8)!

        let dtos = try JSONDecoder().decode([PullRequestFileDTO].self, from: json)
        XCTAssertEqual(dtos.count, 1)

        let file = dtos[0].toFile
        XCTAssertEqual(file.id, "abc1234")
        XCTAssertEqual(file.filename, "Sources/App.swift")
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.status.displayLabel, "MODIFIED")
        XCTAssertEqual(file.additions, 14)
        XCTAssertEqual(file.deletions, 2)
        XCTAssertEqual(file.changes, 16)
        XCTAssertNotNil(file.patch)
    }
}
