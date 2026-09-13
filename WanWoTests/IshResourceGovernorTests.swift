//
//  IshResourceGovernorTests.swift
//  WanWoTests
//
//  【M5-A 批 G1 测试 · 资源护栏 Swift 门面】桩内核（HookCommandExecuting
//  注入先例同模式）断言：
//    - 前后台转发：handleDidEnterBackground → begin / handleWillEnter-
//      Foreground → end（幂等由 ObjC 侧保证，转发面不加防重——两次转发
//      两次调用是期望行为）
//    - 喂送遥测：feedOnce 计数/时刻落快照
//    - 定时器启停：start 后短节拍内 feedCount 增长；stop 后归零不再增
//    - start 幂等：双 start 单定时器（stop 后计数冻结证唯一）
//    - 快照镜像：zone/running/footprintMode/stalls 由内核面直读
//  C 层压测（50 命令并发/内核状态机语义）= 真机验收（G2 件），不在本件。
//

import XCTest
@testable import WanWo

/// 桩内核面：全量记录调用 + 可调静态状态（HookPointRunnerTests 的
/// RecordingHookExecutor 同模式）。
private final class SpyResourceKernel: ISHResourceKernelControlling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var feedCount = 0

    // 静态状态（测试直接写；桩自身不做线程化写入）
    var zone: Int32 = 0
    var running = false
    var footprintMode = false
    var stalls: UInt64 = 0

    func beginBackgroundCPUGovernor() {
        lock.lock(); beginCount += 1; lock.unlock()
    }

    func endBackgroundCPUGovernor() {
        lock.lock(); endCount += 1; lock.unlock()
    }

    func feedMemoryStatus() {
        lock.lock(); feedCount += 1; lock.unlock()
    }

    var backgroundCPUGovernorZone: Int32 { zone }
    var isBackgroundCPUGovernorRunning: Bool { running }
    var isMemoryFootprintModeActive: Bool { footprintMode }
    var forkGuardStallCount: UInt64 { stalls }

    func snapshotBeginCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return beginCount
    }

    func snapshotEndCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return endCount
    }

    func snapshotFeedCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return feedCount
    }
}

final class IshResourceGovernorTests: XCTestCase {

    private var kernel: SpyResourceKernel!

    override func setUp() {
        super.setUp()
        kernel = SpyResourceKernel()
    }

    override func tearDown() {
        kernel = nil
        super.tearDown()
    }

    private func makeGovernor(interval: TimeInterval = 0.25) -> IshResourceGovernor {
        IshResourceGovernor(kernel: kernel, feedInterval: interval)
    }

    /// 轮询至条件成立或超时（定时器测试用；与 governor UTILITY 队列异步
    /// 解耦，不做精确节拍断言——节拍值本身由 ObjC governor 模式锚定）。
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // MARK: - 前后台转发

    func testDidEnterBackgroundForwardsToBeginGovernor() {
        let governor = makeGovernor()
        governor.handleDidEnterBackground()
        governor.handleDidEnterBackground()
        // 幂等在 ObjC 侧（ISHKernel.m:1788 begin 早退）——转发面透传两次。
        XCTAssertEqual(kernel.snapshotBeginCount(), 2)
        XCTAssertEqual(kernel.snapshotEndCount(), 0)
    }

    func testForegroundReturnForwardsToEndGovernor() {
        let governor = makeGovernor()
        governor.handleWillEnterForeground()
        XCTAssertEqual(kernel.snapshotEndCount(), 1)
        XCTAssertEqual(kernel.snapshotBeginCount(), 0)
    }

    // MARK: - 喂送遥测

    func testFeedOnceRecordsTelemetry() {
        let governor = makeGovernor()
        XCTAssertFalse(governor.isFeedTimerRunning)

        governor.feedOnce()
        governor.feedOnce()

        XCTAssertEqual(kernel.snapshotFeedCount(), 2)
        let snap = governor.snapshot
        XCTAssertEqual(snap.feedCount, 2)
        XCTAssertNotNil(snap.lastFeedDate)
        XCTAssertFalse(snap.isFeedTimerRunning)
    }

    // MARK: - 定时器启停

    func testStartRunsFeedTimer() {
        let governor = makeGovernor(interval: 0.05)
        governor.start()
        XCTAssertTrue(governor.isFeedTimerRunning)

        let grew = waitUntil { kernel.snapshotFeedCount() >= 3 }
        governor.stop()
        XCTAssertTrue(grew, "start 后应按节拍持续喂送（feedCount≥3）")
        XCTAssertTrue(governor.snapshot.lastFeedDate != nil)
    }

    func testStopHaltsFeedTimer() {
        let governor = makeGovernor(interval: 0.05)
        governor.start()
        XCTAssertTrue(waitUntil { kernel.snapshotFeedCount() >= 1 })
        governor.stop()
        XCTAssertFalse(governor.isFeedTimerRunning)

        let frozenAt = kernel.snapshotFeedCount()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(kernel.snapshotFeedCount(), frozenAt,
                       "stop 后不得再有喂送")
    }

    func testStartIsIdempotent() {
        let governor = makeGovernor(interval: 0.05)
        governor.start()
        governor.start()
        XCTAssertTrue(governor.isFeedTimerRunning)

        // 双 start 只应挂一个定时器：stop 后计数冻结（若起了两个定时器，
        // 幸存者会继续喂）。给足窗口观察。
        XCTAssertTrue(waitUntil { kernel.snapshotFeedCount() >= 1 })
        governor.stop()
        let frozenAt = kernel.snapshotFeedCount()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(kernel.snapshotFeedCount(), frozenAt,
                       "双 start 必须仍是单定时器")
    }

    // MARK: - 快照镜像

    func testSnapshotMirrorsKernelState() {
        let governor = makeGovernor()
        kernel.zone = 2
        kernel.running = true
        kernel.footprintMode = true
        kernel.stalls = 272

        governor.feedOnce()
        let snap = governor.snapshot

        XCTAssertEqual(snap.governorZone, 2)
        XCTAssertTrue(snap.isGovernorRunning)
        XCTAssertTrue(snap.isFootprintModeActive)
        XCTAssertEqual(snap.forkGuardStallCount, 272)
        XCTAssertEqual(snap.feedCount, 1)
        XCTAssertFalse(snap.isFeedTimerRunning)
    }

    func testSnapshotDefaultsBeforeAnyActivity() {
        let governor = makeGovernor()
        let snap = governor.snapshot
        XCTAssertEqual(snap.governorZone, 0)
        XCTAssertFalse(snap.isGovernorRunning)
        XCTAssertFalse(snap.isFootprintModeActive)
        XCTAssertEqual(snap.forkGuardStallCount, 0)
        XCTAssertFalse(snap.isFeedTimerRunning)
        XCTAssertEqual(snap.feedCount, 0)
        XCTAssertNil(snap.lastFeedDate)
    }
}
