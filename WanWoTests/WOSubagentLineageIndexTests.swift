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
    /// 【dsh 环语义裁决（subagent-lineage.ts :24-45 逐行推演，禁拍脑袋）】：
    /// 环上节点会计入自己祖先桶——后代 a 先给父 b +1、上溯到 b 再给 a +1；
    /// 后代 b 对称地给 a、b 各 +1 → 真实输出 {a:2, b:2}（环上每个节点被
    /// 自己与对方各计一次；各后代独立 seen 集，第二次命中自己即断环）。
    /// 初版期望 {a:1, b:1} 系测试侧误判，实现与 dsh 1:1 不动（报告
    /// §复审修·P1-1 后新增节有完整推演）。
    func testCycleGuardTerminates() {
        let map = WOSubagentLineageIndex.index([
            entry("a", parent: "b"),
            entry("b", parent: "a"),
        ])
        XCTAssertEqual(map["a"]?.count, 2, "dsh 环语义：a 桶 = a、b 两后代各上溯计入")
        XCTAssertEqual(map["b"]?.count, 2, "dsh 环语义：b 桶 = a、b 两后代各上溯计入")
        XCTAssertEqual(map["a"]?.runningCount, 0)
        XCTAssertEqual(map["b"]?.runningCount, 0)
        XCTAssertEqual(map.count, 2, "断环有界：只为环上两父建桶，不死循环")
    }

    /// 空输入 = 空索引。
    func testEmptyInput() {
        XCTAssertTrue(WOSubagentLineageIndex.index([]).isEmpty)
    }
}
