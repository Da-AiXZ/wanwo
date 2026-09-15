//
//  JobNotifierTests.swift
//  WanWoTests
//
//  【M5-A 批 J4 测试 · 本地通知映射（注入桩）】四面：
//    1. 前台抑制：active → 零投递零授权（先于授权——不空耗弹窗预算）
//    2. 后台触发：content 三元（identifier=job id / title=label / body=通知
//       文本）+ 惰性授权一次
//    3. 授权拒绝：静默跳过（fail open）
//    4. owner 复检：unowned（owner nil）与 reported 不发（AppEnvironment
//       listener 已过滤，notifier 独立调用面同合规——J4 测试锚点）
//  真机面（真 UNUserNotificationCenter 弹窗/覆盖语义、applicationState 实读）
//  不在 CI——真机验收，与 J2/J3 同纪律。
//

import XCTest
@testable import WanWo

// MARK: - 测试夹具

/// 投递/授权记录器（线程安全闭包桩的收集面）。
private final class NotifyLog: @unchecked Sendable {
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

    private func makeSnapshot(label: String = "sleep 30",
                              reported: Bool = false) -> JobSnapshot {
        JobSnapshot(id: "bash-1", kind: .bash, label: label,
                    ownerSessionId: "s1", status: .completed,
                    detail: "exit code: 0", startedAt: 1, finishedAt: 2,
                    reported: reported)
    }

    func testForegroundSuppressed() async {
        // active → 零投递零授权（通知=打扰，inject 已可见——F007 判定钉死）。
        JobNotifier.resetForTests()
        defer { JobNotifier.resetForTests() }
        let log = NotifyLog()
        let notifier = makeNotifier(active: true, authGranted: true, log: log)
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(),
                                      ownerSessionId: "s1",
                                      noticeText: "notice")
        XCTAssertTrue(log.entries.isEmpty, "前台抑制=零投递")
        XCTAssertEqual(log.authRequests, 0, "抑制先于授权（不空耗弹窗预算）")
    }

    func testActiveButMissedInBackgroundNotifies() async {
        // 【真机批 B2 修复回归 2026-09-15】判定方向修复：作业启动后曾进
        // 后台（startedAt < bgAt）→ 结算虽回前台仍发通知。用户实证场景：
        // 切后台后作业完成 → iOS 冻结推迟结算 → 回前台结算时被旧方向
        // 判定（bgAt < startedAt）吞掉，通知始终不来。
        JobNotifier.resetForTests()
        JobNotifier.noteBackgrounded()   // bgAt=now ≫ startedAt(1ms)
        defer { JobNotifier.resetForTests() }
        let log = NotifyLog()
        let notifier = makeNotifier(active: true, authGranted: true, log: log)
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(),
                                      ownerSessionId: "s1",
                                      noticeText: "missed in background")
        XCTAssertEqual(log.entries.count, 1, "启动后进过后台→回前台结算仍发通知")
        XCTAssertEqual(log.authRequests, 1)
    }

    func testBackgroundNotifiesWithContent() async throws {
        let log = NotifyLog()
        let notifier = makeNotifier(active: false, authGranted: true, log: log)
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(),
                                      ownerSessionId: "s1",
                                      noticeText: "background job bash-1 …")
        XCTAssertEqual(log.entries.count, 1)
        let entry = try XCTUnwrap(log.entries.first)
        XCTAssertEqual(entry.identifier, "bash-1", "identifier=job id（同作业覆盖去重）")
        XCTAssertEqual(entry.title, "sleep 30", "title=作业 label")
        XCTAssertEqual(entry.body, "background job bash-1 …", "body=JobCompletionNotice 同文本")
        XCTAssertEqual(log.authRequests, 1, "惰性授权恰一次")
    }

    func testTitleTruncatedAtUtf8Boundary() async {
        let log = NotifyLog()
        let notifier = makeNotifier(active: false, authGranted: true, log: log)
        let longLabel = String(repeating: "命令片段", count: 40)  // 480 字节 > 120
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(label: longLabel),
                                      ownerSessionId: "s1",
                                      noticeText: "x")
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
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(),
                                      ownerSessionId: "s1",
                                      noticeText: "notice")
        XCTAssertTrue(log.entries.isEmpty, "拒绝授权=静默跳过（fail open，登记）")
        XCTAssertEqual(log.authRequests, 1, "请求发生且被拒")
    }

    func testOwnerNilAndReportedSkip() async {
        let log = NotifyLog()
        let notifier = makeNotifier(active: false, authGranted: true, log: log)
        // unowned（owner nil）不发。
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(),
                                      ownerSessionId: nil,
                                      noticeText: "notice")
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.authRequests, 0)
        // reported（已上报）不发。
        await notifier.notifyIfNeeded(snapshot: makeSnapshot(reported: true),
                                      ownerSessionId: "s1",
                                      noticeText: "notice")
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.authRequests, 0)
    }
}
