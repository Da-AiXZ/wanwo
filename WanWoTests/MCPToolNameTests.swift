//
//  MCPToolNameTests.swift
//  WanWoTests
//
//  【M4-A 件12】件4 锚点：命名契约 publicToolName（MCPToolBridge.swift，
//  dsh tools.ts:47-57/98-118 直译）——干净名原样/非法字符替换+hash/超长
//  截断 keep=51+"_"+12hex=64/同规范化不同 identity 哈希不同/确定性；
//  ToolRegistry tryRegister 冲突抛 ToolRegistryConflictError + disposer
//  幂等注销（ToolRegistry.swift:174-192）。
//

import XCTest
@testable import WanWo

final class MCPToolNameTests: XCTestCase {

    // MARK: 干净名：原样、不加 hash（tools.ts:115 快速路径）

    func testCleanNameIsPassThrough() {
        XCTAssertEqual(publicToolName(serverName: "docs", rawName: "search"),
                       "mcp__docs__search")
        XCTAssertEqual(publicToolName(serverName: "a_b", rawName: "c_d"),
                       "mcp__a_b__c_d")   // '-' '_' 均合法字符
    }

    /// 恰好 64 字符的干净名仍走快速路径（上限含等号）。
    func testCleanNameAtExactLimitStaysClean() {
        let server = String(repeating: "s", count: 32)
        let raw = String(repeating: "r", count: 25)
        let name = publicToolName(serverName: server, rawName: raw)
        XCTAssertEqual(name, "mcp__\(server)__\(raw)")
        XCTAssertEqual(name.count, 64)
    }

    // MARK: 非法字符：替换 + SHA256 身份哈希（tools.ts:114/116-117）

    func testIllegalCharsAreReplacedAndHashAppended() {
        let name = publicToolName(serverName: "my server", rawName: "file.read")
        // 替换后的规范化前缀保留；哈希追加使不同 MCP 身份不坍缩。
        XCTAssertTrue(name.hasPrefix("mcp__my_server__file_read_"),
                      "unexpected: \(name)")
        XCTAssertEqual(name.count, "mcp__my_server__file_read".count + 1 + 12)
        let suffix = String(name.suffix(12))
        XCTAssertTrue(suffix.allSatisfy { "0123456789abcdef".contains($0) },
                      "hash suffix must be lowercase hex: \(suffix)")
    }

    /// 干净名 65 字符：规范化无损但超长 → 有损分支（截断+hash）。
    func testOverlongCleanNameIsTruncatedToSixtyFour() {
        let server = String(repeating: "s", count: 32)
        let raw = String(repeating: "r", count: 26)
        let name = publicToolName(serverName: server, rawName: raw)
        XCTAssertEqual(name.count, 64)
        // keep = 64 - 12 - 1 = 51（tools.ts:117）。两侧显式 String 归一
        // （Substring 字面量推断歧义——CI 工具链实证）。
        XCTAssertEqual(String(name.prefix(51)),
                       String("mcp__\(server)__\(raw)".prefix(51)))
        XCTAssertEqual(name[..<name.index(name.startIndex, offsetBy: 52)].last, "_")
    }

    /// 任意超长 raw：总长恒 64、结构 51+"_"+12hex。
    func testHugeRawNameProducesStructuredName() {
        let name = publicToolName(serverName: "docs", rawName: String(repeating: "a", count: 200))
        XCTAssertEqual(name.count, 64)
        XCTAssertEqual(name.prefix(51), String("mcp__docs__" + String(repeating: "a", count: 200)).prefix(51))
        XCTAssertTrue(name.suffix(12).allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: 同规范化、不同身份：哈希不同（tools.ts:56 契约）

    func testSameNormalizationDifferentIdentityYieldDifferentNames() {
        let a = publicToolName(serverName: "a b", rawName: "c d")     // → mcp__a_b__c_d + hash
        let b = publicToolName(serverName: "a.b", rawName: "c.d")     // → mcp__a_b__c_d + hash
        XCTAssertTrue(a.hasPrefix("mcp__a_b__c_d_"))
        XCTAssertTrue(b.hasPrefix("mcp__a_b__c_d_"))
        XCTAssertNotEqual(a, b, "distinct identities must never collapse")
    }

    /// 有损名与同名干净名不冲突（hash 防坍缩的另一形态）。
    func testLossyNameDoesNotCollideWithCleanName() {
        let clean = publicToolName(serverName: "a_b", rawName: "c_d")
        let lossy = publicToolName(serverName: "a b", rawName: "c d")
        XCTAssertEqual(clean, "mcp__a_b__c_d")
        XCTAssertNotEqual(clean, lossy)
    }

    // MARK: 确定性（同输入同输出）

    func testDeterministic() {
        let first = publicToolName(serverName: "srv-1", rawName: "do thing")
        let second = publicToolName(serverName: "srv-1", rawName: "do thing")
        XCTAssertEqual(first, second)
    }

    // MARK: ToolRegistry 冲突与注销器（ToolRegistry.swift:174-192）

    private struct StubTool: AgentTool {
        let name: String
        let description = "stub"
        let parameters: JSONValue = .object([:])
        func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws
            -> ToolOutput { .success("ok") }
    }

    func testTryRegisterConflictThrows() throws {
        let registry = ToolRegistry()
        _ = try registry.tryRegister(StubTool(name: "t1"))
        XCTAssertThrowsError(try registry.tryRegister(StubTool(name: "t1"))) { error in
            guard let conflict = error as? ToolRegistryConflictError else {
                return XCTFail("expected ToolRegistryConflictError, got \(error)")
            }
            XCTAssertEqual(conflict.name, "t1")
            XCTAssertEqual(String(describing: conflict),
                           "tool \"t1\" is already registered")
        }
        // 冲突后原注册仍在（可捕获路径不改既有注册集）。
        XCTAssertNotNil(registry.get("t1"))
    }

    func testDisposerIsIdempotentUnregister() throws {
        let registry = ToolRegistry()
        let disposer = try registry.tryRegister(StubTool(name: "t2"))
        XCTAssertNotNil(registry.get("t2"))
        disposer()
        XCTAssertNil(registry.get("t2"))
        disposer()  // 二次调用无副作用（幂等）
        XCTAssertNil(registry.get("t2"))
    }
}
