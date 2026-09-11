//
//  MCPElicitationTests.swift
//  WanWoTests
//
//  【M4-A 件12】件9 锚点：elicitation 决策链纯函数面（MCPElicitation.swift）——
//  canAutoAccept 三态（codex can_auto_accept_elicitation :483-496：仅标准
//  form 且 properties 为空）；eventPayload（codex ElicitationRequest
//  :376-429 的 E1 形态 + :382-385/:396-399 meta 携带——lead 件9 review
//  补充锚点）：form/url 全字段 + meta 在场/缺席语义。
//

import XCTest
import MCP
@testable import WanWo

final class MCPElicitationTests: XCTestCase {

    // MARK: canAutoAccept 三态（:483-496 1:1）

    func testEmptyFormIsAutoAcceptable() {
        let params = CreateElicitation.Parameters.form(.init(
            message: "Confirm?",
            requestedSchema: .init(properties: [:])))
        XCTAssertTrue(MCPElicitationManager.canAutoAccept(params))
    }

    func testFormWithPropertiesIsNotAutoAcceptable() {
        let params = CreateElicitation.Parameters.form(.init(
            message: "Enter name",
            requestedSchema: .init(properties: [
                "name": .object(["type": .string("string")]),
            ])))
        XCTAssertFalse(MCPElicitationManager.canAutoAccept(params))
    }

    func testUrlElicitationIsNeverAutoAcceptable() {
        let params = CreateElicitation.Parameters.url(.init(
            message: "Open link",
            url: "https://example.com/auth",
            elicitationId: "el-1"))
        XCTAssertFalse(MCPElicitationManager.canAutoAccept(params))
    }

    // MARK: eventPayload（E1 载荷形态）

    private func objectFields(_ payload: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let fields) = payload else {
            throw MCPConfigurationError("eventPayload must be an object")
        }
        return fields
    }

    /// form 型全字段 + meta 在场（codex :382-385）。
    func testFormPayloadCarriesAllFieldsAndMeta() throws {
        let params = CreateElicitation.Parameters.form(.init(
            message: "Allow tool?",
            requestedSchema: .init(properties: [
                "ok": .object(["type": .string("boolean")]),
            ]),
            _meta: Metadata(additionalFields: [
                "codex.approvalKind": .string("tool_suggestion"),
            ])))
        let payload = try MCPElicitationManager.eventPayload(
            serverName: "docs", publicRequestID: "req-1", params: params)
        let fields = try objectFields(payload)
        XCTAssertEqual(fields["serverName"], .string("docs"))
        XCTAssertEqual(fields["requestId"], .string("req-1"))
        XCTAssertEqual(fields["message"], .string("Allow tool?"))
        XCTAssertEqual(fields["mode"], .string("form"))
        XCTAssertNotNil(fields["requestedSchema"])
        // meta 携带 = fields["_meta"] 映射（lead 件9 review 补充锚点）。
        XCTAssertEqual(fields["meta"],
                       .object(["codex.approvalKind": .string("tool_suggestion")]))
    }

    /// meta 缺失 → 键省略（Option 语义，非必填）。
    func testFormPayloadOmitsAbsentMeta() throws {
        let params = CreateElicitation.Parameters.form(.init(
            message: "Confirm?",
            requestedSchema: .init(properties: [:])))
        let payload = try MCPElicitationManager.eventPayload(
            serverName: "docs", publicRequestID: "req-2", params: params)
        let fields = try objectFields(payload)
        XCTAssertNil(fields["meta"])
        XCTAssertEqual(fields["mode"], .string("form"))
        // SDK RequestSchema 全字段编码（CI 实证）：type 恒在场（默认 object）、
        // properties 恒在场（空表）。
        XCTAssertEqual(fields["requestedSchema"],
                       .object(["type": .string("object"),
                                "properties": .object([:])]))
    }

    /// url 型全字段（codex :396-399 + :404-410 的 E1 形态）。
    func testUrlPayloadCarriesAllFieldsAndMeta() throws {
        let params = CreateElicitation.Parameters.url(.init(
            message: "Open link",
            url: "https://example.com/auth",
            elicitationId: "el-9",
            _meta: Metadata(additionalFields: ["k": .string("v")])))
        let payload = try MCPElicitationManager.eventPayload(
            serverName: "browser", publicRequestID: "req-3", params: params)
        let fields = try objectFields(payload)
        XCTAssertEqual(fields["serverName"], .string("browser"))
        XCTAssertEqual(fields["requestId"], .string("req-3"))
        XCTAssertEqual(fields["message"], .string("Open link"))
        XCTAssertEqual(fields["mode"], .string("url"))
        XCTAssertEqual(fields["url"], .string("https://example.com/auth"))
        XCTAssertEqual(fields["elicitationId"], .string("el-9"))
        XCTAssertEqual(fields["meta"], .object(["k": .string("v")]))
        XCTAssertNil(fields["requestedSchema"], "url 型不携带 requestedSchema")
    }
}
