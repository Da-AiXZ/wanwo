//
//  GitDiffParserTests.swift
//  WanWoTests
//
//  【M6.6（B4）测试 · 审查 diff 解析（骨架级纯逻辑面）】
//  覆盖：unified diff → DiffFile（路径剥离 a/ b/、+/− 计数、hunk 结构、
//  no-newline 标记跳过、多文件）+ 折叠块（foldedLines——≥阈值 context 连块、
//  短 context 不折）。
//

import XCTest
@testable import WanWo

final class GitDiffParserTests: XCTestCase {

    private let sample = """
    diff --git a/src/main.swift b/src/main.swift
    index 1111111..2222222 100644
    --- a/src/main.swift
    +++ b/src/main.swift
    @@ -1,6 +1,7 @@ context header
     unchanged line
    -removed line
    +added line
    +added line 2
    \\ No newline at end of file
    diff --git a/docs/readme.md b/docs/readme.md
    index 3333333..4444444 100644
    --- a/docs/readme.md
    +++ b/docs/readme.md
    @@ -1,3 +1,4 @@
    -old text
    +new text
    """

    // MARK: - parse

    func testParsesTwoFilesWithStrippedPaths() {
        let files = GitDiffParser.parse(sample)
        XCTAssertEqual(files.map(\.path), ["src/main.swift", "docs/readme.md"])
    }

    func testCountsAddedRemovedPerFile() {
        let files = GitDiffParser.parse(sample)
        XCTAssertEqual(files[0].addedCount, 2)
        XCTAssertEqual(files[0].removedCount, 1)
        XCTAssertEqual(files[1].addedCount, 1)
        XCTAssertEqual(files[1].removedCount, 1)
    }

    func testHunksCarryHeaderAndLineKinds() {
        let files = GitDiffParser.parse(sample)
        XCTAssertEqual(files[0].hunks.count, 1)
        let hunk = files[0].hunks[0]
        XCTAssertTrue(hunk.header.hasPrefix("@@"))
        XCTAssertEqual(hunk.lines.first?.kind, .context)
        XCTAssertEqual(hunk.lines.first?.text, "unchanged line")
        XCTAssertEqual(hunk.lines[1].kind, .removed)
        XCTAssertEqual(hunk.lines[2].kind, .added)
        // "\ No newline" 标记不进行集。
        XCTAssertFalse(hunk.lines.contains { $0.text.contains("No newline") })
    }

    func testEmptyDiffYieldsNoFiles() {
        XCTAssertTrue(GitDiffParser.parse("").isEmpty)
        // 仅头部无 hunk（纯 mode 变更形态）→ 记 0/0 条目（与 rename 呈现同口径）。
        let files = GitDiffParser.parse("diff --git a/x b/x\nindex 1..2 100644\n")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].addedCount, 0)
        XCTAssertEqual(files[0].removedCount, 0)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testRenameHeaderPresentsNewPath() {
        let text = """
        diff --git a/old-name.md b/new-name.md
        similarity index 90%
        rename from old-name.md
        rename to new-name.md
        """
        let files = GitDiffParser.parse(text)
        XCTAssertEqual(files.map(\.path), ["new-name.md"])
    }

    // MARK: - 折叠（§6.5 未修改行折叠）

    func testLongContextRunsFoldIntoBlocks() {
        let lines = (1...6).map { _ in DiffLine(kind: .context, text: "c") }
        let folded = GitDiffParser.foldedLines(lines, foldThreshold: 4)
        XCTAssertEqual(folded.count, 1)
        if case .fold(let count) = folded[0].kind {
            XCTAssertEqual(count, 6)
        } else {
            XCTFail("应为折叠块")
        }
    }

    func testShortContextRunsStayVisible() {
        let lines = (1...3).map { _ in DiffLine(kind: .context, text: "c") }
        let folded = GitDiffParser.foldedLines(lines, foldThreshold: 4)
        XCTAssertEqual(folded.count, 3)
        XCTAssertTrue(folded.allSatisfy {
            if case .visible = $0.kind { return true } else { return false }
        })
    }

    func testChangesSplitContextRuns() {
        var lines = (1...5).map { _ in DiffLine(kind: .context, text: "c") }
        lines.append(DiffLine(kind: .added, text: "change"))
        lines += (1...5).map { _ in DiffLine(kind: .context, text: "c") }
        let folded = GitDiffParser.foldedLines(lines, foldThreshold: 4)
        // 5+5 context → 两折叠块 + 1 变更行。
        XCTAssertEqual(folded.count, 3)
        guard case .fold(let first) = folded[0].kind,
              case .visible = folded[1].kind,
              case .fold(let second) = folded[2].kind else {
            XCTFail("折叠结构不符")
            return
        }
        XCTAssertEqual(first, 5)
        XCTAssertEqual(second, 5)
    }
}
