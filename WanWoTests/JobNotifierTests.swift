//
//  JobNotifierTests.swift
//  WanWoTests
//
//  【真机批 B4 重写】通知语义重定义（作业级 → 回合级）：notifyTurnCompleted
//  三态覆盖（前台不通知 / 后台投递 / 授权拒绝静默）+ UTF-8 标题截断保留。
//

import XCTest
@testable import WanWo

/// 通知投递桩（记录 identifier/title/body 与授权请求次数）。
final class NotifyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(identifier: String, title: String, body: String)] = []
    private var _authRequests = 0

    var entries: [(identifier: String, title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    var authRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return _authRequests
    }

    func recordAuth() {
        lock.lock(); _authRequests += 1; lock.unlock()
    }

    func record(identifier: String, title: String, body: String) {
        lock.lock(); _entries.append((identifier, title, body)); lock.unlock()
    }
}

final class JobNotifierTests: XCTestCase {

    private func makeNotifier(active: Bool, authGranted: Bool,
                              log: NotifyLog) -> JobNotifier {
        var notifier = JobNotifier()
        notifier.isAppActive = { active }
        notifier.requestAuthorization = {
            log.recordAuth()
            return authGranted
        }
        notifier.addNotification = { identifier, title, body in
            log.record(identifier: identifier, title: title, body: body)
        }
        return notifier
    }

    func testForegroundNoNotify() async {
        // active → 零投递零授权（用户在场，不打扰——B4 裁定）。
        let log = NotifyLog()
        let notifier = makeNotifier(active: true, authGranted: true, log: log)
        await notifier.notifyTurnCompleted(sessionId: "s1", taskLabel: "后台任务")
        XCTAssertTrue(log.entries.isEmpty, "前台=零投递")
        XCTAssertEqual(log.authRequests, 0, "不空耗授权弹窗")
    }

    func testBackgroundTurnCompletedNotifies() async {
        // 后台回合完成 → 投递"任务完成，回来验收"。
        let log = NotifyLog()
        let notifier = makeNotifier(active: false, authGranted: true, log: log)
        await notifier.notifyTurnCompleted(sessionId: "s1", taskLabel: "后台任务")
        XCTAssertEqual(log.entries.count, 1)
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.identifier, "s1", "identifier=sessionId（同会话覆盖去重）")
        XCTAssertEqual(entry.title, "后台任务", "title=任务摘要")
        XCTAssertEqual(entry.body, "任务完成，回来验收。")
        XCTAssertEqual(log.authRequests, 1, "惰性授权恰一次")
    }

    func testTitleTruncatedAtUtf8Boundary() async {
        let log = NotifyLog()
        let notifier = makeNotifier(active: false, authGranted: true, log: log)
        let longLabel = String(repeating: "命令片段", count: 40)  // 480 字节 > 120
        await notifier.notifyTurnCompleted(sessionId: "s1", taskLabel: longLabel)
        XCTAssertEqual(log.entries.count, 1)
        // title 截断复用 J3 retainHead（UTF-8 边界保留）。
        XCTAssertEqual(log.entries[0].title,
                       retainHead(longLabel, maxBytes: JobNotifier.titleMaxBytes))
        XCTAssertLessThanOrEqual(log.entries[0].title.utf8.count,
                                 JobNotifier.titleMaxBytes)
    }

    func testAuthorizationDeniedSilent() async {
        let log = NotifyLog()
        let notifier = makeNotifier(active: false, authGranted: false, log: log)
        await notifier.notifyTurnCompleted(sessionId: "s1", taskLabel: "后台任务")
        XCTAssertTrue(log.entries.isEmpty, "拒绝授权=静默跳过（fail open，登记）")
        XCTAssertEqual(log.authRequests, 1, "请求发生且被拒")
    }
}
