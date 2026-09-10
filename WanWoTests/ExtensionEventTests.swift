//
//  ExtensionEventTests.swift
//  WanWoTests
//
//  【M3 E1 单测】事件词汇扩展通道（10-design v2.4 修订①）：
//    · replay 全量回归：旧 JSONL（无 extension）读取不变
//    · extension 编码→解码→schema 校验→投影往返
//    · 未注册 kind 透传 + 扫描计数（旧版本读新日志不崩）
//    · SessionInvariant 配对规则（answeredBy 开/关/违例）
//    · DeriveFold / ConversationProjector 投影规则分流
//

import XCTest
@testable import WanWo

final class ExtensionEventTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ExtensionEventRegistry.shared.resetForTests()
    }

    override func tearDown() {
        ExtensionEventRegistry.shared.resetForTests()
        super.tearDown()
    }

    // MARK: - 助手

    /// 测试用 demo schema：id(string) + verdict(string 枚举) + count(int)。
    private func registerDemoSchema(kind: String = "test/demo",
                                    projection: ExtensionEventProjection = .logOnly) {
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: kind,
            requiredFields: [
                ExtensionFieldSchema("id", .string),
                ExtensionFieldSchema("verdict", .string,
                                     allowedValues: [.string("go"), .string("stop")]),
                ExtensionFieldSchema("count", .int),
            ],
            projection: projection))
    }

    private func demoPayload(id: String = "k1", verdict: String = "go",
                             count: Int = 3) -> JSONValue {
        .object(["id": .string(id), "verdict": .string(verdict), "count": .int(count)])
    }

    /// JSONL 字节构造（头行 + 事件行，与 JsonlEventLog 行格式同形）。
    private func jsonl(_ events: [SessionEvent]) throws -> Data {
        let header = #"{"type":"session","version":0,"id":"test-session","createdAt":0}"#
        var lines = [header]
        for event in events {
            lines.append(String(decoding: try JSONEncoder().encode(event), as: UTF8.self))
        }
        return Data(lines.joined(separator: "\n").appending("\n").utf8)
    }

    private func userEvent(_ seq: Int, _ text: String) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: .userMessage(text: text))
    }

    private func extEvent(_ seq: Int, _ kind: String, _ payload: JSONValue) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0,
                     payload: .extensionEvent(kind: kind, payload: payload))
    }

    // MARK: wire 形状与编码往返

    func testWireTypeAndCodableRoundTrip() throws {
        registerDemoSchema()
        let event = extEvent(0, "test/demo", demoPayload())
        XCTAssertEqual(event.wireType, "extension/test/demo")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(SessionEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.wireType, "extension/test/demo")
    }

    func testExtensionWireIgnorableDefault() {
        // v2.4 修订①：extension 恒 ignorable（旧构建读新日志透传不崩的承载）。
        XCTAssertTrue(SessionEvent.defaultIgnorable(for: "extension/test/demo"))
        XCTAssertTrue(SessionEvent.defaultIgnorable(for: "extension/anything"))
        XCTAssertEqual(SessionEvent.defaultIgnorable(for: "tool/call"), false)
    }

    // MARK: schema 校验（fail closed：缺字段/类型错/值非法/非对象）

    func testSchemaValidationFailClosed() {
        registerDemoSchema()
        let registry = ExtensionEventRegistry.shared
        // 合法载荷：无违例。
        XCTAssertNil(registry.validationReason(kind: "test/demo", payload: demoPayload()))
        // 缺字段。
        XCTAssertNotNil(registry.validationReason(
            kind: "test/demo",
            payload: .object(["id": .string("k1"), "verdict": .string("go")])))
        // 类型错（count 应为 int）。
        XCTAssertNotNil(registry.validationReason(
            kind: "test/demo",
            payload: .object(["id": .string("k1"), "verdict": .string("go"),
                              "count": .string("3")])))
        // 值非法（verdict 枚举外）。
        XCTAssertNotNil(registry.validationReason(
            kind: "test/demo",
            payload: .object(["id": .string("k1"), "verdict": .string("maybe"),
                              "count": .int(3)])))
        // 载荷非对象。
        XCTAssertNotNil(registry.validationReason(kind: "test/demo", payload: .array([])))
        // 未注册 kind：一律合法（透传口径）。
        XCTAssertNil(registry.validationReason(kind: "future/thing", payload: .null))
    }

    /// 解码层 fail closed：已注册 kind 的违例载荷 → JSONDecoder 抛错（拒该条）。
    func testDecodeRejectsSchemaViolation() throws {
        registerDemoSchema()
        let bad = extEvent(0, "test/demo",
                           .object(["id": .string("k1"), "verdict": .string("go")]))
        let line = try JSONEncoder().encode(bad)
        XCTAssertThrowsError(try JSONDecoder().decode(SessionEvent.self, from: line))
    }

    // MARK: 未知 kind：解码透传 + 扫描计数（旧版本读新日志不崩）

    func testUnknownKindPassesThroughAndScannerCounts() throws {
        // 无注册：kind "future/thing" 解码透传不抛。
        let unknown = extEvent(1, "future/thing", .object(["x": .int(1)]))
        let decoded = try JSONDecoder().decode(
            SessionEvent.self, from: JSONEncoder().encode(unknown))
        XCTAssertEqual(decoded.payload, unknown.payload)

        // 扫描：透传保留在流内（保 seq 连续性）+ 计数。
        let data = try jsonl([
            userEvent(0, "hi"),
            unknown,
            userEvent(2, "again"),
        ])
        let scan = try SessionLogScanner.scan(data: data)
        XCTAssertEqual(scan.events.count, 3)
        XCTAssertNil(scan.issue)
        XCTAssertEqual(scan.skippedExtensionCount, 1)
        XCTAssertEqual(scan.skippedExtensionKinds, ["future/thing"])
    }

    /// kind 与 wire 不一致（拼错行）→ 解码拒绝。
    func testKindWireMismatchRejected() throws {
        let event = extEvent(0, "test/demo", demoPayload())
        var line = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        // 把 wire type 改成不匹配的 kind。注意 Apple JSONEncoder 会把 "/"
        // 转义为 "\/"——必须匹配转义形态，否则替换静默不生效（与事件流
        // grep 误诊同源的 JSON 转义斜杠坑）。
        line = line.replacingOccurrences(of: "extension\\/test\\/demo",
                                         with: "extension\\/test\\/other")
        XCTAssertThrowsError(try JSONDecoder().decode(SessionEvent.self,
                                                      from: Data(line.utf8)))
    }

    // MARK: replay 全量回归：旧 JSONL（无 extension）读取不变

    func testLegacyJSONLReplayUnchanged() throws {
        let message = AssistantMessage(id: "m1", provider: "p", model: "m",
                                       content: [.text("方案"), .toolCall(id: "c1",
                                                                         name: "bash",
                                                                         arguments: "{}")])
        let legacy: [SessionEvent] = [
            SessionEvent(seq: 0, timeMs: 0, payload: .turnStart(turn: 1)),
            SessionEvent(seq: 1, timeMs: 0, payload: .stepStart(turn: 1, step: 1)),
            userEvent(2, "帮我跑一下"),
            SessionEvent(seq: 3, timeMs: 0,
                         payload: .assistantMessage(turn: 1, step: 1, message: message,
                                                    usage: nil, interrupted: false)),
            SessionEvent(seq: 4, timeMs: 0,
                         payload: .toolCall(turn: 1, step: 1, callId: "c1",
                                            name: "bash", arguments: "{}")),
            SessionEvent(seq: 5, timeMs: 0,
                         payload: .toolResult(turn: 1, step: 1, callId: "c1",
                                              content: "done", isError: false,
                                              errorName: nil, errorCode: nil, meta: nil)),
            SessionEvent(seq: 6, timeMs: 0, payload: .stepEnd(turn: 1, step: 1)),
            SessionEvent(seq: 7, timeMs: 0,
                         payload: .turnEnd(turn: 1, reason: .completed)),
        ]
        let scan = try SessionLogScanner.scan(data: try jsonl(legacy))
        XCTAssertEqual(scan.events, legacy, "旧 JSONL 读取必须逐字节语义不变")
        XCTAssertNil(scan.issue)
        XCTAssertEqual(scan.skippedExtensionCount, 0)
    }

    // MARK: 不变量：extension 中性 + answeredBy 配对

    func testInvariantAcceptsExtensionAsNeutral() throws {
        registerDemoSchema()
        var invariant = SessionInvariant()
        try invariant.validate(extEvent(0, "test/demo", demoPayload()))
        try invariant.validate(extEvent(1, "unregistered/thing", .null))
        try invariant.validate(userEvent(2, "ok"))
    }

    func testInvariantAnsweredByPairing() throws {
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: "test/hook-open",
            requiredFields: [ExtensionFieldSchema("runId", .string)],
            pairing: .answeredBy(closeKind: "test/hook-close", keyField: "runId")))
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: "test/hook-close",
            requiredFields: [ExtensionFieldSchema("runId", .string)]))

        var invariant = SessionInvariant()
        // open(k1) → close(k1)：合法成对。
        try invariant.validate(extEvent(0, "test/hook-open",
                                        .object(["runId": .string("k1")])))
        try invariant.validate(extEvent(1, "test/hook-close",
                                        .object(["runId": .string("k1")])))
        // open(k2) → close(k3)：close 无 open → 违例。
        try invariant.validate(extEvent(2, "test/hook-open",
                                        .object(["runId": .string("k2")])))
        XCTAssertThrowsError(try invariant.validate(
            extEvent(3, "test/hook-close", .object(["runId": .string("k3")])))
        ) { error in
            guard case SessionInvariant.InvariantViolation.extensionPairViolation =
                error else {
                return XCTFail("应抛 extensionPairViolation：\(error)")
            }
        }
        // 同键二次 close（k1 已消费）→ 违例。
        XCTAssertThrowsError(try invariant.validate(
            extEvent(4, "test/hook-close", .object(["runId": .string("k1")])))
        ) { error in
            guard case SessionInvariant.InvariantViolation.extensionPairViolation =
                error else {
                return XCTFail("已消费键不得重复 close：\(error)")
            }
        }
        // close 键缺失/非字符串 → 违例。
        XCTAssertThrowsError(try invariant.validate(
            extEvent(5, "test/hook-close", .object([:]))) ) { error in
            guard case SessionInvariant.InvariantViolation.extensionPairViolation =
                error else {
                return XCTFail("close 缺键应违例：\(error)")
            }
        }
    }

    // MARK: DeriveFold 投影规则分流

    func testDeriveFoldProjectionRules() {
        registerDemoSchema(kind: "test/log-only", projection: .logOnly)
        registerDemoSchema(kind: "test/model-visible", projection: .modelVisible)
        let events = [
            userEvent(0, "hi"),
            extEvent(1, "test/log-only", demoPayload()),
            extEvent(2, "test/model-visible", demoPayload(id: "k2")),
        ]
        let messages = DeriveFold(events).messages
        // logOnly 跳过；modelVisible 以标准信封 user 消息进派生。
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].content, "hi")
        XCTAssertTrue(messages[1].content.hasPrefix("<extension-event kind=\"test/model-visible\">"),
                      "信封缺失：\(messages[1].content)")
        XCTAssertTrue(messages[1].content.contains("\"id\":\"k2\""),
                      "载荷缺失：\(messages[1].content)")
    }

    // MARK: ConversationProjector（UI 投影）规则分流

    func testUIProjectionRules() {
        registerDemoSchema(kind: "test/log-only", projection: .logOnly)
        registerDemoSchema(kind: "test/model-visible", projection: .modelVisible)
        let events = [
            userEvent(0, "hi"),
            extEvent(1, "test/log-only", demoPayload()),
            extEvent(2, "test/unregistered", .object(["x": .int(1)])),
            extEvent(3, "test/model-visible", demoPayload()),
        ]
        var callArgs: [String: (name: String, args: JSONValue)] = [:]
        let bubbles = ConversationProjector.project(events: events, registry: nil,
                                                    callArgs: &callArgs)
        // logOnly 与未注册均不渲染；modelVisible 渲染 note 气泡（id 锚定 seq）。
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles[0].id, "u0")
        XCTAssertEqual(bubbles[1].id, "x3")
        guard case .note(let text) = bubbles[1].kind else {
            return XCTFail("model-visible extension 应渲染 note 气泡：\(bubbles[1].kind)")
        }
        XCTAssertTrue(text.contains("test/model-visible"))
    }
}
