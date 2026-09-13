//
//  HookSessionEventsTests.swift
//  WanWoTests
//
//  【M4-E 批 E3 测试 · hook/* 事件对端口】dsh hook-protocol tests/events.spec.ts
//  移植 + E1 通道接入面断言：
//    · summarizeStderr 三分支（空白→nil / trim 直通 / 截断加省略号）+ 帽
//      排他边界（恰 500 原样 / 501 截 500+…）+ 默认帽 = 500；
//    · appendHookInvoked payload 形态（五键齐 / matcher 缺席省略键）；
//    · appendHookResult 派生面（decision 三分支：显式 > continue:false→stop >
//      pass；exitCode/stderrSummary 缺席省略键；durationMs 恒含；全形态
//      toEqual 精确对拍）；
//    · registry 注册面（两 kind 注册 / logOnly / invoked answeredBy(handlerId)
//      / result .none / 未知 dialect 拒 / 必填缺-类型错-值非法拒）；
//    · 配对校验三态（真 SessionWriter 端到端：正常对落盘 / 无 invoked 的
//      result 抛 extensionPairViolation / 写侧门拒未知 dialect）。
//

import XCTest
@testable import WanWo

final class HookSessionEventsTests: XCTestCase {

    // MARK: 夹具（真 JsonlEventLog + SessionDatabase + SessionWriter，临时目录）

    private func makeWriter(id: String) async throws -> (SessionWriter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-events-\(id)-\(UUID().uuidString)",
                                     isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let header = SessionHeader(id: id, createdAtMs: 0, cwd: nil)
        let log = try JsonlEventLog.create(
            header: header, at: dir.appendingPathComponent("events.jsonl"))
        let database = try SessionDatabase(
            path: dir.appendingPathComponent("index.sqlite").path)
        let writer = try await SessionWriter(id: id, header: header,
                                             log: log, database: database)
        return (writer, dir)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 注册表是进程级单例：隔离重建（resetForTests + 本端口幂等注册）。
        ExtensionEventRegistry.shared.resetForTests()
        HookSessionEvents.registerEventSchemas()
    }

    override func tearDownWithError() throws {
        ExtensionEventRegistry.shared.resetForTests()
        try super.tearDownWithError()
    }

    /// 从事件提取 extension payload 字段表。
    private func extensionFields(of event: SessionEvent) -> (kind: String,
                                                             fields: [String: JSONValue])? {
        guard case .extensionEvent(let kind, let payload) = event.payload,
              case .object(let fields) = payload else { return nil }
        return (kind, fields)
    }

    // MARK: - summarizeStderr 三分支（dsh events.spec.ts describe('summarizeStderr')）

    func testSummarizeStderrEmptyAndWhitespaceIsNil() {
        XCTAssertNil(HookSessionEvents.summarizeStderr("", maxChars: 500))
        XCTAssertNil(HookSessionEvents.summarizeStderr("  \n\t ", maxChars: 500))
    }

    func testSummarizeStderrTrimsAndPassesThrough() {
        XCTAssertEqual(
            HookSessionEvents.summarizeStderr("  blocked: bad tool  ", maxChars: 500),
            "blocked: bad tool")
        XCTAssertEqual(HookSessionEvents.summarizeStderr("abc", maxChars: 3), "abc")
    }

    func testSummarizeStderrTruncatesWithEllipsis() {
        XCTAssertEqual(HookSessionEvents.summarizeStderr("abcdef", maxChars: 4),
                       "abcd…")
        XCTAssertEqual(
            HookSessionEvents.summarizeStderr(String(repeating: "x", count: 600),
                                              maxChars: 500),
            String(repeating: "x", count: 500) + "…")
    }

    // MARK: 帽排他边界（dsh events.spec.ts:84-94）

    func testSummarizeStderrExactlyAtCapKeptVerbatim() {
        let exact = String(repeating: "y", count: 500)
        XCTAssertEqual(HookSessionEvents.summarizeStderr(exact, maxChars: 500), exact)
    }

    func testSummarizeStderrOneOverCapTruncates() {
        let over = String(repeating: "z", count: 501)
        XCTAssertEqual(HookSessionEvents.summarizeStderr(over, maxChars: 500),
                       String(repeating: "z", count: 500) + "…")
    }

    func testDefaultStderrSummaryMaxCharsIs500() {
        // dsh events.ts:53 DEFAULT_STDERR_SUMMARY_MAX_CHARS。
        XCTAssertEqual(HookSessionEvents.defaultStderrSummaryMaxChars, 500)
    }

    // MARK: - appendHookInvoked payload 形态（dsh events.spec.ts:11-32）

    func testAppendHookInvokedPayloadWithMatcher() async throws {
        let (writer, dir) = try await makeWriter(id: "invoked-full")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await HookSessionEvents.appendHookInvoked(to: writer,
            invocation: HookInvocation(turn: 1, point: "PreToolUse",
                                       dialect: .claudeCode, handlerId: "h1",
                                       matcher: "Bash"))
        let event = try XCTUnwrap(writer.events.last)
        let extracted = try XCTUnwrap(extensionFields(of: event))
        XCTAssertEqual(extracted.kind, HookSessionEvents.invokedKind)
        // events.ts:76-82 全形态对拍（键名 dsh 逐字保真）。
        XCTAssertEqual(extracted.fields, [
            "turn": .int(1),
            "point": .string("PreToolUse"),
            "dialect": .string("claude-code"),
            "handlerId": .string("h1"),
            "matcher": .string("Bash"),
        ])
    }

    func testAppendHookInvokedOmitsMatcherWhenAbsent() async throws {
        let (writer, dir) = try await makeWriter(id: "invoked-sparse")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await HookSessionEvents.appendHookInvoked(to: writer,
            invocation: HookInvocation(turn: 2, point: "Stop",
                                       dialect: .codex, handlerId: "h2",
                                       matcher: nil))
        let extracted = try XCTUnwrap(extensionFields(of: try XCTUnwrap(writer.events.last)))
        // events.ts:81——matcher 缺席省略键（match-all hook）。
        XCTAssertFalse(extracted.fields.keys.contains("matcher"))
        XCTAssertEqual(extracted.fields["dialect"], .string("codex"))
    }

    // MARK: - appendHookResult 派生面（dsh events.spec.ts:34-70）

    func testAppendHookResultFullShape() async throws {
        let (writer, dir) = try await makeWriter(id: "result-full")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await HookSessionEvents.appendHookResult(to: writer,
            record: HookResultRecord(turn: 1, point: "PreToolUse", handlerId: "h1",
                                     output: HookOutput(exitCode: 2, stderr: "blocked",
                                                        stdout: "", decision: .deny),
                                     stderrSummaryMaxChars: 500, durationMs: 5))
        let extracted = try XCTUnwrap(extensionFields(of: try XCTUnwrap(writer.events.last)))
        XCTAssertEqual(extracted.kind, HookSessionEvents.resultKind)
        // dsh events.spec.ts:42 toEqual 精确对拍。
        XCTAssertEqual(extracted.fields, [
            "turn": .int(1),
            "point": .string("PreToolUse"),
            "handlerId": .string("h1"),
            "decision": .string("deny"),
            "exitCode": .int(2),
            "stderrSummary": .string("blocked"),
            "durationMs": .int(5),
        ])
    }

    func testAppendHookResultOmitsAbsentExitCodeAndStderrSummary() async throws {
        let (writer, dir) = try await makeWriter(id: "result-sparse")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await HookSessionEvents.appendHookResult(to: writer,
            record: HookResultRecord(turn: 1, point: "Stop", handlerId: "h3",
                                     output: HookOutput(exitCode: nil, stderr: "",
                                                        stdout: "", decision: .allow),
                                     stderrSummaryMaxChars: 500, durationMs: 5))
        let extracted = try XCTUnwrap(extensionFields(of: try XCTUnwrap(writer.events.last)))
        // dsh events.spec.ts:53-54——两键缺席省略；decision 显式直通。
        XCTAssertFalse(extracted.fields.keys.contains("exitCode"))
        XCTAssertFalse(extracted.fields.keys.contains("stderrSummary"))
        XCTAssertEqual(extracted.fields["decision"], .string("allow"))
        XCTAssertEqual(extracted.fields["durationMs"], .int(5))
    }

    func testDecisionFallbackThreeBranches() async throws {
        let (writer, dir) = try await makeWriter(id: "decision-fallback")
        defer { try? FileManager.default.removeItem(at: dir) }

        // ① continue:false → stop（events.ts:99 回退第一支）。
        _ = try await HookSessionEvents.appendHookResult(to: writer,
            record: HookResultRecord(turn: 1, point: "Stop", handlerId: "halt",
                                     output: HookOutput(exitCode: 0, stderr: "",
                                                        stdout: "", continue: false),
                                     stderrSummaryMaxChars: 500, durationMs: 5))
        // ② 无 continue 无 decision → pass。
        _ = try await HookSessionEvents.appendHookResult(to: writer,
            record: HookResultRecord(turn: 1, point: "Stop", handlerId: "noop",
                                     output: HookOutput(exitCode: 0, stderr: "",
                                                        stdout: ""),
                                     stderrSummaryMaxChars: 500, durationMs: 5))
        // ③ 显式 decision 压过 continue:false（events.ts:99 ?? 左支优先）。
        _ = try await HookSessionEvents.appendHookResult(to: writer,
            record: HookResultRecord(turn: 1, point: "Stop", handlerId: "both",
                                     output: HookOutput(exitCode: 0, stderr: "",
                                                        stdout: "", continue: false,
                                                        decision: .block),
                                     stderrSummaryMaxChars: 500, durationMs: 5))

        let decisions = writer.events.compactMap { event -> (String, String)? in
            guard let extracted = extensionFields(of: event),
                  extracted.kind == HookSessionEvents.resultKind,
                  case .string(let handlerId) = extracted.fields["handlerId"],
                  case .string(let decision) = extracted.fields["decision"]
            else { return nil }
            return (handlerId, decision)
        }
        // dsh events.spec.ts:69——三分支一比一。
        XCTAssertEqual(decisions.map { $0.0 }, ["halt", "noop", "both"])
        XCTAssertEqual(decisions.map { $0.1 }, ["stop", "pass", "block"])
    }

    // MARK: - registry 注册面（E1 通道接入）

    func testRegistryRegistersBothKindsWithLogOnlyProjection() {
        let registry = ExtensionEventRegistry.shared
        XCTAssertTrue(registry.isRegistered(HookSessionEvents.invokedKind))
        XCTAssertTrue(registry.isRegistered(HookSessionEvents.resultKind))
        // M4-E E3 派单：注册为 projection .logOnly（审计记录，不进派生历史）。
        XCTAssertEqual(registry.projectionRule(for: HookSessionEvents.invokedKind),
                       .logOnly)
        XCTAssertEqual(registry.projectionRule(for: HookSessionEvents.resultKind),
                       .logOnly)
    }

    func testRegistryPairingRules() {
        let registry = ExtensionEventRegistry.shared
        // invoked：开事件，answeredBy(hook/result, handlerId)。
        XCTAssertEqual(registry.pairingRule(for: HookSessionEvents.invokedKind),
                       .answeredBy(closeKind: HookSessionEvents.resultKind,
                                   keyField: "handlerId"))
        // result：close 侧自身 .none——经 invoked 规则被消费（先关后开序）。
        XCTAssertEqual(registry.pairingRule(for: HookSessionEvents.resultKind), .none)
    }

    func testRegistryRejectsUnknownDialect() {
        let registry = ExtensionEventRegistry.shared
        let legal: [String: JSONValue] = [
            "turn": .int(1), "point": .string("PreToolUse"),
            "dialect": .string("codex"), "handlerId": .string("h1"),
        ]
        XCTAssertNil(registry.validationReason(
            kind: HookSessionEvents.invokedKind, payload: .object(legal)))
        // 未知 dialect fail closed（allowedValues 封闭值域）。
        var unknown = legal
        unknown["dialect"] = .string("opencode")
        XCTAssertNotNil(registry.validationReason(
            kind: HookSessionEvents.invokedKind, payload: .object(unknown)))
    }

    func testRegistryResultSchemaRejectsMissingWrongTypedAndIllegalValues() {
        let registry = ExtensionEventRegistry.shared
        let legal: [String: JSONValue] = [
            "turn": .int(1), "point": .string("Stop"),
            "handlerId": .string("h1"), "decision": .string("pass"),
            "durationMs": .int(5),
        ]
        XCTAssertNil(registry.validationReason(
            kind: HookSessionEvents.resultKind, payload: .object(legal)))

        // 缺必填字段（durationMs 恒含——缺即拒）。
        var missing = legal
        missing.removeValue(forKey: "durationMs")
        XCTAssertNotNil(registry.validationReason(
            kind: HookSessionEvents.resultKind, payload: .object(missing)))

        // 类型错（durationMs 必须整型）。
        var wrongType = legal
        wrongType["durationMs"] = .string("5")
        XCTAssertNotNil(registry.validationReason(
            kind: HookSessionEvents.resultKind, payload: .object(wrongType)))

        // decision 值域外（七值闭集：五 HookDecision + stop/pass）。
        var illegal = legal
        illegal["decision"] = .string("bogus")
        XCTAssertNotNil(registry.validationReason(
            kind: HookSessionEvents.resultKind, payload: .object(illegal)))
    }

    // MARK: - 配对校验三态（真 SessionWriter 端到端）

    func testInvokedResultPairAppendsCorrelated() async throws {
        let (writer, dir) = try await makeWriter(id: "pair-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await HookSessionEvents.appendHookInvoked(to: writer,
            invocation: HookInvocation(turn: 1, point: "PreToolUse",
                                       dialect: .claudeCode, handlerId: "pair-1",
                                       matcher: nil))
        _ = try await HookSessionEvents.appendHookResult(to: writer,
            record: HookResultRecord(turn: 1, point: "PreToolUse", handlerId: "pair-1",
                                     output: HookOutput(exitCode: 0, stderr: "",
                                                        stdout: "", decision: .allow),
                                     stderrSummaryMaxChars: 500, durationMs: 5))
        // dsh events.spec.ts:96-105——handlerId 关联对齐，两条均落盘。
        let kinds = writer.events.compactMap { event -> String? in
            guard let extracted = extensionFields(of: event) else { return nil }
            return extracted.kind
        }
        XCTAssertEqual(kinds, [HookSessionEvents.invokedKind,
                               HookSessionEvents.resultKind])
        XCTAssertEqual(writer.events.count, 2)
        // E1 通道 wire 恒 ignorable（SessionEvent:217-226 编码端承载）。
        XCTAssertTrue(writer.events.allSatisfy(\.ignorable))
    }

    func testResultWithoutInvokedIsRejectedByInvariant() async throws {
        let (writer, dir) = try await makeWriter(id: "pair-orphan")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await HookSessionEvents.appendHookResult(to: writer,
                record: HookResultRecord(turn: 1, point: "PreToolUse", handlerId: "ghost",
                                         output: HookOutput(exitCode: 0, stderr: "",
                                                            stdout: "", decision: .allow),
                                         stderrSummaryMaxChars: 500, durationMs: 5))
            XCTFail("无 invoked 的 hook/result 必须 fail closed")
        } catch let violation as SessionInvariant.InvariantViolation {
            guard case .extensionPairViolation(_, let kind, let reason) = violation else {
                return XCTFail("非预期违例形态: \(violation)")
            }
            XCTAssertEqual(kind, HookSessionEvents.resultKind)
            XCTAssertTrue(reason.contains("no open"), "reason=\(reason)")
        }
        // 拒绝后日志零残留（校验先于落盘，fail closed 不污染事件流）。
        XCTAssertTrue(writer.events.isEmpty)
    }

    func testWriteSideGateRejectsUnknownDialect() async throws {
        let (writer, dir) = try await makeWriter(id: "gate-dialect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload: [String: JSONValue] = [
            "turn": .int(1), "point": .string("PreToolUse"),
            "dialect": .string("opencode"), "handlerId": .string("h1"),
        ]
        do {
            _ = try await writer.append(
                .extensionEvent(kind: HookSessionEvents.invokedKind,
                                payload: .object(payload)))
            XCTFail("未知 dialect 必须被写侧门拒绝")
        } catch let violation as ExtensionEventRegistry.SchemaViolation {
            // SessionWriter.appendOnce 的 E1 写侧门（validationReason fail closed）。
            XCTAssertEqual(violation.kind, HookSessionEvents.invokedKind)
            XCTAssertTrue(violation.reason.contains("allowed set"))
        }
        XCTAssertTrue(writer.events.isEmpty)
    }
}
