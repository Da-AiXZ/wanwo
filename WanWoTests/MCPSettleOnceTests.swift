//
//  MCPSettleOnceTests.swift
//  WanWoTests
//
//  【M4-A 件12】件3 锚点：看门狗竞速底座 settle-once 语义（MCPConnection.swift
//  :155-187）——超时路径/先到方获胜的确定性注入（不真等待；CI 时长预算纪律）。
//  件5/件8 的 callToolUncached/requestWithTimeout 复用同一形态。
//

import XCTest
@testable import WanWo

final class MCPSettleOnceTests: XCTestCase {

    /// 先 settle 者获胜：双 settle 只取首个值（:161-173 settled 守卫）。
    func testFirstSettleWins() async {
        let box = MCPSettleOnce<Int>()
        box.settle(1)
        box.settle(2)
        let value = await box.wait()
        XCTAssertEqual(value, 1)
    }

    /// 先 wait 后 settle（挂起方被续体唤醒；确定性：settle 在同任务后续体）。
    func testWaitThenSettle() async {
        let box = MCPSettleOnce<String>()
        let waiter = Task { await box.wait() }
        // 让 waiter 先挂起：确定性注入——wait 内部持锁登记 continuation 前后
        // 无外部门槛，Task.start 与 settle 的次序由「settled 分支即时返回」
        // 兜底（两种次序都得到 "ok"）。
        box.settle("ok")
        let value = await waiter.value
        XCTAssertEqual(value, "ok")
    }

    /// 先 settle 后 wait：即时返回（:178-181 settled 快路径，无挂起窗口）。
    func testSettleThenWaitIsImmediate() async {
        let box = MCPSettleOnce<Result<Int, any Error>>()
        box.settle(.success(7))
        let outcome = await box.wait()
        XCTAssertEqual(try? outcome.get(), 7)
    }

    /// 失败 settle 形态（watchdog 超时路径的错误值注入）。
    func testFailureSettlePropagates() async {
        let box = MCPSettleOnce<Result<Int, any Error>>()
        box.settle(.failure(MCPToolCallTimeoutError(timeoutMs: 30_000)))
        let outcome = await box.wait()
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertEqual(String(describing: error),
                           "mcp-client: tool call timed out after 30000ms")
        }
    }

    /// 多 waiter：全部收到同一首个 settle 值。
    func testMultipleWaitersAllReceiveFirstValue() async {
        let box = MCPSettleOnce<Int>()
        let waiters = (0..<4).map { _ in Task { await box.wait() } }
        box.settle(42)
        box.settle(99)
        for waiter in waiters {
            let value = await waiter.value
            XCTAssertEqual(value, 42)
        }
    }
}
