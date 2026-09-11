//
//  MCPConfigTests.swift
//  WanWoTests
//
//  【M4-A 件12】件1 锚点：serverName 形态（index.ts:38
//  ^[A-Za-z0-9_-]{1,32}$）/defaults 四元组（connection.ts:40-45）/
//  resolve 四条错误路径文案逐字（connection.ts:76-87）/未知 reconnect 键
//  加载即报（connection.ts:66-70「每个键都要再判」）。
//

import XCTest
@testable import WanWo

final class MCPConfigTests: XCTestCase {

    // MARK: serverName 形态（index.ts:38）

    func testServerNameBoundaries() {
        XCTAssertTrue(MCPClientConfig.isValidServerName("a"))            // 1 字符下界
        XCTAssertTrue(MCPClientConfig.isValidServerName(String(repeating: "a", count: 32)))  // 32 上界
        XCTAssertFalse(MCPClientConfig.isValidServerName(String(repeating: "a", count: 33))) // 33 越界
        XCTAssertFalse(MCPClientConfig.isValidServerName(""))             // 空
        XCTAssertFalse(MCPClientConfig.isValidServerName("a.b"))          // 非法字符 '.'
        XCTAssertFalse(MCPClientConfig.isValidServerName("服务器"))        // 非 ASCII
        XCTAssertTrue(MCPClientConfig.isValidServerName("A-z_9"))         // 全部合法字符族
    }

    // MARK: RECONNECT_DEFAULTS 四元组（connection.ts:40-45）

    func testReconnectDefaults() {
        let d = MCPReconnectConfig.defaults
        XCTAssertEqual(d.enabled, true)
        XCTAssertEqual(d.initialDelayMs, 500)
        XCTAssertEqual(d.maxDelayMs, 30_000)
        XCTAssertEqual(d.maxAttempts, 10)
    }

    /// resolve 全默认（nil config）= 四元组原样。
    func testResolveAllDefaults() throws {
        let policy = try MCPReconnectResolver.resolve(nil, path: "p")
        XCTAssertEqual(policy, MCPReconnectPolicy(enabled: true, initialDelayMs: 500,
                                                  maxDelayMs: 30_000, maxAttempts: 10))
    }

    // MARK: resolve 四条错误路径（文案逐字，connection.ts:76-87）

    private func resolveError(_ configure: (inout MCPReconnectConfig) -> Void) -> String {
        var config = MCPReconnectConfig()
        configure(&config)
        do {
            _ = try MCPReconnectResolver.resolve(config, path: "p")
            return "<no error>"
        } catch {
            return String(describing: error)
        }
    }

    func testResolveInitialDelayErrors() {
        XCTAssertEqual(
            resolveError { $0.initialDelayMs = 0 },
            "p.initialDelayMs must be a positive finite number no greater than 2147483647")
        XCTAssertEqual(
            resolveError { $0.initialDelayMs = MCPConstants.maxTimerDelayMs + 1 },
            "p.initialDelayMs must be a positive finite number no greater than 2147483647")
    }

    func testResolveMaxDelayError() {
        XCTAssertEqual(
            resolveError { $0.maxDelayMs = -1 },
            "p.maxDelayMs must be a positive finite number no greater than 2147483647")
    }

    func testResolveDelayOrderError() {
        XCTAssertEqual(
            resolveError { $0.initialDelayMs = 40_000; $0.maxDelayMs = 30_000 },
            "p.initialDelayMs must be less than or equal to maxDelayMs")
    }

    func testResolveMaxAttemptsError() {
        XCTAssertEqual(
            resolveError { $0.maxAttempts = 0 },
            "p.maxAttempts must be a positive integer")
    }

    // MARK: 未知 reconnect 键=配置错误（connection.ts:66-70）

    func testUnknownReconnectKeyIsRejected() throws {
        let json = #"{"enabled":true,"bogusOption":1}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(MCPReconnectConfig.self, from: data)) {
            error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("is not a reconnect option"),
                          "unexpected message: \(context.debugDescription)")
        }
    }

    /// 已知键全解析（显式值原样保留）。
    func testKnownKeysParse() throws {
        let json = #"{"enabled":false,"initialDelayMs":100,"maxDelayMs":200,"maxAttempts":3}"#
        let config = try JSONDecoder().decode(
            MCPReconnectConfig.self, from: XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(config.enabled, false)
        XCTAssertEqual(config.initialDelayMs, 100)
        XCTAssertEqual(config.maxDelayMs, 200)
        XCTAssertEqual(config.maxAttempts, 3)
    }
}
