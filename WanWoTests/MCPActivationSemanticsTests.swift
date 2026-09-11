//
//  MCPActivationSemanticsTests.swift
//  WanWoTests
//
//  【M4-B 场景2 根因修复 · commit 2 测试锚】吞错场景必记 ✗ 而非 ✓——
//  "activate() 未抛出"（failOnStartupError=false 默认，MCPConfig.swift:208，
//  dsh index.ts:69-70 语义 1:1）≠ "initialize 成功"。真机实证：诊断日志
//  "activation succeeded" 与 exit 512 crash-loop 交错（3 次栈构建的首尝试
//  settle 行——终判=候选 2 写入语义，lead 采信），设置页"上次激活 ✓ 2:38"
//  误导用户以为激活成功过。本锚锁 MCPRuntime 激活记录判定语义：
//  outcome.error 非 nil = 失败。
//  纪律：不真 spawn/不真连（竞态类确定性——MCPServerStoreTests 头注同款），
//  判定面以纯函数锚定，端到端行为由真机最终验收覆盖。
//

import XCTest
@testable import WanWo

final class MCPActivationSemanticsTests: XCTestCase {

    /// 吞错场景（outcome 携带首次尝试错误）→ 必记失败（✗）。
    func testSwallowedStartupErrorRecordsFailure() {
        let outcome = MCPConnectionOutcome(error: MCPConfigurationError(
            "mcp-client(echo): initial connection or tool synchronization failed"))
        XCTAssertFalse(MCPRuntime.activationSucceeded(outcome),
                       "swallowed startup error must record ✗, not ✓")
    }

    /// 真连通（首次 connect+初始同步成功，error=nil）→ 记成功（✓）。
    func testConnectedOutcomeRecordsSuccess() {
        XCTAssertTrue(MCPRuntime.activationSucceeded(MCPConnectionOutcome(error: nil)),
                      "successful initial connection must record ✓")
    }
}
