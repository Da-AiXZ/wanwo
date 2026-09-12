//
//  MCPTransportFactoryTests.swift
//  WanWoTests
//
//  【M4-A 件12】件2 锚点：非法（非绝对）URL 使 connect 判负——dsh
//  `new URL(config.url)` 对缺 scheme/host 字符串抛 TypeError（transport.ts:46），
//  Swift URL 宽松通过 → 显式 scheme+host 校验 fail closed 同形。
//  【场景2 根因修复】makeTransport 签名补 fsContext（10-design:647 兑现）：
//  http 变体不消费该值（校验先于 stdio 分支），测试用 0 占位。
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
            for: makeConfig(url: "example.com/mcp"), fsContext: 0)) { error in
            XCTAssertEqual(
                String(describing: error),
                "mcp-client(docs): url is not a valid absolute URL")
        }
    }

    /// 缺 host（"https:///path"）→ 抛。
    func testRejectsURLWithoutHost() {
        XCTAssertThrowsError(try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "https:///path"), fsContext: 0))
    }

    /// 合法绝对 http(s) URL → 构造成功（HTTPClientTransport 无公开连接
    /// 状态面——isConnected 为 SDK private，CI 工具链实证；构造不抛即锚点）。
    func testAcceptsAbsoluteHTTPSURL() throws {
        _ = try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "https://example.com/mcp"), fsContext: 0)
    }

    func testAcceptsAbsoluteHTTPURL() throws {
        _ = try MCPTransportFactory.makeTransport(
            for: makeConfig(url: "http://127.0.0.1:8765/mcp"), fsContext: 0)
    }
}
