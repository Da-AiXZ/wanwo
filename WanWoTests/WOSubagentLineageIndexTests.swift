//
//  WOSubagentLineageIndexTests.swift
//  WanWoTests
//
//  【M7-Fix2 批2 B1】后代索引纯函数例（dsh subagent-lineage.ts
//  indexSubagentDescendants 语义 1:1 折算的对拍面）：
//  直接子聚合 / 链上溯逐祖先聚合 / running 计数 / 断环 / 非 subagent
//  跳过 / 父缺失即停。
//

import XCTest
@testable import WanWo

final class WOSubagentLineageIndexTests: XCTestCase {

    // MARK: - fixture

    private func entry(_ id: String, parent: String?, running: Bool = false)
        -> WOSubagentLineageIndex.Entry {
        WOSubagentLineageIndex.Entry(id: id, parentID: parent, running: running)
    }

    // MARK: - 聚合语义

    /// 直接子：count=1 聚合到父。
    func testDirectChildAggregatesToParent() {
        let map = WOSubagentLineageIndex.index([entry("child", parent: "root")])
        XCTAssertEqual(map["root"]?.count, 1)
        XCTAssertEqual(map["root"]?.runningCount, 0)
    }

    /// 链上溯：孙代沿父链逐祖先 +1（root→mid→leaf：root=2、mid=1）。
    func testGrandchildAggregatesToWholeAncestorChain() {
        let map = WOSubagentLineageIndex.index([
            entry("mid", parent: "root"),
            entry("leaf", parent: "mid"),
        ])
        XCTAssertEqual(map["root"]?.count, 2, "不间断后代链逐祖先聚合")
        XCTAssertEqual(map["mid"]?.count, 1)
        XCTAssertNil(map["leaf"], "叶自身无后代")
    }

    /// running 后代逐祖先 +1 runningCount。
    func testRunningCountTracksRunningDescendants() {
        let map = WOSubagentLineageIndex.index([
            entry("mid", parent: "root", running: false),
            entry("leaf1", parent: "mid", running: true),
            entry("leaf2", parent: "mid", running: true),
        ])
        XCTAssertEqual(map["root"]?.count, 3)
        XCTAssertEqual(map["root"]?.runningCount, 2)
        XCTAssertEqual(map["mid"]?.count, 2)
        XCTAssertEqual(map["mid"]?.runningCount, 2)
    }

    /// 非 subagent-origin（parentID=nil，dsh origin!=='subagent'）不入索引。
    func testNonSubagentEntryIgnored() {
        let map = WOSubagentLineageIndex.index([entry("normal", parent: nil)])
        XCTAssertTrue(map.isEmpty)
    }

    /// 父不在集合（非 subagent-origin 父，dsh summaries[parentId] undefined）
    /// 即停——只为该父记一条，不再上溯。
    func testMissingParentStops() {
        let map = WOSubagentLineageIndex.index([entry("child", parent: "ghost")])
        XCTAssertEqual(map["ghost"]?.count, 1)
        XCTAssertEqual(map.count, 1, "ghost 不在集合，上溯即停")
    }

    /// 环（a→b→a）：seen 集断环，不死循环、计数有界。
    func testCycleGuardTerminates() {
        let map = WOSubagentLineageIndex.index([
            entry("a", parent: "b"),
            entry("b", parent: "a"),
        ])
        XCTAssertEqual(map["b"]?.count, 1)
        XCTAssertEqual(map["a"]?.count, 1)
    }

    /// 空输入 = 空索引。
    func testEmptyInput() {
        XCTAssertTrue(WOSubagentLineageIndex.index([]).isEmpty)
    }
}
