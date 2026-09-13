//
//  HookProtocolTests.swift
//  WanWoTests
//
//  【M4-E 批 E1 测试 · dsh hook-protocol 测试移植】出处：
//    packages/hooks/hook-protocol/tests/codec.spec.ts（25 用例）/ merge.spec.ts
//    （12 用例）/ matcher.spec.ts（9 用例）——vitest 断言→XCTAssert 同义映射，
//    用例名与 spec 一一对应可溯（对照全表见 E1 呈报④）。invariant/detached/
//    events spec 属 E3/E5 不移植。
//

import XCTest
@testable import WanWo

// MARK: - codec.spec.ts（parseHookOutput）

final class HookCodecTests: XCTestCase {

    /// spec:5-10
    func testExit0NoStdoutIsNeutralSuccess() {
        let out = HookCodec.parseHookOutput(exitCode: 0, stdout: "", stderr: "")
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertNil(out.decision)
        XCTAssertNil(out.continue)
    }

    /// spec:12-17
    func testExit2BlocksStderrBecomesDecisionAndReason() {
        let out = HookCodec.parseHookOutput(exitCode: 2, stdout: "",
                                            stderr: "this command is not allowed")
        XCTAssertEqual(out.decision, .block)
        XCTAssertEqual(out.reason, "this command is not allowed")
        XCTAssertEqual(out.stderr, "this command is not allowed")
    }

    /// spec:19-23
    func testExit2EmptyStderrBlocksWithoutReason() {
        let out = HookCodec.parseHookOutput(exitCode: 2, stdout: "", stderr: "   ")
        XCTAssertEqual(out.decision, .block)
        XCTAssertNil(out.reason)
    }

    /// spec:25-30
    func testOtherNonZeroExitIsNonBlockingError() {
        let out = HookCodec.parseHookOutput(exitCode: 1, stdout: "", stderr: "some warning")
        XCTAssertNil(out.decision)
        XCTAssertEqual(out.exitCode, 1)
        XCTAssertEqual(out.stderr, "some warning")
    }

    /// spec:32-37
    func testUndefinedExitCarriesNoDecision() {
        let out = HookCodec.parseHookOutput(exitCode: nil, stdout: "",
                                            stderr: "spawn failed: ENOENT")
        XCTAssertNil(out.exitCode)
        XCTAssertNil(out.decision)
        XCTAssertEqual(out.stderr, "spawn failed: ENOENT")
    }

    // MARK: structured stdout（exit 0 only）

    /// spec:41-48
    func testParsesTopLevelContinueStopReasonSystemMessage() {
        let json = "{\"continue\":false,\"stopReason\":\"budget exceeded\",\"systemMessage\":\"heads up\"}"
        let out = HookCodec.parseHookOutput(exitCode: 0, stdout: json, stderr: "")
        XCTAssertEqual(out.continue, false)
        XCTAssertEqual(out.stopReason, "budget exceeded")
        XCTAssertEqual(out.systemMessage, "heads up")
    }

    /// spec:50-53
    func testParsesLegacyTopLevelDecisionApproveBlockOnly() {
        XCTAssertEqual(
            HookCodec.parseHookOutput(exitCode: 0,
                                      stdout: "{\"decision\":\"block\",\"reason\":\"nope\"}",
                                      stderr: "").decision,
            .block)
        XCTAssertEqual(
            HookCodec.parseHookOutput(exitCode: 0,
                                      stdout: "{\"decision\":\"approve\"}",
                                      stderr: "").decision,
            .approve)
    }

    /// spec:55-61（顶层 allow/deny/ask 无效忽略——permissionDecision 保留）
    func testTopLevelAllowDenyAskInvalidIgnored() {
        XCTAssertNil(HookCodec.parseHookOutput(exitCode: 0,
                                               stdout: "{\"decision\":\"deny\"}",
                                               stderr: "").decision)
        XCTAssertNil(HookCodec.parseHookOutput(exitCode: 0,
                                               stdout: "{\"decision\":\"allow\"}",
                                               stderr: "").decision)
        XCTAssertNil(HookCodec.parseHookOutput(exitCode: 0,
                                               stdout: "{\"decision\":\"ask\"}",
                                               stderr: "").decision)
    }

    /// spec:63-67
    func testCapturesHookEventNameDiscriminator() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\"}}",
            stderr: "")
        XCTAssertEqual(out.hookEventName, "PreToolUse")
        XCTAssertEqual(out.decision, .deny)
    }

    /// spec:69-76
    func testPermissionDecisionOverridesLegacyDecision() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"decision\":\"approve\",\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"denied by policy\"}}",
            stderr: "")
        XCTAssertEqual(out.decision, .deny)
        XCTAssertEqual(out.reason, "denied by policy")
    }

    /// spec:78-81
    func testParsesAllowAndAskPermissionDecision() {
        XCTAssertEqual(
            HookCodec.parseHookOutput(exitCode: 0,
                                      stdout: "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}",
                                      stderr: "").decision,
            .allow)
        XCTAssertEqual(
            HookCodec.parseHookOutput(exitCode: 0,
                                      stdout: "{\"hookSpecificOutput\":{\"permissionDecision\":\"ask\"}}",
                                      stderr: "").decision,
            .ask)
    }

    /// spec:83-89
    func testParsesAdditionalContextAndUpdatedInput() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"additionalContext\":\"remember X\",\"updatedInput\":{\"command\":\"safe\"}}}",
            stderr: "")
        XCTAssertEqual(out.additionalContext, "remember X")
        XCTAssertEqual(out.updatedInput, ["command": .string("safe")])
    }

    /// spec:91-93
    func testUnknownDecisionStringIgnored() {
        XCTAssertNil(HookCodec.parseHookOutput(exitCode: 0,
                                               stdout: "{\"decision\":\"maybe\"}",
                                               stderr: "").decision)
    }

    /// spec:95-106（异名块整块丢弃，判别名仍记录）
    func testDiscardsMismatchedHookEventNameBlock() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"no\",\"additionalContext\":\"x\",\"updatedInput\":{\"command\":\"y\"}}}",
            stderr: "",
            expectedEventName: "Stop")
        XCTAssertEqual(out.hookEventName, "PreToolUse") // 仍记录供日志
        XCTAssertNil(out.decision) // 事件域字段丢弃
        XCTAssertNil(out.reason)
        XCTAssertNil(out.additionalContext)
        XCTAssertNil(out.updatedInput)
    }

    /// spec:108-114
    func testAppliesMatchingHookEventNameBlock() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"additionalContext\":\"x\"}}",
            stderr: "",
            expectedEventName: "PreToolUse")
        XCTAssertEqual(out.decision, .deny)
        XCTAssertEqual(out.additionalContext, "x")
    }

    /// spec:116-121
    func testAppliesBlockWhenExpectedEventNameOmitted() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\"}}",
            stderr: "")
        XCTAssertEqual(out.decision, .deny)
    }

    /// spec:123-133（缺判别名=同 malformed，事件域字段丢弃）
    func testDiscardsBlockWithoutHookEventNameWhenExpected() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"additionalContext\":\"x\"}}",
            stderr: "",
            expectedEventName: "Stop")
        XCTAssertNil(out.hookEventName) // 无可记录
        XCTAssertNil(out.decision) // 事件域字段丢弃
        XCTAssertNil(out.additionalContext)
    }

    /// spec:135-141
    func testAppliesDiscriminatorlessBlockWhenExpectedOmitted() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}",
            stderr: "")
        XCTAssertEqual(out.decision, .deny)
    }

    /// spec:143-153（异名块不丢弃事件无关的顶层字段）
    func testMismatchedBlockKeepsTopLevelFields() {
        let out = HookCodec.parseHookOutput(
            exitCode: 0,
            stdout: "{\"decision\":\"block\",\"reason\":\"top\",\"continue\":false,\"stopReason\":\"halt\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\"}}",
            stderr: "",
            expectedEventName: "Stop")
        XCTAssertEqual(out.decision, .block) // 顶层存活；allow 块被丢弃
        XCTAssertEqual(out.reason, "top")
        XCTAssertEqual(out.continue, false)
        XCTAssertEqual(out.stopReason, "halt")
    }

    /// spec:155-159
    func testMalformedJSONOnCleanExitIsLenient() {
        let out = HookCodec.parseHookOutput(exitCode: 0, stdout: "{ not valid json", stderr: "")
        XCTAssertNil(out.decision)
        XCTAssertNil(out.continue)
    }

    /// spec:161-168
    func testPlainTextStdoutLeftForBridge() {
        let out = HookCodec.parseHookOutput(exitCode: 0, stdout: "just some text output", stderr: "")
        XCTAssertNil(out.decision)
        XCTAssertNil(out.continue)
        XCTAssertEqual(out.stdout, "just some text output") // 原文保真（trim 后）
    }

    /// spec:170-175
    func testPreservesRawTrimmedStdoutWithStructuredFields() {
        let json = "{\"decision\":\"block\"}"
        let out = HookCodec.parseHookOutput(exitCode: 0, stdout: "  \(json)  \n", stderr: "")
        XCTAssertEqual(out.stdout, json)
        XCTAssertEqual(out.decision, .block)
    }

    /// spec:177-179
    func testStdoutEmptyStringWhenNone() {
        XCTAssertEqual(HookCodec.parseHookOutput(exitCode: 0, stdout: "", stderr: "").stdout, "")
    }

    /// spec:181-185（'[' 开头连 JSON 都不尝试）
    func testJSONArrayStdoutIsNeutral() {
        let out = HookCodec.parseHookOutput(exitCode: 0, stdout: "[1,2,3]", stderr: "")
        XCTAssertNil(out.decision)
    }

    /// spec:187-192（exit 2 时 stdout 结构化被忽略——stderr 权威）
    func testStructuredStdoutIgnoredOnBlockingExit() {
        let out = HookCodec.parseHookOutput(exitCode: 2,
                                            stdout: "{\"decision\":\"approve\"}",
                                            stderr: "blocked")
        XCTAssertEqual(out.decision, .block)
        XCTAssertEqual(out.reason, "blocked")
    }
}

// MARK: - merge.spec.ts（mergeHookOutputs）

final class HookMergeTests: XCTestCase {

    /// spec:5-7 的 out() helper。
    private func out(_ over: (inout HookOutput) -> Void = { _ in }) -> HookOutput {
        var value = HookOutput(exitCode: 0, stderr: "", stdout: "")
        over(&value)
        return value
    }

    /// spec:10-16
    func testEmptyListYieldsNeutralOutcome() {
        let m = HookMerge.mergeHookOutputs([])
        XCTAssertEqual(m.decision, .none)
        XCTAssertFalse(m.stop)
        XCTAssertEqual(m.additionalContext, [])
        XCTAssertEqual(m.systemMessages, [])
    }

    /// spec:18-21
    func testSingleAllowYieldsAllow() {
        XCTAssertEqual(HookMerge.mergeHookOutputs(
            [out { $0.decision = .allow }]).decision, .allow)
        XCTAssertEqual(HookMerge.mergeHookOutputs(
            [out { $0.decision = .approve }]).decision, .allow)
    }

    /// spec:23-29（deny>ask>allow 与序无关；block 折为 deny）
    func testDenyBeatsAskBeatsAllowRegardlessOfOrder() {
        XCTAssertEqual(HookMerge.mergeHookOutputs(
            [out { $0.decision = .allow }, out { $0.decision = .ask }]).decision, .ask)
        XCTAssertEqual(HookMerge.mergeHookOutputs(
            [out { $0.decision = .ask }, out { $0.decision = .deny }]).decision, .deny)
        XCTAssertEqual(HookMerge.mergeHookOutputs(
            [out { $0.decision = .deny }, out { $0.decision = .allow }]).decision, .deny)
        XCTAssertEqual(HookMerge.mergeHookOutputs(
            [out { $0.decision = .allow }, out { $0.decision = .block }]).decision, .deny)
    }

    /// spec:31-33
    func testNoDecisionAnywhereYieldsNone() {
        XCTAssertEqual(HookMerge.mergeHookOutputs([out(), out()]).decision, .none)
    }

    /// spec:37-44
    func testJoinsBlockingReasonsWithBlankLine() {
        let m = HookMerge.mergeHookOutputs([
            out { $0.decision = .deny; $0.reason = "first objection" },
            out { $0.decision = .allow; $0.reason = "this allow reason is NOT collected" },
            out { $0.decision = .block; $0.reason = "second objection" },
        ])
        XCTAssertEqual(m.reason, "first objection\n\nsecond objection")
    }

    /// spec:46-48
    func testNoReasonWhenNothingBlocked() {
        XCTAssertNil(HookMerge.mergeHookOutputs(
            [out { $0.decision = .allow }]).reason)
    }

    /// spec:50-57（ask 胜出时浮出 ask 理由）
    func testAskWinningOutcomeSurfacesAskReason() {
        let m = HookMerge.mergeHookOutputs([
            out { $0.decision = .allow; $0.reason = "allow reason — not surfaced" },
            out { $0.decision = .ask; $0.reason = "needs approval" },
        ])
        XCTAssertEqual(m.decision, .ask)
        XCTAssertEqual(m.reason, "needs approval")
    }

    /// spec:59-66（deny 胜出时 ask 理由被丢弃——只有胜出 rank 的理由）
    func testDenyWinDropsAskReasons() {
        let m = HookMerge.mergeHookOutputs([
            out { $0.decision = .ask; $0.reason = "ask reason — not surfaced once deny wins" },
            out { $0.decision = .deny; $0.reason = "the real objection" },
        ])
        XCTAssertEqual(m.decision, .deny)
        XCTAssertEqual(m.reason, "the real objection")
    }

    /// spec:68-76（首个 continue:false sticky，捕其 stopReason）
    func testStopStickyOnFirstContinueFalse() {
        let m = HookMerge.mergeHookOutputs([
            out { $0.continue = true },
            out { $0.continue = false; $0.stopReason = "halt now" },
            out { $0.continue = false; $0.stopReason = "second halt — ignored" },
        ])
        XCTAssertTrue(m.stop)
        XCTAssertEqual(m.stopReason, "halt now")
    }

    /// spec:78-82
    func testNoStopWhenEveryHookContinues() {
        let m = HookMerge.mergeHookOutputs([out { $0.continue = true }, out()])
        XCTAssertFalse(m.stop)
        XCTAssertNil(m.stopReason)
    }

    /// spec:84-88
    func testContinueFalseWithoutStopReasonStopsWithNilReason() {
        let m = HookMerge.mergeHookOutputs([out { $0.continue = false }])
        XCTAssertTrue(m.stop)
        XCTAssertNil(m.stopReason)
    }

    /// spec:90-99（按 hook 序收集，跳过空串）
    func testCollectsContextAndSystemMessagesInOrderSkippingEmpties() {
        let m = HookMerge.mergeHookOutputs([
            out { $0.additionalContext = "ctx-A"; $0.systemMessage = "warn-A" },
            out { $0.additionalContext = ""; $0.systemMessage = "" }, // 空串跳过
            out { $0.additionalContext = "ctx-B" },
            out { $0.systemMessage = "warn-B" },
        ])
        XCTAssertEqual(m.additionalContext, ["ctx-A", "ctx-B"])
        XCTAssertEqual(m.systemMessages, ["warn-A", "warn-B"])
    }
}

// MARK: - matcher.spec.ts（matchesMatcher / matcherDiagnostic）

final class HookMatcherTests: XCTestCase {

    /// spec:4-12（两方言 × 三哨兵）
    func testMatchAllSentinelsBothDialects() {
        for mode in [MatcherMode.claudeCode, .codex] {
            XCTAssertTrue(HookMatcher.matchesMatcher(nil, query: "Bash", mode: mode))
            XCTAssertTrue(HookMatcher.matchesMatcher("", query: "anything", mode: mode))
            XCTAssertTrue(HookMatcher.matchesMatcher("*", query: "whatever", mode: mode))
        }
    }

    /// spec:15-19（literal 精确匹配，非子串）
    func testClaudeLiteralIsExactMatchNotSubstring() {
        XCTAssertTrue(HookMatcher.matchesMatcher("Bash", query: "Bash", mode: .claudeCode))
        // literal 精确："Bash" 不得匹配 "BashOutput"（regex 会子串命中）
        XCTAssertFalse(HookMatcher.matchesMatcher("Bash", query: "BashOutput", mode: .claudeCode))
    }

    /// spec:21-27（pipe = 逐备选精确）
    func testClaudePipePatternIsLiteralAlternation() {
        XCTAssertTrue(HookMatcher.matchesMatcher("Edit|Write", query: "Edit", mode: .claudeCode))
        XCTAssertTrue(HookMatcher.matchesMatcher("Edit|Write", query: "Write", mode: .claudeCode))
        XCTAssertFalse(HookMatcher.matchesMatcher("Edit|Write", query: "Read", mode: .claudeCode))
        XCTAssertFalse(HookMatcher.matchesMatcher("Edit|Write", query: "EditFile", mode: .claudeCode))
    }

    /// spec:29-34（非 word 模式落 regex，unanchored）
    func testClaudeNonWordPatternFallsToRegex() {
        XCTAssertTrue(HookMatcher.matchesMatcher("^Bash$", query: "Bash", mode: .claudeCode))
        XCTAssertTrue(HookMatcher.matchesMatcher("Bash.*", query: "BashOutput", mode: .claudeCode))
        XCTAssertTrue(HookMatcher.matchesMatcher(".*\\.ts$", query: "foo.ts", mode: .claudeCode))
        XCTAssertFalse(HookMatcher.matchesMatcher(".*\\.ts$", query: "foo.js", mode: .claudeCode))
    }

    /// spec:38-42（codex 无 literal 快路径——word 模式也是子串 regex）
    func testCodexWordPatternIsUnanchoredRegex() {
        XCTAssertTrue(HookMatcher.matchesMatcher("Bash", query: "Bash", mode: .codex))
        XCTAssertTrue(HookMatcher.matchesMatcher("Bash", query: "BashOutput", mode: .codex))
    }

    /// spec:44-48
    func testCodexRegexAlternationAndAnchors() {
        XCTAssertTrue(HookMatcher.matchesMatcher("Edit|Write", query: "Edit", mode: .codex))
        XCTAssertTrue(HookMatcher.matchesMatcher("^Bash$", query: "Bash", mode: .codex))
        XCTAssertFalse(HookMatcher.matchesMatcher("^Bash$", query: "BashOutput", mode: .codex))
    }

    /// spec:51-58（无效 regex = 非匹配，永不抛）
    func testInvalidRegexIsNonMatchNeverThrows() {
        XCTAssertFalse(HookMatcher.matchesMatcher("(", query: "x", mode: .claudeCode))
        XCTAssertFalse(HookMatcher.matchesMatcher("[", query: "x", mode: .codex))
    }

    /// spec:60-68
    func testMatcherDiagnosticAcceptsValidPatterns() {
        XCTAssertNil(HookMatcher.matcherDiagnostic(nil, mode: .claudeCode))
        XCTAssertNil(HookMatcher.matcherDiagnostic("", mode: .codex))
        XCTAssertNil(HookMatcher.matcherDiagnostic("*", mode: .codex))
        XCTAssertNil(HookMatcher.matcherDiagnostic("Edit|Write", mode: .claudeCode))
        XCTAssertNil(HookMatcher.matcherDiagnostic("^Bash$", mode: .claudeCode))
        XCTAssertNil(HookMatcher.matcherDiagnostic("Edit|Write", mode: .codex))
    }

    /// spec:70-73（无效 regex 稳定诊断串）
    func testMatcherDiagnosticStableForInvalidRegex() {
        XCTAssertEqual(HookMatcher.matcherDiagnostic("(", mode: .claudeCode),
                       "invalid claude-code regex matcher \"(\"")
        XCTAssertEqual(HookMatcher.matcherDiagnostic("[", mode: .codex),
                       "invalid codex regex matcher \"[\"")
    }
}
