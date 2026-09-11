//
//  MCPServerStoreTests.swift
//  WanWoTests
//
//  【M4-B B8 · 测试回归】两块登记兑现：
//    · B1 登记①：args/env 非 String 项丢弃+警告（MCPServerStore.entry
//      读侧「忽略+警告不静默」纪律=startupTimeoutSeconds 先例 :165 同款
//      ——本测试锁丢弃语义；警告为 log 面，语义锚=类型收窄结果）。
//    · B5 startupTimeoutMs 传递路径断言（lead 派单）：http 恒默认
//      connectWatchdogTimeoutMs 30s；stdio=(entry.startupTimeoutSeconds ??
//      60) * 1000（MCPServerStore.swift clientConfig stdio 分支）。
//  竞态类确定性注入纪律：文件 fixture 逐测独立临时目录（UUID 后缀），
//  不真读 Keychain/不真 spawn。
//

import XCTest
@testable import WanWo

final class MCPServerStoreTests: XCTestCase {

    // MARK: fixture（逐测独立临时目录）

    /// 写 servers.json → 建 store（@MainActor 调用点经调用方法上 actor）。
    /// @MainActor：MCPServerStore init 是 @MainActor 隔离（B9 首跑编译红自修）。
    @MainActor
    private func makeFixture(_ json: String) throws -> (store: MCPServerStore,
                                                        url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanwo-mcp-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("servers.json")
        try Data(json.utf8).write(to: url)
        return (MCPServerStore(fileURL: url), url)
    }

    // MARK: B1 登记① —— args/env 非 String 项丢弃（警告 log 面）

    /// 类型收窄语义：非 String args 项/非 String env 值逐项丢弃，合法项
    /// 保留（entry() 解析层收窄——MCPServerStore.swift args/env 循环）。
    @MainActor
    func testArgsEnvNonStringEntriesAreDropped() throws {
        let json = #"""
        {"mcpServers":{"py":{"command":"/usr/bin/python3",
            "args":[1,"ok",true,"also-ok"],
            "env":{"GOOD":"1","BAD":123,"ALSO_GOOD":"2"},
            "startupTimeoutSeconds":120}}}
        """#
        let (store, _) = try makeFixture(json)
        let entry = try XCTUnwrap(store.servers.first { $0.id == "py" })
        XCTAssertEqual(entry.args, ["ok", "also-ok"],
                       "non-string args entries must be dropped")
        XCTAssertEqual(entry.env, ["GOOD": "1", "ALSO_GOOD": "2"],
                       "non-string env values must be dropped")
    }

    /// args/env 键在场但整体形态错（非数组/非对象）→ 整键忽略、条目仍有效
    /// （command 在场即 stdio——形态判别不受影响）。
    @MainActor
    func testArgsEnvWrongContainerTypeIgnored() throws {
        let json = #"""
        {"mcpServers":{"py":{"command":"x","args":"not-array","env":"not-object"}}}
        """#
        let (store, _) = try makeFixture(json)
        let entry = try XCTUnwrap(store.servers.first { $0.id == "py" })
        XCTAssertTrue(entry.args.isEmpty)
        XCTAssertTrue(entry.env.isEmpty)
        XCTAssertTrue(entry.isStdio)
    }

    // MARK: B5 —— startupTimeoutMs 传递路径

    /// stdio：entry.startupTimeoutSeconds 在场 → *1000 直传
    ///（clientConfig stdio 分支 `(entry.startupTimeoutSeconds ?? 60) * 1000`）。
    @MainActor
    func testStdioStartupTimeoutMsUsesEntryValue() throws {
        let json = #"""
        {"mcpServers":{"py":{"command":"/usr/bin/python3","startupTimeoutSeconds":120}}}
        """#
        let (store, _) = try makeFixture(json)
        let entry = try XCTUnwrap(store.servers.first { $0.id == "py" })
        let config = try store.clientConfig(for: entry)
        guard case .stdio = config.transport else {
            return XCTFail("expected stdio transport")
        }
        XCTAssertEqual(config.startupTimeoutMs, 120_000)
    }

    /// stdio：字段缺省 → 60s 默认（MCPConstants.defaultStartupTimeoutSeconds）。
    @MainActor
    func testStdioStartupTimeoutMsDefaultsTo60() throws {
        let json = #"""
        {"mcpServers":{"py":{"command":"/usr/bin/python3"}}}
        """#
        let (store, _) = try makeFixture(json)
        let entry = try XCTUnwrap(store.servers.first { $0.id == "py" })
        let config = try store.clientConfig(for: entry)
        XCTAssertEqual(config.startupTimeoutMs,
                       MCPConstants.defaultStartupTimeoutSeconds * 1000)
    }

    /// stdio：非法值（0/901 越界）→ 读侧忽略回默认（resolvedStartupTimeout
    /// 语义——非法值忽略+警告，不静默吞进越界值）。
    @MainActor
    func testStdioInvalidStartupTimeoutFallsBackToDefault() throws {
        let json = #"""
        {"mcpServers":{"a":{"command":"x","startupTimeoutSeconds":0},
                       "b":{"command":"y","startupTimeoutSeconds":901}}}
        """#
        let (store, _) = try makeFixture(json)
        for id in ["a", "b"] {
            let entry = try XCTUnwrap(store.servers.first { $0.id == id })
            let config = try store.clientConfig(for: entry)
            XCTAssertEqual(config.startupTimeoutMs,
                           MCPConstants.defaultStartupTimeoutSeconds * 1000,
                           "\(id): invalid value must fall back to default")
        }
    }

    /// http：恒默认 connectWatchdogTimeoutMs 30s（stdio 分支不经过——
    /// http 条目 startupTimeoutMs 不受任何条目字段影响）。
    @MainActor
    func testHttpStartupTimeoutMsConstant() throws {
        let json = #"""
        {"mcpServers":{"web":{"url":"https://example.com/mcp"}}}
        """#
        let (store, _) = try makeFixture(json)
        let entry = try XCTUnwrap(store.servers.first { $0.id == "web" })
        let config = try store.clientConfig(for: entry)
        XCTAssertEqual(config.startupTimeoutMs, MCPConstants.connectWatchdogTimeoutMs)
        XCTAssertEqual(config.startupTimeoutMs, 30_000)
    }
}
