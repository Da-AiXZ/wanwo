//
//  MCPToolExposureBudgetTests.swift
//  WanWoTests
//
//  【C4 测试锚】MCP 工具 spec 字节预算——对拍基准 = codex-rs core/src/
//  mcp_tool_exposure.rs:19-20（常量）/:121-141（逐工具判定）+
//  handlers/mcp.rs:91-93（model_spec_bytes = compact JSON 字节数）。
//  10-design:1051 验收硬条文三条：单工具超 8KB→Hidden / 总量超 64KB→后续
//  Hidden / 边界内不误伤。
//

import XCTest
@testable import WanWo

final class MCPToolExposureBudgetTests: XCTestCase {

    // MARK: modelSpecBytes（codex mcp.rs:91-93 等价面）

    /// 同输入同字节（ERR-026 确定性编码）且与手工 compact JSON 字节数一致。
    func testModelSpecBytesIsDeterministicCompactJSON() {
        let parameters = JSONValue.schemaObject(
            properties: ["mode": .stringSchema(description: "Mode.")],
            required: ["mode"])
        let bytes = MCPToolExposureBudget.modelSpecBytes(
            name: "mcp__calendar__create_event",
            description: "Create a calendar event",
            parameters: parameters)
        XCTAssertEqual(bytes, MCPToolExposureBudget.modelSpecBytes(
            name: "mcp__calendar__create_event",
            description: "Create a calendar event",
            parameters: parameters))
        let expected = "{\"description\":\"Create a calendar event\","
            + "\"name\":\"mcp__calendar__create_event\",\"parameters\":{"
            + "\"additionalProperties\":false,\"properties\":{\"mode\":"
            + "{\"description\":\"Mode.\",\"type\":\"string\"}},"
            + "\"required\":[\"mode\"],\"type\":\"object\"}}"
        XCTAssertEqual(bytes, expected.utf8.count)
    }

    // MARK: 10-design:1051 验收三条

    /// 单工具 spec 超 8KB → Hidden，且不误伤后续小工具（running 不推进）。
    func testOversizedSingleToolIsHidden() {
        let exposures = MCPToolExposureBudget.exposures(forSpecBytes: [
            7_999, 8_001, 100, 64_001])
        XCTAssertEqual(exposures, [.deferred, .hidden, .deferred, .hidden],
                       "超 8KB 单工具 Hidden；后续小工具不受牵连")
    }

    /// 总量超 64KB：放不下的工具 Hidden（codex :126-132 精确语义——next ≤
    /// 64KB 才推进 running，Hidden 工具不占累计面）。
    func testCumulativeOverflowHidesOverflowTools() {
        // 3000 × 21 = 63000 ≤ 64000；第 22 个 next=66000 → Hidden；
        // 第 23 个 next 仍 66000 → Hidden。
        let exposures = MCPToolExposureBudget.exposures(forSpecBytes:
            Array(repeating: 3_000, count: 23))
        XCTAssertEqual(Array(exposures.prefix(21)),
                       Array(repeating: ToolExposure.deferred, count: 21))
        XCTAssertEqual(exposures[21], .hidden)
        XCTAssertEqual(exposures[22], .hidden)
    }

    /// 边界内不误伤：单工具恰 8_000、累计恰 64_000 均压线放行（`<=` 判定）。
    func testBoundaryValuesStayWithinBudget() {
        let exposures = MCPToolExposureBudget.exposures(forSpecBytes: [
            8_000, 56_000])
        XCTAssertEqual(exposures, [.deferred, .deferred],
                       "8_000 单工具与 64_000 累计均为闭边界（codex `next <= MAX`）")
    }

    /// 空输入零输出。
    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertEqual(MCPToolExposureBudget.exposures(forSpecBytes: []), [])
    }

    /// base 可参数化（预算内 exposure 随调用方语义——MCP 工具 = .deferred）。
    func testBaseExposureIsRespected() {
        let exposures = MCPToolExposureBudget.exposures(
            forSpecBytes: [100, 200], base: .deferred)
        XCTAssertEqual(exposures, [.deferred, .deferred])
    }
}
