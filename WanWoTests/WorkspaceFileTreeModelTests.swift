//
//  WorkspaceFileTreeModelTests.swift
//  WanWoTests
//
//  【M6.6（B4）测试 · 文件树纯逻辑（验收单测面：文件树过滤）】
//  覆盖：buildTree（嵌套构树、目录前序）、filterTree（命中保留祖先链、
//  无命中剪枝）、expandedAncestorPaths（筛选态自动展开链）、
//  flattenedVisible（目录折叠 + 展开语义）。
//

import XCTest
@testable import WanWo

final class WorkspaceFileTreeModelTests: XCTestCase {

    // MARK: - buildTree

    func testBuildTreeNestsAndOrdersDirectoriesFirst() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "zeta.md", "docs/b.md", "docs/a/c.md", "src/main.swift",
        ])
        // 目录前、名称序。
        XCTAssertEqual(tree.map(\.name), ["docs", "src", "zeta.md"])
        let docs = tree.first { $0.name == "docs" }
        XCTAssertEqual(docs?.children.map(\.name), ["a", "b.md"])
        XCTAssertEqual(docs?.children.first?.children.first?.name, "c.md")
        XCTAssertEqual(docs?.children.first?.children.first?.id, "docs/a/c.md")
    }

    func testBuildTreeTreatsDeepPathsAsDirectories() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: ["a/b/c.txt"])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "a")
        XCTAssertTrue(tree[0].isDirectory)
        XCTAssertTrue(tree[0].children[0].isDirectory)
        XCTAssertFalse(tree[0].children[0].children[0].isDirectory)
    }

    // MARK: - filterTree（验收面）

    func testFilterKeepsMatchedFilesWithAncestorChain() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "docs/readme.md", "docs/design/spec.md", "src/main.swift",
        ])
        let filtered = WorkspaceFileTreeModel.filterTree(tree, query: "spec")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].name, "docs")
        XCTAssertEqual(filtered[0].children.count, 1)
        XCTAssertEqual(filtered[0].children[0].name, "design")
        XCTAssertEqual(filtered[0].children[0].children.first?.name, "spec.md")
    }

    func testFilterPrunesEmptyDirectories() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "docs/a.md", "src/main.swift",
        ])
        let filtered = WorkspaceFileTreeModel.filterTree(tree, query: "a.md")
        XCTAssertEqual(filtered.map(\.name), ["docs"])
    }

    func testFilterKeepsWholeSubtreeWhenDirectoryMatches() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "proj/readme.md", "other/x.md",
        ])
        let filtered = WorkspaceFileTreeModel.filterTree(tree, query: "proj")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].children.count, 1)
    }

    func testFilterCaseInsensitive() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: ["README.md"])
        XCTAssertFalse(WorkspaceFileTreeModel.filterTree(tree, query: "readme").isEmpty)
    }

    func testExpandedAncestorPathsCoversMatchChain() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "docs/design/spec.md", "src/main.swift",
        ])
        let paths = WorkspaceFileTreeModel.expandedAncestorPaths(tree, query: "spec")
        XCTAssertEqual(paths, ["docs", "docs/design"])
    }

    // MARK: - flattenedVisible（折叠语义）

    func testFlattenedVisibleCollapsesByDefault() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "docs/a.md", "src/main.swift",
        ])
        let rows = WorkspaceFileTreeModel.flattenedVisible(tree, expanded: [])
        XCTAssertEqual(rows.map(\.node.name), ["docs", "src", "main.swift"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0])
    }

    func testFlattenedVisibleExpandsMarkedDirectories() {
        let tree = WorkspaceFileTreeModel.buildTree(relativePaths: [
            "docs/a.md", "docs/sub/b.md",
        ])
        let rows = WorkspaceFileTreeModel.flattenedVisible(
            tree, expanded: ["docs"])
        // 展开的 docs 子层深度 1（目录序在前：sub、a.md）；sub 未展开不渲染。
        XCTAssertEqual(rows.map(\.node.name), ["docs", "sub", "a.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1])
    }
}
