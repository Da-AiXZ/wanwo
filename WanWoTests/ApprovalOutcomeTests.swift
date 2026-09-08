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
        XCTAssertEqual(ApprovalOutcome.normalizing("ALLOWED-ONCE"), .unavailable) // 大小写敏感
    }

    /// E1 legacy 台账兼容（v2.4 备忘答复，已批）：M2 期 verdict 双值
    /// "allow"/"deny" 重放映射——allow→allowed-once、deny→rejected。
    func testLegacyM2VerdictMapping() {
        XCTAssertEqual(ApprovalOutcome.normalizing("allow"), .allowedOnce)
        XCTAssertEqual(ApprovalOutcome.normalizing("deny"), .rejected)
        // 与 M2 旧值仅差大小写的串不享受映射（严格字面匹配）。
        XCTAssertEqual(ApprovalOutcome.normalizing("ALLOW"), .unavailable)
        XCTAssertEqual(ApprovalOutcome.normalizing("Deny"), .unavailable)
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
