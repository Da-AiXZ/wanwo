//
//  ApprovalOutcomeTests.swift
//  WanWoTests
//
//  【M3 T1 单测 1/5】四值闭集 + rogue 归一化。
//  出处：dsh user-approval types.ts:32（闭集）、index.ts:48/279（OUTCOMES 全集
//  运行时归一化——rogue 返回值归 'unavailable'，绝不泄漏进闭集 switch）。
//

import XCTest
@testable import WanWo

final class ApprovalOutcomeTests: XCTestCase {

    /// 四值闭集字面值与 dsh wire 名 1:1。
    func testClosedVocabularyRawValues() {
        XCTAssertEqual(ApprovalOutcome.allowedOnce.rawValue, "allowed-once")
        XCTAssertEqual(ApprovalOutcome.rejected.rawValue, "rejected")
        XCTAssertEqual(ApprovalOutcome.cancelled.rawValue, "cancelled")
        XCTAssertEqual(ApprovalOutcome.unavailable.rawValue, "unavailable")
        XCTAssertEqual(ApprovalOutcome.all.count, 4)
    }

    /// rogue（非词汇）字符串归一为 fail-closed 的 unavailable。
    func testRogueNormalization() {
        XCTAssertEqual(ApprovalOutcome.normalizing("allowed-once"), .allowedOnce)
        XCTAssertEqual(ApprovalOutcome.normalizing("nonsense"), .unavailable)
        XCTAssertEqual(ApprovalOutcome.normalizing(""), .unavailable)
        XCTAssertEqual(ApprovalOutcome.normalizing("allow"), .unavailable)      // M2 旧值
        XCTAssertEqual(ApprovalOutcome.normalizing("deny"), .unavailable)       // M2 旧值
        XCTAssertEqual(ApprovalOutcome.normalizing("ALLOWED-ONCE"), .unavailable) // 大小写敏感
    }

    /// Codable 往返（审计事件 verdict 字段值 round-trip）。
    func testCodableRoundTrip() throws {
        for outcome in ApprovalOutcome.all {
            let data = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(ApprovalOutcome.self, from: data)
            XCTAssertEqual(decoded, outcome)
        }
    }

    /// ApprovalPolicy 闭集（dsh index.ts:60/63）。
    func testApprovalPolicyVocabulary() {
        XCTAssertEqual(ApprovalPolicy.all, [.ask, .never])
        XCTAssertEqual(ApprovalPolicy.ask.rawValue, "ask")
        XCTAssertEqual(ApprovalPolicy.never.rawValue, "never")
    }
}
