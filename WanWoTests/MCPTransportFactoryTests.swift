//
//  MCPTransportFactoryTests.swift
//  WanWoTests
//
//  【M4-A 件12】件2 锚点：非法（非绝对）URL 使 connect 判负——dsh
//  `new URL(config.url)` 对缺 scheme/host 字符串抛 TypeError（transport.ts:46），
//  Swift URL 宽松通过 → 显式 scheme+host 校验 fail closed 同形。
//

import XCTest
@testable import WanWo

final class MCPTransportFactoryTests: XCTestCase {

    private func makeConfig(url: String) -> MCPClientConfig {
        MCPClientConfig(transport: .streamableHTTP(url: url, headers: [:]),
                        serverName: "docs")
    }

    /// 缺 scheme（"example.com/mcp"）→ 抛。
    func testRejectsURLWithoutScheme() {
        XCTAssertThrowsError(try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "example.com/mcp"))) { error in
            XCTAssertEqual(
                String(describing: error),
                "mcp-client(docs): url is not a valid absolute URL")
        }
    }

    /// 缺 host（"https:///path"）→ 抛。
    func testRejectsURLWithoutHost() {
        XCTAssertThrowsError(try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "https:///path")))
    }

    /// 合法绝对 http(s) URL → 产出未连接 transport。
    func testAcceptsAbsoluteHTTPSURL() throws {
        let transport = try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "https://example.com/mcp"))
        XCTAssertFalse(transport.isConnected)
    }

    func testAcceptsAbsoluteHTTPURL() throws {
        _ = try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "http://127.0.0.1:8765/mcp"))
    }
}
