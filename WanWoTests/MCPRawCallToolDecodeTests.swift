//
//  MCPRawCallToolDecodeTests.swift
//  WanWoTests
//
//  【M4-A 件12】件5 锚点：宽松 result 解码（MCPToolExecutor.swift
//  RawCallTool.Result 自定义 Codable，dsh tools.ts:59
//  RawCallToolResultSchema z.record 宽松语义）——键缺失 nil vs 显式 null
//  → Value.null 的区分（decodeLoose contains+decode 组合）、isError===true
//  严格判定（null→nil 不抛）、legacy toolResult 键存在性 hasToolResult、
//  非 object 顶层抛（container(keyedBy:) 即抛=z.record 校验 1:1）。
//

import XCTest
import MCP
@testable import WanWo

final class MCPRawCallToolDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> RawCallTool.Result {
        try JSONDecoder().decode(
            RawCallTool.Result.self,
            from: XCTUnwrap(json.data(using: .utf8)))
    }

    // MARK: 键缺失 = nil（decodeLoose guard contains）

    func testMissingKeysDecodeToNil() throws {
        let result = try decode("{}")
        XCTAssertNil(result.content)
        XCTAssertNil(result.structuredContent)
        XCTAssertNil(result.isError)
        XCTAssertFalse(result.hasToolResult)
        XCTAssertNil(result.toolResult)
    }

    // MARK: 显式 null = Value.null（与缺失区分——dsh 语义核心锚点）

    func testExplicitNullStructuredContentIsPreserved() throws {
        let result = try decode(#"{"structuredContent":null}"#)
        XCTAssertEqual(result.structuredContent, .null)
    }

    func testExplicitNullContentIsPreserved() throws {
        let result = try decode(#"{"content":null}"#)
        XCTAssertEqual(result.content, .null)
    }

    /// 'toolResult' in result 对显式 null 为 true（dsh :327 键存在性语义）。
    func testExplicitNullToolResultKeepsKeyPresence() throws {
        let result = try decode(#"{"toolResult":null}"#)
        XCTAssertTrue(result.hasToolResult)
        XCTAssertEqual(result.toolResult, .null)
    }

    // MARK: isError 严格判定（dsh :329/:345 === true；null→不抛）

    func testIsErrorTrueIsDecoded() throws {
        let result = try decode(#"{"isError":true}"#)
        XCTAssertEqual(result.isError, true)
    }

    func testIsErrorFalseAndNullDecodeToNonThrowing() throws {
        XCTAssertEqual(try decode(#"{"isError":false}"#).isError, false)
        XCTAssertNil(try decode(#"{"isError":null}"#).isError)
    }

    // MARK: legacy toolResult（dsh :325）

    func testLegacyToolResultObject() throws {
        let result = try decode(#"{"toolResult":{"value":42}}"#)
        XCTAssertTrue(result.hasToolResult)
        XCTAssertEqual(result.toolResult,
                       .object(["value": .int(42)]))
    }

    // MARK: content 数组原样保留（宽松：非校验）

    func testContentArrayPreserved() throws {
        let result = try decode(
            #"{"content":[{"type":"text","text":"hi"}]}"#)
        XCTAssertEqual(result.content,
                       .array([.object(["type": .string("text"),
                                        "text": .string("hi")])]))
    }

    // MARK: 非 object 顶层抛（z.record 校验 1:1）

    func testNonObjectTopLevelThrows() {
        XCTAssertThrowsError(try decode("[1,2,3]"))
        XCTAssertThrowsError(try decode("42"))
        XCTAssertThrowsError(try decode("\"str\""))
        XCTAssertThrowsError(try decode("null"))
    }
}
