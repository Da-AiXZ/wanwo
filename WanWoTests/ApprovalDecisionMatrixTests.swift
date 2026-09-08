//
//  ApprovalDecisionMatrixTests.swift
//  WanWoTests
//
//  【M3 T1 单测 2/5】判定骨架：效果分类静态表 + workspace-write 最简矩阵 +
//  三值取最严 + 规则行优先。
//  出处：m3-scope-brief §二.3；06-codex-gap1 §3.1/§七.2/§八.1-2（三值判定、
//  取最严、pre-execute 缝承载判定入口）。
//

import XCTest
@testable import WanWo

final class ApprovalDecisionMatrixTests: XCTestCase {

    // MARK: 效果分类静态表

    func testEffectClassification() {
        XCTAssertEqual(ToolEffectTable.classify("read"), .readOnly)
        XCTAssertEqual(ToolEffectTable.classify("glob"), .readOnly)
        XCTAssertEqual(ToolEffectTable.classify("grep"), .readOnly)
        XCTAssertEqual(ToolEffectTable.classify("web_search"), .readOnly)
        XCTAssertEqual(ToolEffectTable.classify("write"), .workspaceWrite)
        XCTAssertEqual(ToolEffectTable.classify("edit"), .workspaceWrite)
        XCTAssertEqual(ToolEffectTable.classify("bash"), .arbitrary)
        XCTAssertEqual(ToolEffectTable.classify("ask_user_question"), .interaction)
        // fail closed：未分类工具一律 arbitrary（绝不默认放行）。
        XCTAssertEqual(ToolEffectTable.classify("unknown_tool"), .arbitrary)
    }

    // MARK: workspace-write 最简矩阵

    func testWorkspaceWriteMatrix() {
        let matrix = ApprovalDecisionMatrix(sandboxMode: .workspaceWrite)
        // 只读与工作区写放行（T1 无沙箱强制，工作区写即缺省档语义）。
        XCTAssertEqual(matrix.decide(tool: "read", args: .null), .allow)
        XCTAssertEqual(matrix.decide(tool: "write", args: .null), .allow)
        // bash（任意效果）一律审批。
        XCTAssertEqual(matrix.decide(tool: "bash", args: .object(["command": .string("ls")])), .prompt)
        // 未分类工具 fail closed → prompt。
        XCTAssertEqual(matrix.decide(tool: "mystery", args: .null), .prompt)
        // 交互工具不得再触发审批（自锁死锁）。
        XCTAssertEqual(matrix.decide(tool: "ask_user_question", args: .null), .allow)
    }

    func testReadOnlyMatrix() {
        let matrix = ApprovalDecisionMatrix(sandboxMode: .readOnly)
        XCTAssertEqual(matrix.decide(tool: "read", args: .null), .allow)
        XCTAssertEqual(matrix.decide(tool: "write", args: .null), .prompt)
        XCTAssertEqual(matrix.decide(tool: "bash", args: .null), .prompt)
    }

    func testDangerFullAccessMatrix() {
        let matrix = ApprovalDecisionMatrix(sandboxMode: .dangerFullAccess)
        XCTAssertEqual(matrix.decide(tool: "bash", args: .null), .allow)
        XCTAssertEqual(matrix.decide(tool: "write", args: .null), .allow)
    }

    // MARK: 规则行（T2 规则引擎的接管面；T1 验证叠加/取最严骨架）

    func testRowsTakeStrictest() {
        let matrix = ApprovalDecisionMatrix(
            sandboxMode: .workspaceWrite,
            rows: [
                .init(matches: { tool, _ in tool == "bash" }, verdict: .allow, reason: nil),
                .init(matches: { tool, args in
                    tool == "bash"
                        && (args.field("command")?.stringValue ?? "").hasPrefix("rm ")
                }, verdict: .forbidden, reason: "请用更安全的方式删除文件"),
            ])
        // 多条命中取最严（allow < forbidden）。
        XCTAssertEqual(matrix.decide(tool: "bash", args: .object(["command": .string("rm -rf /")])),
                       .forbidden)
        XCTAssertEqual(matrix.decide(tool: "bash", args: .object(["command": .string("ls")])),
                       .allow)
        // 未命中行回落静态矩阵（bash → prompt）。
        XCTAssertEqual(matrix.decide(tool: "bash", args: .object(["command": .string("echo hi")])),
                       .prompt)
    }

    // MARK: 取最严算子

    func testStrictestOperator() {
        XCTAssertEqual(ApprovalDecisionVerdict.strictest(.allow, .prompt), .prompt)
        XCTAssertEqual(ApprovalDecisionVerdict.strictest(.prompt, .forbidden), .forbidden)
        XCTAssertEqual(ApprovalDecisionVerdict.strictest(.allow, .forbidden), .forbidden)
        XCTAssertEqual(ApprovalDecisionVerdict.strictest(.allow, .allow), .allow)
    }
}
