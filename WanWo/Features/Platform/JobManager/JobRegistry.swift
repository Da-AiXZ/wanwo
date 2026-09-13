//
//  JobRegistry.swift
//  WanWo
//
//  【M5-A 批 J1 · 后台作业抽象注册表缝】出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/jobs/jobs/src/index.ts（179 行全文）——JobRegistry
//  抽象类九方法 + 类级语义注释（:41-60）逐条移植为 Swift doc。
//
//  形态裁定（呈报要点③）：
//    - Swift 无 abstract → 缝由 protocol JobRegistryProtocol 承载；J2 的
//      LocalJobRegistry 实现 protocol（dsh jobs-local 对应）。
//    - 同步语义逐字保留：start/list/get/read/kill/onJobDone/onJobsChanged/
//      attachController 全部同步（唯一 async = wait——Promise 映射）。
//      Swift actor 的隔离方法无法直接 conform 同步 protocol 要求（须
//      nonisolated 即失去状态访问），故 J2 形态 = final class + NSLock
//      （HookPointRunner.swift:53 同款并发先例）；单进程内存 registry
//      临界区毫秒级，actor 无额外收益。若 J2 需要 actor，另议 async 化。
//    - AbortSignal 无直接对应物：Swift wait 的 caller 取消 = Task
//      cancellation（async throws 下 Task.isCancelled 轮询/CheckCancellation），
//      语义等价（"Caller abort rejects only while the job is live"）。
//

import Foundation

// MARK: - 抽象注册表缝（index.ts:62-177）

/// 抽象后台作业注册表缝（dsh `ctx.jobs` 契约）。子类化实现九方法并以插件
/// 装载——一个 context 一份实现（index.ts:35-39 语义：重复装载即抛）。
///
/// 实现必须遵守的语义（index.ts:41-60 注释逐条移植）：
/// - 注册记录比生产者与 controller 纤维活得久。owner 与 service disposal
///   取消在飞工作并 await 合规生产者；teardown cancel 抛错只强置记录为
///   failed。teardown 取消同时把记录标 reported——owner 正被销毁的记录
///   已无读者（index.ts:42-46）。
/// - owned-job 访问按 owner 的 session id 围栏。"Ids are predictable, so
///   authorization — not secrecy — is the boundary"（index.ts:47-48）。
/// - 结算 first-wins：一条终态记录、释放全部 waiter、一轮被包含的 listener
///   通知——即使面对迟到的生产者 outcome。完成通知最后发：记录已提交且
///   结算的每个其他观察者都已看到之后，因为 reporter 可能同步打开一个
///   模型回合（index.ts:49-53）。
/// - start 在无已挂接的 job controller 服务该 spec 的 owner 时拒绝工作，
///   使生产者无法启动 owner 无法收集或停止的工作（index.ts:54-56）。
///   controller 与完成 listener 的挂接是 owner 相对而非进程全局的——
///   WanWo 单层形态（ScopedLayers 不做，J2 需要再补，登记）退化为
///   进程级挂接集合。
/// （J2 增补：Sendable 收紧——ShellTool 等 AgentTool: Sendable 装配面
///   持有注册表存在体，缝协议须 Sendable；LocalJobRegistry 以
///   @unchecked Sendable + NSLock 兑现。）
public protocol JobRegistryProtocol: AnyObject, Sendable {

    /// preflight 访问、校验、owner cleanup 与实现自有的 admission，然后才
    /// 启动并原子注册工作。任何 preflight 拒绝都不留下 job id 或执行资源。
    /// 抛错的 starter 不留下任何已注册物；它返回之后注册不可能失败。结算
    /// 记录 outcome、通知 listener、释放 waiter（index.ts:73-82 注释逐字）。
    /// - Returns: 注册表签发的 `<kind>-N` id。
    /// - Throws: 访问/校验/admission 拒绝，或 starter 本身抛错（不注册）。
    func start(_ spec: JobStart) throws -> String

    /// 按注册序列出 caller-owned 与 unowned 作业，不暴露其他会话的标签
    /// （index.ts:84-90）。非 agent caller（callerSessionId = nil）只见
    /// unowned 作业。
    /// - Returns: 全新快照（绝不返回活注册状态）。
    func list(callerSessionId: String?) -> [JobSnapshot]

    /// 返回非消费性快照，不改变其读取游标或通知状态。对未知或非本会话的
    /// 作业抛错（index.ts:92-99）。
    func get(id: String, callerSessionId: String?) throws -> JobSnapshot

    /// 读取下一段流增量；或结算后的幂等终态输出。终态读取把作业标
    /// reported。对未知或非本会话的作业抛错（index.ts:101-109）。
    /// - Returns: 输出文本与读取后快照。
    func read(id: String, callerSessionId: String?) throws -> JobRead

    /// 请求取消，然后把作业标 stopping 与 reported。生产者抛错原样传播且
    /// 不改变作业状态。对未知或非本会话的作业抛错（index.ts:111-120）。
    /// - Returns: 在飞工作返回 `requested`，否则 `already-finished`。
    @discardableResult
    func kill(id: String, callerSessionId: String?, reason: String?) throws -> JobKillResult

    /// 等结算或超时，不取消作业。caller 取消仅在作业活着时抛；结算之后
    /// 终态快照胜出——本 waiter 被抑制的通知仍会送达（index.ts:122-133
    /// 注释逐字）。对非法、未知或非本会话的输入抛错。
    /// - Parameters:
    ///   - timeoutMs: 正的有限等待上界（毫秒）；超时返回当前快照不抛。
    ///   - callerSessionId: 等待方，按 owner 围栏校验。
    /// - Note: dsh 的可选 AbortSignal 映射为 Swift Task cancellation
    ///   （caller 的 Task 取消仅在其作业 live 时抛 CancellationError；
    ///   结算后终态快照胜出，见上）。
    func wait(id: String, timeoutMs: Int64, callerSessionId: String?) async throws -> JobSnapshot

    /// 注册完成 listener。收到其挂接范围覆盖的 owner 们的结算；每个
    /// listener 被包含（抛错不外泄）、返回不被 await。service disposal 后
    /// 无 listener 运行（index.ts:135-143）。
    /// - Returns: 注销该 listener 的 disposer。
    @discardableResult
    func onJobDone(_ listener: @escaping JobDoneListener) -> () -> Void

    /// 注册可见集变更观察者。它在每次改变 list 返回内容的提交后触发——
    /// 注册、每次 stopping 迁移（含 teardown 在 await 慢生产者之前做的
    /// 那次）、结算、owner-disposal 移除、service disposal 提交的清空——
    /// 观察者重读而非累积增量。这不是 onJobDone 的超集：后者在 first-wins
    /// 语义下送达终态记录（job controller 可耦合通知投递），本回调不承载
    /// 投递语义也不标 reported。listener 被包含且永不被 await
    /// （index.ts:146-167 注释逐字移植）。
    /// - Returns: 注销该观察者的 disposer。
    @discardableResult
    func onJobsChanged(_ listener: @escaping JobsChangedListener) -> () -> Void

    /// 挂接可读取与停止作业的 effect 范围 controller。它服务其挂接范围
    /// 覆盖的 owner，start 拒绝无已挂接 controller 服务的 owner
    /// （index.ts:169-176）。WanWo 单层形态：controller 服务全部 owner。
    /// - Parameter name: 诊断标签；重名互相独立。
    /// - Returns: 摘除该 controller 的 disposer。
    @discardableResult
    func attachController(name: String) -> () -> Void
}

// MARK: - 快照不变量（invariant.ts 全量移植）

/// 包级后台作业快照不变量（invariant.ts:1-57 全量移植；纯函数形态——
/// dsh 的 cordis 插件安装面/Invariants 服务不移植，校验结果以失败清单
/// 返回，供本件测试与 J2/J3 运行期复用）。
public enum JobInvariants {

    /// 终态集合（invariant.ts:9 TERMINAL_STATUSES）。
    public static let terminalStatuses: Set<JobStatus> = [.completed, .killed, .failed]

    /// 校验单个注册表快照的跨字段关系（invariant.ts:17-43 逐分支移植）。
    /// - Parameters:
    ///   - snapshot: 待校验快照。
    ///   - completionOwnerSessionId: 该作业结算通知所带的精确 owner
    ///     （unowned 作业为 nil）——dsh 的 `owner?.id` 归一为 session id。
    /// - Returns: 失败清单（空 = 全过）。文案与 invariant.ts fail() 逐条
    ///   对应（id 细节英文保留，便于与上游日志对读）。
    public static func validate(snapshot: JobSnapshot,
                                completionOwnerSessionId: String?) -> [String] {
        var failures: [String] = []
        func fail(_ message: String) { failures.append(message) }

        // invariant.ts:19-24：id 必须是 `<kind>-` 前缀 + 正序数。
        // （kind 为空串的分支在 Swift 不可能——JobKind 是非空 rawValue 的
        // 封闭 enum，登记为类型系统差异。）
        let prefix = "\(snapshot.kind.rawValue)-"
        let ordinalText = String(snapshot.id.dropFirst(prefix.count))
        let ordinal = Int(ordinalText)
        if !snapshot.id.hasPrefix(prefix) || ordinal == nil || ordinal! < 1 {
            fail("job snapshot id \"\(snapshot.id)\" must be \"\(prefix)\" followed by a positive ordinal")
        }

        // invariant.ts:25：label 非空。
        if snapshot.label.isEmpty {
            fail("job \"\(snapshot.id)\" label must be non-empty")
        }

        // invariant.ts:26-28：startedAt 非负 epoch 整数。
        // （Number.isSafeInteger 的上界分支在 Swift Int64 语义下不存在。）
        if snapshot.startedAt < 0 {
            fail("job \"\(snapshot.id)\" startedAt must be a non-negative epoch integer")
        }

        // invariant.ts:30-33：finishedAt 恰在终态时存在（一一对应）。
        let terminal = terminalStatuses.contains(snapshot.status)
        if terminal != (snapshot.finishedAt != nil) {
            fail("job \"\(snapshot.id)\" finishedAt must be present exactly for a terminal status")
        }

        // invariant.ts:34-37：finishedAt 不得早于 startedAt。
        if let finishedAt = snapshot.finishedAt, finishedAt < snapshot.startedAt {
            fail("job \"\(snapshot.id)\" finishedAt must be an epoch integer no earlier than startedAt")
        }

        // invariant.ts:39-42：ownerSession 与结算 owner 一致。
        if snapshot.ownerSessionId != completionOwnerSessionId {
            fail("job \"\(snapshot.id)\" ownerSession does not match its completion owner")
        }

        return failures
    }
}
