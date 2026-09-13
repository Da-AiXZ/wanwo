//
//  JobTypes.swift
//  WanWo
//
//  【M5-A 批 J1 · 后台作业类型词汇缝】出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/jobs/jobs/src/types.ts（160 行全文）。
//
//  平台差异登记（简报裁定）：
//    - owner 归一：dsh owner = Agent 实例（多 agent，types.ts:57-63/:106-111/
//      :146-149）；WanWo 单宿主 agent → ownerSessionId: String?（围栏语义
//      保留：owned job 仅 ownerSessionId 相同的 caller 可达，unowned 开放）
//    - JobKindMap 声明合并（types.ts:23-26 bash/subagent）：Swift 无声明
//      合并 → 封闭 enum；subagent 不移植（WanWo 无 subagent 生产者）
//    - done: Promise → async throws（"Must not reject; the runtime converts
//      a rejection to `failed`" 语义由 J2 实现侧承接，types.ts:79-84）
//

import Foundation

// MARK: - 生命周期词汇（types.ts:17）

/// 作业生命周期：`running`，可选 `stopping`，然后恰好一个终态。生产者专属
/// 事实放 {@link JobSnapshot.detail}（types.ts:13-16 注释逐字移植）。
public enum JobStatus: String, Equatable, Sendable, CaseIterable {
    case running
    case stopping
    case completed
    case killed
    case failed

    /// 终态判定（invariant.ts:9 TERMINAL_STATUSES 同集合）。
    public var isTerminal: Bool {
        JobInvariants.terminalStatuses.contains(self)
    }
}

// MARK: - 作业种类（types.ts:23-29）

/// 生产者定义的作业种类——注册表把它当不透明 id 命名空间（id 前缀同源）。
/// dsh JobKindMap 经声明合并扩展（bash/subagent）；WanWo 单 agent 形态只做
/// bash——subagent 不移植（简报裁定，登记）。
public enum JobKind: String, Equatable, Sendable, CaseIterable {
    case bash
}

// MARK: - 终态结果（types.ts:32-39）

/// 终态词汇子集（JobStatus 的 completed/killed/failed 三值——生产者经
/// JobHooks.done 供给；dsh 类型字面 'completed' | 'killed' | 'failed'）。
public enum JobOutcomeStatus: String, Equatable, Sendable, CaseIterable {
    case completed
    case killed
    case failed
}

/// 生产者经 JobHooks.done 供给的终态结果（types.ts:32-39）。
public struct JobOutcome: Equatable, Sendable {
    /// 作业如何结束：跑完（completed）/ 被取消（killed）/ 出错（failed）。
    public var status: JobOutcomeStatus
    /// 种类专属细节，渲染进状态行（'exit code: 3'、'max-tokens'）。
    public var detail: String?
    /// 无 readOutput 作业的最终输出；流式作业留空（types.ts:37 注释）。
    public var output: String?

    public init(status: JobOutcomeStatus, detail: String? = nil, output: String? = nil) {
        self.status = status
        self.detail = detail
        self.output = output
    }
}

// MARK: - 生产者声明（types.ts:46-69）

/// 传给 JobRegistry.start 的生产者声明（types.ts:41-45 注释语义：运行时在
/// 调 run 之前 preflight 访问与清理；生产者在 preflight 通过后拥有执行
/// 资源，运行时拥有身份与生命周期状态）。
public struct JobStart: Sendable {
    /// 生产者种类——同时是 id 前缀（`bash`，…）。
    public let kind: JobKind
    /// 面向模型的一行标签（命令本身；委派描述）。
    public let label: String
    /// 可选 UTF-8 字节上限：作用于每份完整面向模型的完成通知或输出读取，
    /// 含 controller 状态元数据（types.ts:50-54）。
    public let outputLimitBytes: Int?
    /// 持有者会话 id（归一裁定：dsh owner Agent 实例 → session id；访问
    /// 按其围栏，owner disposal 取消并 await 作业）。省略 = unowned job，
    /// 在 service disposal 前对任何 caller 开放（types.ts:56-63 语义保留）。
    public let ownerSessionId: String?
    /// preflight 通过后启动工作并同步返回其 hooks。只调一次；抛错则什么
    /// 都不注册，生产者须清理任何已部分启动的资源（types.ts:64-68）。
    /// TS 原文 run() 未标 throws 但 index.ts:78-79 明言 "A throwing starter
    /// leaves nothing registered"——Swift 形态显式 throws。
    public let run: @Sendable () throws -> JobHooks

    public init(kind: JobKind,
                label: String,
                outputLimitBytes: Int? = nil,
                ownerSessionId: String? = nil,
                run: @escaping @Sendable () throws -> JobHooks) {
        self.kind = kind
        self.label = label
        self.outputLimitBytes = outputLimitBytes
        self.ownerSessionId = ownerSessionId
        self.run = run
    }
}

// MARK: - 生产者钩子（types.ts:72-91）

/// 运行时借以控制与观察生产者工作的钩子（types.ts:71-91）。
public struct JobHooks: Sendable {
    /// 请求终止。必须同步、幂等、并最终使 done 结算；抛错向上传播。可选
    /// reason 原样转发（types.ts:73-77 注释逐字）。
    public let cancel: @Sendable (String?) -> Void
    /// 生产者释放完其资源后才结算——不只是工作跑完时。"Must not reject;
    /// the runtime converts a rejection to `failed`"（types.ts:79-84）——
    /// Swift 形态显式 throws，拒绝→failed 的转换归 J2 运行时侧承接。
    public let done: @Sendable () async throws -> JobOutcome
    /// 消费自上次调用以来产出的输出。生产者负责格式化截断与 spill 通知。
    /// 缺省 = 仅终态输出的作业；每个作业只有一条消费游标（types.ts:85-90）。
    public let readOutput: (@Sendable () -> String)?

    public init(cancel: @escaping @Sendable (String?) -> Void,
                done: @escaping @Sendable () async throws -> JobOutcome,
                readOutput: (@Sendable () -> String)? = nil) {
        self.cancel = cancel
        self.done = done
        self.readOutput = readOutput
    }
}

// MARK: - 快照投影（types.ts:94-128）

/// 单个作业的只读投影，可安全交给 listener 与工具——每次调用都是新对象，
/// 绝不是注册表的活状态（types.ts:93-96 注释语义）。
public struct JobSnapshot: Equatable, Sendable {
    /// 注册表签发的 id（`<kind>-N` 正序数）。
    public let id: String
    /// 注册时登记的生产者种类。
    public let kind: JobKind
    /// 生产者供给的一行标签。
    public let label: String
    /// 生产者自有的、面向模型的通知与输出读取字节上限。
    public let outputLimitBytes: Int?
    /// 授权与关联用的持有者会话 id；unowned 作业为 nil（types.ts:106-111，
    /// owner Agent 实例归一为 session id——完成 listener 另经参数收精确
    /// ownerSessionId，见 JobDoneListener）。
    public let ownerSessionId: String?
    /// 当前生命周期状态。
    public let status: JobStatus
    /// 种类专属状态细节，生产者供给后出现（通常在终态）。
    public let detail: String?
    /// 注册时刻（epoch 毫秒）。
    public let startedAt: Int64
    /// 结算时刻（epoch 毫秒）；running/stopping 期间为 nil。
    public let finishedAt: Int64?
    /// kill、read、wait 或 teardown cancel 已上报或已承诺上报终态时为真。
    /// 完成上报方据此抑制冗余通知。teardown 置位是因为 owner/service 被销
    /// 毁后已无读者：否则每个 teardown 层都会为一条通知花一次模型请求
    /// （types.ts:120-127 注释逐字移植）。
    public var reported: Bool

    public init(id: String,
                kind: JobKind,
                label: String,
                outputLimitBytes: Int? = nil,
                ownerSessionId: String? = nil,
                status: JobStatus,
                detail: String? = nil,
                startedAt: Int64,
                finishedAt: Int64? = nil,
                reported: Bool = false) {
        self.id = id
        self.kind = kind
        self.label = label
        self.outputLimitBytes = outputLimitBytes
        self.ownerSessionId = ownerSessionId
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reported = reported
    }
}

// MARK: - 读取结果（types.ts:131-140）

/// JobRegistry.read 返回的输出与读取后状态（types.ts:130）。
public struct JobRead: Equatable, Sendable {
    /// 流式种类：自上次读取以来的消费增量。仅终态输出种类：活着时为空，
    /// 结算后为终态 output（或空）——幂等、永不消费（types.ts:132-137）。
    public let text: String
    /// 读取时刻的作业状态。
    public let snapshot: JobSnapshot

    public init(text: String, snapshot: JobSnapshot) {
        self.text = text
        self.snapshot = snapshot
    }
}

// MARK: - kill 返回词汇（index.ts:120）

/// kill 的两值结果（index.ts:118 "requested for live work, otherwise
/// already-finished"；wire 词汇 'already-finished' 带连字符）。
public enum JobKillResult: String, Equatable, Sendable, CaseIterable {
    case requested
    case alreadyFinished = "already-finished"
}

// MARK: - listener 类型（types.ts:142-160，owner 归一）

/// 完成回调：收到终态快照与 start 时的精确 ownerSessionId（unowned 作业为
/// nil；dsh 的 Agent 实例参数随 owner 归一收 session id）。dsh "Returned
/// promises are observed but not awaited"（types.ts:144-145）——Swift 形态
/// 为同步闭包；需要异步工作的 listener 自行 Task 包裹（J2 负责观察不等待）。
public typealias JobDoneListener = @Sendable (JobSnapshot, String?) -> Void

/// 可见集变更观察回调（types.ts:151-160 注释语义逐字移植）：owner 粒度而
/// 非 job 粒度——变更可能是移除（单作业记录无法表达），且消费者本来就会
/// 重读整个可见集。nil 表示 unowned 作业变更，即每个 caller 的可见集都变了。
public typealias JobsChangedListener = @Sendable (String?) -> Void
