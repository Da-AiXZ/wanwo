//
//  JobRegistrySeamTests.swift
//  WanWoTests
//
//  【M5-A 批 J1 测试 · 后台作业缝】三面：
//    1. 类型词汇编译面：五态/终态三值/kill 两值 wire rawValue 逐字
//       （types.ts:17/:34/index.ts:120）+ isTerminal 映射
//    2. 不变量函数全分支（invariant.ts:17-43 逐分支对拍）：合法快照零失败
//       / id 前缀错 / 序数错 / label 空 / startedAt 负 / terminal↔finishedAt
//       一一对应 / finishedAt<startedAt / ownerSession 不一致 / 多失败累积
//    3. protocol 形态约束：九方法签名的编译锚（J2 LocalJobRegistry 将实现
//       的缝——桩 conform + 调用一遍证明签名可用）
//

import XCTest
@testable import WanWo

// MARK: - 桩实现（仅证 protocol 签名编译锚；J2 真 impl 不在本件）

/// 九方法最小 conform 桩：全部 preflight 拒绝（抛/空表）——缝测试只关心
/// 签名可调，不关心行为（行为语义属 J2 jobs-local）。
private final class StubJobRegistry: JobRegistryProtocol, @unchecked Sendable {
    func start(_ spec: JobStart) throws -> String { "bash-1" }
    func list(callerSessionId: String?) -> [JobSnapshot] { [] }
    func get(id: String, callerSessionId: String?) throws -> JobSnapshot {
        throw JobRegistrySeamError.stub
    }
    func read(id: String, callerSessionId: String?) throws -> JobRead {
        throw JobRegistrySeamError.stub
    }
    func kill(id: String, callerSessionId: String?, reason: String?) throws -> JobKillResult {
        .requested
    }
    func wait(id: String, timeoutMs: Int64, callerSessionId: String?) async throws -> JobSnapshot {
        throw JobRegistrySeamError.stub
    }
    func onJobDone(_ listener: @escaping JobDoneListener) -> () -> Void { {} }
    func onJobsChanged(_ listener: @escaping JobsChangedListener) -> () -> Void { {} }
    func attachController(name: String) -> () -> Void { {} }
}

private enum JobRegistrySeamError: Error { case stub }

final class JobRegistrySeamTests: XCTestCase {

    // MARK: - 类型词汇（wire rawValue 逐字）

    func testJobStatusWireVocabulary() {
        // types.ts:17 五态字面量。
        XCTAssertEqual(
            Set(JobStatus.allCases.map(\.rawValue)),
            ["running", "stopping", "completed", "killed", "failed"])
        // invariant.ts:9 终态集合。
        XCTAssertEqual(
            Set(JobStatus.allCases.filter(\.isTerminal).map(\.rawValue)),
            ["completed", "killed", "failed"])
        XCTAssertFalse(JobStatus.running.isTerminal)
        XCTAssertFalse(JobStatus.stopping.isTerminal)
    }

    func testJobOutcomeStatusWireVocabulary() {
        // types.ts:34 终态三值字面量。
        XCTAssertEqual(
            Set(JobOutcomeStatus.allCases.map(\.rawValue)),
            ["completed", "killed", "failed"])
    }

    func testJobKillResultWireVocabulary() {
        // index.ts:120 两值字面量（'already-finished' 带连字符）。
        XCTAssertEqual(JobKillResult.requested.rawValue, "requested")
        XCTAssertEqual(JobKillResult.alreadyFinished.rawValue, "already-finished")
    }

    func testJobKindVocabulary() {
        // types.ts:23-26 JobKindMap——subagent 不移植（登记），bash 保留。
        XCTAssertEqual(JobKind.bash.rawValue, "bash")
    }

    // MARK: - 快照构造缺省

    func testSnapshotDefaultsMatchTypesTs() {
        // types.ts:97-128——outputLimitBytes/ownerSessionId/detail/
        // finishedAt 缺省为 nil，reported 缺省 false。
        let snap = JobSnapshot(id: "bash-1", kind: .bash, label: "ls",
                               status: .running, startedAt: 100)
        XCTAssertNil(snap.outputLimitBytes)
        XCTAssertNil(snap.ownerSessionId)
        XCTAssertNil(snap.detail)
        XCTAssertNil(snap.finishedAt)
        XCTAssertFalse(snap.reported)
    }

    // MARK: - 不变量全分支（invariant.ts:17-43 逐分支）

    /// 合法快照基底（可逐字段变异构造负例）。
    private func makeValidSnapshot(
        id: String = "bash-1",
        kind: JobKind = .bash,
        label: String = "sleep 10",
        ownerSessionId: String? = "s1",
        status: JobStatus = .running,
        startedAt: Int64 = 1_000,
        finishedAt: Int64? = nil,
        completionOwner: String?? = "s1"   // 双层 Optional：nil=unowned 断言
    ) -> (snapshot: JobSnapshot, completionOwner: String?) {
        let snapshot = JobSnapshot(id: id, kind: kind, label: label,
                                   ownerSessionId: ownerSessionId,
                                   status: status,
                                   startedAt: startedAt,
                                   finishedAt: finishedAt)
        return (snapshot, completionOwner)
    }

    func testValidRunningOwnedSnapshotPasses() {
        let (snap, owner) = makeValidSnapshot()
        XCTAssertEqual(JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner), [])
    }

    func testValidTerminalOwnedSnapshotPasses() {
        let (snap, owner) = makeValidSnapshot(status: .completed, finishedAt: 2_000)
        XCTAssertEqual(JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner), [])
    }

    func testValidUnownedSnapshotPasses() {
        // unowned：ownerSession 与 completion owner 同为 nil。
        let (snap, owner) = makeValidSnapshot(ownerSessionId: nil, completionOwner: nil)
        XCTAssertEqual(JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner), [])
    }

    func testIdWrongPrefixFails() {
        // invariant.ts:21-24：id 不以 "<kind>-" 开头。
        let (snap, owner) = makeValidSnapshot(id: "subagent-1")
        let failures = JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("must be \"bash-\" followed by a positive ordinal"))
    }

    func testIdOrdinalZeroFails() {
        // invariant.ts:22 ordinal < 1。
        let (snap, owner) = makeValidSnapshot(id: "bash-0")
        XCTAssertEqual(
            JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner).count, 1)
    }

    func testIdOrdinalNonNumericFails() {
        let (snap, owner) = makeValidSnapshot(id: "bash-abc")
        XCTAssertEqual(
            JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner).count, 1)
    }

    func testEmptyLabelFails() {
        // invariant.ts:25。
        let (snap, owner) = makeValidSnapshot(label: "")
        let failures = JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("label must be non-empty"))
    }

    func testNegativeStartedAtFails() {
        // invariant.ts:26-28。
        let (snap, owner) = makeValidSnapshot(startedAt: -1)
        let failures = JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("startedAt must be a non-negative epoch integer"))
    }

    func testTerminalWithoutFinishedAtFails() {
        // invariant.ts:30-33：terminal 但无 finishedAt。
        let (snap, owner) = makeValidSnapshot(status: .failed)
        let failures = JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("finishedAt must be present exactly for a terminal status"))
    }

    func testFinishedAtWithoutTerminalStatusFails() {
        // invariant.ts:30-33 反向：running 却带 finishedAt。
        let (snap, owner) = makeValidSnapshot(finishedAt: 2_000)
        XCTAssertEqual(
            JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner).count, 1)
    }

    func testStoppingWithFinishedAtFails() {
        // stopping 也是非终态——带 finishedAt 同样违例。
        let (snap, owner) = makeValidSnapshot(status: .stopping, finishedAt: 2_000)
        XCTAssertEqual(
            JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner).count, 1)
    }

    func testFinishedAtBeforeStartedAtFails() {
        // invariant.ts:34-37。
        let (snap, owner) = makeValidSnapshot(status: .killed,
                                              startedAt: 5_000, finishedAt: 4_999)
        let failures = JobInvariants.validate(snapshot: snap, completionOwnerSessionId: owner)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("no earlier than startedAt"))
    }

    func testOwnerSessionMismatchFails() {
        // invariant.ts:39-42：快照 ownerSession 与结算 owner 不一致。
        let (snap, _) = makeValidSnapshot()
        let failures = JobInvariants.validate(snapshot: snap,
                                              completionOwnerSessionId: "s2")
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("ownerSession does not match its completion owner"))
    }

    func testOwnedSnapshotMustMatchNilCompletionOwner() {
        // 归一边界：owned 快照配 nil 结算 owner（unowned 通知）也违例。
        let (snap, _) = makeValidSnapshot()
        XCTAssertEqual(
            JobInvariants.validate(snapshot: snap, completionOwnerSessionId: nil).count, 1)
    }

    func testMultipleFailuresAccumulate() {
        // 多分支同时破：id 前缀 + label 空 + startedAt 负 + terminal 缺
        // finishedAt + owner 不一致 = 5 条（invariant.ts fail 累积语义）。
        let (snap, _) = makeValidSnapshot(id: "x-1", label: "",
                                          status: .completed, startedAt: -5)
        let failures = JobInvariants.validate(snapshot: snap,
                                              completionOwnerSessionId: "other")
        XCTAssertEqual(failures.count, 5)
    }

    // MARK: - protocol 形态约束（J2 签名编译锚）

    func testProtocolShapeIsCallable() async throws {
        let registry: JobRegistryProtocol = StubJobRegistry()

        // start 返回 `<kind>-N` 形态 id（桩值）。
        let id = try registry.start(JobStart(kind: .bash, label: "ls", run: {
            JobHooks(cancel: { _ in }, done: { JobOutcome(status: .completed) })
        }))
        XCTAssertEqual(id, "bash-1")

        // list / get / read / kill 同步签名可调。
        XCTAssertEqual(registry.list(callerSessionId: nil), [])
        XCTAssertThrowsError(try registry.get(id: "bash-1", callerSessionId: nil))
        XCTAssertThrowsError(try registry.read(id: "bash-1", callerSessionId: nil))
        XCTAssertEqual(try registry.kill(id: "bash-1", callerSessionId: nil,
                                         reason: "test"), .requested)

        // listener/observer/controller 挂接返回 disposer（可调用不崩）。
        registry.onJobDone { _, _ in }()
        registry.onJobsChanged { _ in }()
        registry.attachController(name: "chat")

        // wait 是唯一 async throws 面。
        XCTAssertThrowsError(try await registry.wait(id: "bash-1", timeoutMs: 10,
                                                     callerSessionId: nil))
    }
}
