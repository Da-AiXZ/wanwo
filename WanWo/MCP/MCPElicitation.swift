//
//  MCPElicitation.swift
//  WanWo
//
//  【M4-A 件9 · elicitation 决策链】参照物=codex 源码（gap3 笔记仅作索引，
//  语义以源码为准——件8 教训）：
//    · codex-mcp/src/elicitation.rs:201-459 make_sender 八步决策链 1:1：
//      ①auto_deny :214-220 ②meta approval_kind=tool_suggestion :222-233
//      ③authority/profile 缺失 :235-256 ④strict_auto_review :258-306
//      ⑤空表单自动接受 :308-319（can_auto_accept_elicitation :483-496）
//      ⑥full-access 表单上浮 :321-341（WanWo 无 full-access 配置面→省略，
//      呈报）⑦政策拒绝 :342-349（elicitation_is_rejected_by_policy :472-479）
//      ⑧公共 ID+事件+oneshot 等待 :363-455；
//    · mcp_approval_meta.rs:4-13 策略键逐字（codex_approval_kind/
//      tool_suggestion/codex_strict_auto_review/approvals_reviewer/auto_review）；
//    · rmcp-client/src/rmcp_client.rs:184-268——ElicitationPauseState
//      （enter 计数 :198-205/Guard Drop 递减 :216-222）+ active_time_timeout
//      （:224-268 活跃时间扣减：暂停进入时 remaining-=elapsed、归零即超时；
//      测试锚点 :1596 active_time_timeout_pauses_while_elicitation_is_pending）；
//    · rmcp-client/src/elicitation_client_service.rs:93-105——拦截面：进入
//      暂停区→send_elicitation（WanWo=SDK withElicitationHandler 包暂停守卫）；
//    · PendingElicitationRequest Drop :106-116——悬空请求清理（Swift=defer
//      removeIfPresent+取消路径 resume CancellationError→SDK internal_error
//      回 server=codex oneshot 关闭路径同向）。
//  SDK 0.12.1 面（上游 tag 取证）：Client.withElicitationHandler（Client.swift
//  :826-843，actor 方法，connect 前注册）+ Capabilities.Elicitation（:100-121，
//  form 默认在 capability、url 需显式）+ CreateElicitation.Parameters{form/url,
//  _meta: Metadata?}/Result{action, content, _meta}。
//  平台适配（汇报逐项呈报）：OpenAI 私有扩展 elicitation 不移植（codex 私有
//  方法面）；reviewer/自动评审机制不移植（WanWo 无评审器——strict_auto_review
//  恒走 :269-271 无 reviewer 拒绝文案，fail closed）；full-access 上浮省略；
//  per-server permission profile 省略（WanWo 单一政策面）；ElicitationLifecycle
//  省略（WanWo 无宿主注册消费方）；E1 事件投影 logOnly（呈现归 M4-B/M9 UI）。
//

import Foundation
import MCP

// MARK: - 策略键（codex mcp_approval_meta.rs 逐字）

private enum MCPElicitationMetaKeys {
    static let approvalKindKey = "codex_approval_kind"          // :4
    static let approvalKindToolSuggestion = "tool_suggestion"   // :6
    static let strictAutoReviewKey = "codex_strict_auto_review" // :9
    static let approvalsReviewerKey = "approvals_reviewer"      // :13
    static let reviewerStampAutoReview = "auto_review"          // elicitation.rs:296
}

/// strict_auto_review 无评审器的固定拒绝文案（elicitation.rs:44 逐字）。
private let strictAutoReviewDeclineMessage = "Automated review of this operation " +
    "failed. Do not proceed without asking the user for explicit approval."

// MARK: - E1 事件注册（词汇新增走已批扩展通道）

/// extensionEvent kind（lead 派单指定：mcp/elicitation）。
enum MCPElicitationEvents {
    static let kind = "mcp/elicitation"

    /// 进程级一次注册（AttachmentStore.registrationOnce 同款纪律）；重名
    /// fatal（注册表 fail loud）。
    static let registrationOnce: Void = {
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: kind,
            requiredFields: [
                ExtensionFieldSchema("serverName", .string),
                ExtensionFieldSchema("requestId", .string),
                ExtensionFieldSchema("mode", .string,
                                     allowedValues: [.string("form"), .string("url")]),
                ExtensionFieldSchema("message", .string),
            ],
            // logOnly：决策链审计面；聊天流呈现归 M4-B/M9 UI 批次（呈报）。
            projection: .logOnly,
            // 非配对：响应走 router.resolve 程序化通道（呈报——响应侧审计
            // 事件与配对清理随 UI 批次落地）。
            pairing: .none))
    }()
}

// MARK: - 活跃时间暂停（rmcp_client.rs:184-268 移植）

/// 暂停状态（codex ElicitationPauseState 1:1）：计数>0 即暂停态；状态迁移
/// 以 AsyncStream 广播（tokio watch::channel 的 Swift 对应物——订阅者另读
/// isPaused 快照校正初值，迁移丢失由循环顶部重读兜底）。全部可变状态由
/// NSLock 独占（@unchecked=锁护纪律登记）。
final class MCPElicitationPauseState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var pausedNow = false
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    init() {}

    /// 当前是否暂停（订阅者初值快照；codex borrow_and_update 对应）。
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedNow
    }

    /// 进入暂停区（codex enter :198-205：0→1 迁移广播 true）。
    func enter() -> MCPElicitationPauseGuard {
        lock.lock()
        activeCount += 1
        if activeCount == 1, !pausedNow {
            pausedNow = true
            broadcastLocked(paused: true)
        }
        lock.unlock()
        return MCPElicitationPauseGuard(state: self)
    }

    /// 退出（codex Guard Drop :216-222：1→0 迁移广播 false；由 Guard
    /// deinit 驱动=Rust Drop 的 Swift 对应物）。
    fileprivate func leave() {
        lock.lock()
        activeCount -= 1
        if activeCount == 0, pausedNow {
            pausedNow = false
            broadcastLocked(paused: false)
        }
        lock.unlock()
    }

    /// 订阅状态迁移流（codex subscribe :207-209；watch::Receiver 的 Swift
    /// 对应物——每次迁移 yield 一次，流不主动 finish，生命周期由订阅侧
    /// 释放经 onTermination 收口）。
    func subscribe() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id)
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    private func broadcastLocked(paused: Bool) {
        // 值投递给所有存活订阅者（watch notify 对应）；不移除注册——旧值/
        // 迟到值由订阅者重读 isPaused 快照兜底（文件头注纪律）。
        for continuation in continuations.values {
            continuation.yield(paused)
        }
    }
}

/// 暂停守卫（codex ElicitationPauseGuard 1:1；deinit=Drop）。
final class MCPElicitationPauseGuard: @unchecked Sendable {
    private let state: MCPElicitationPauseState

    fileprivate init(state: MCPElicitationPauseState) {
        self.state = state
    }

    deinit {
        state.leave()
    }
}

enum MCPElicitationPause {

    /// codex active_time_timeout（rmcp_client.rs:224-268）的 Swift 移植：
    /// 活跃时间预算——暂停期间不扣减。operation 与 clock 竞速，先到者裁决；
    /// - Returns: operation 完成值；预算耗尽=nil。
    static func activeTimeTimeout<T: Sendable>(
        _ duration: Duration,
        pauseState: MCPElicitationPauseState,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: Outcome<T>.self) { group in
            group.addTask { .completed(await operation()) }
            group.addTask { .expired(await runClock(duration: duration, pauseState: pauseState)) }
            let first = await group.next() ?? .expired(true)
            group.cancelAll()
            _ = await group.next()
            if case .completed(let value) = first { return value }
            return nil
        }
    }

    private enum Outcome<T: Sendable> {
        case completed(T)
        case expired(Bool)
    }

    /// clock 半边：true=预算耗尽；false=流端（codex changed() is_err →
    /// 按剩余预算纯等待 :240-242/:256-257 对应）。
    private static func runClock(duration: Duration,
                                 pauseState: MCPElicitationPauseState) async -> Bool {
        var remaining = duration
        var iterator = pauseState.subscribe().makeAsyncIterator()
        var paused = pauseState.isPaused
        while true {
            if paused {                                                     // :236-247
                guard await iterator.next() != nil else {                   // 流端
                    try? await Task.sleep(for: remaining)                   // :241
                    return true
                }
                paused = pauseState.isPaused
                continue
            }
            let start = ContinuousClock.now
            // sleep(remaining) 与 pause 迁移竞速（tokio::select! 对应）。
            let expired = await withTaskGroup(of: Bool?.self) { group -> Bool in
                group.addTask { [remaining] in
                    try? await Task.sleep(for: remaining)
                    return true                                             // :252-254
                }
                group.addTask {
                    _ = await iterator.next()
                    return nil                                              // :255
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                _ = await group.next()
                return first == true
            }
            if expired { return true }
            let elapsed = ContinuousClock.now - start
            if pauseState.isPaused {                                        // :259
                remaining = remaining - elapsed
                if remaining <= .zero { return true }                       // :261-263
            }
        }
    }
}

// MARK: - 公共请求 ID（elicitation.rs:42/:371-374；前缀适配 WANWO）

/// 自生成公共令牌（不复制 server 请求 ID——跨 runtime/重连不碰撞，
/// elicitation.rs:89-93 注释语义；前缀平台适配）。
final class MCPElicitationRequestIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    init() {}

    func nextID() -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = "wanwo-mcp-elicitation-\(next)"
        next += 1
        return id
    }
}

// MARK: - 路由器（elicitation.rs:89-152 ElicitationRequestRouter 1:1）

/// 公共令牌→pending responder 精确路由。线程安全（NSLock=StdMutex 对应，
/// @unchecked=锁护纪律登记）。
final class MCPElicitationRouter: @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<CreateElicitation.Result, any Error>
    }

    private let lock = NSLock()
    private var pending: [String: Pending] = [:]        // 键=publicRequestId
    private var autoDenyNow = false
    private var fullAccessFormInputNow = false

    init() {}

    // codex auto_deny 开关（:119-125）。
    var autoDeny: Bool {
        get { lock.lock(); defer { lock.unlock() }; return autoDenyNow }
        set { lock.lock(); autoDenyNow = newValue; lock.unlock() }
    }

    // codex full_access_form_input_enabled（:127-134；WanWo 恒 false=省略步⑥）。
    var fullAccessFormInputEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fullAccessFormInputNow }
        set { lock.lock(); fullAccessFormInputNow = newValue; lock.unlock() }
    }

    /// 登记 pending（调用方持续 await；取消经 cancelPending 唤醒）。
    func insert(publicRequestID: String,
                continuation: CheckedContinuation<CreateElicitation.Result, any Error>) {
        lock.lock()
        pending[publicRequestID] = Pending(continuation: continuation)
        lock.unlock()
    }

    /// codex resolve（:136-151）：精确移除并投递；未命中=false（"not found"）。
    @discardableResult
    func resolve(publicRequestID: String,
                 response: CreateElicitation.Result) -> Bool {
        lock.lock()
        guard let waiter = pending.removeValue(forKey: publicRequestID) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        waiter.continuation.resume(returning: response)
        return true
    }

    /// PendingElicitationRequest.Drop（:106-116）+ 取消路径：移除并以
    /// CancellationError 唤醒（handler 抛穿→SDK internal_error 回 server=
    /// codex oneshot 关闭同向）。
    func cancelPending(publicRequestID: String) {
        lock.lock()
        let waiter = pending.removeValue(forKey: publicRequestID)
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - 决策链缝

/// 事件汇（E1 extensionEvent 写侧；装配点接 SessionWriter——payload 已过
/// 注册 schema 校验的形状）。
typealias MCPElicitationEventEmitter = @Sendable (_ payload: JSONValue) async -> Void

/// 决策链注入面（codex ElicitationAuthority :154-159 的缝化）：
///   · policyProvider——approval_policy 读取（authority 热读 :248 对应）；
///   · isPromptAutoApproved——mcp_permission_prompt_is_auto_approved 的
///     WanWo 数据源（权限三档装配缝；默认档=false=恒问人）。
protocol MCPElicitationAuthority: Sendable {
    func approvalPolicy() async -> ApprovalPolicy
    func isPromptAutoApproved(serverName: String) async -> Bool
}

/// 连接层安装缝（件3 connectGeneration 消费；nil=不声明 elicitation 能力
/// ——fail closed，件5 imageProjector 同款模式）。
protocol MCPElicitationHandling: Sendable {
    func handle(serverName: String,
                params: CreateElicitation.Parameters) async throws -> CreateElicitation.Result
}

// MARK: - 决策链管理器（elicitation.rs:162-459 ElicitationRequestManager）

/// 八步决策链（make_sender 闭包体的 Swift 直译；步骤编号见文件头注）。
final class MCPElicitationManager: MCPElicitationHandling, @unchecked Sendable {

    private let router: MCPElicitationRouter
    private let authority: any MCPElicitationAuthority
    private let eventEmitter: MCPElicitationEventEmitter?
    private let requestIDs = MCPElicitationRequestIDs()
    private let pauseState = MCPElicitationPauseState()

    /// - Parameters:
    ///   - router: pending 路由（呈现层经 resolve 投递用户响应）。
    ///   - authority: 政策/自动批准读取缝。
    ///   - eventEmitter: E1 事件汇（nil=步⑧首检拒绝 :363-369 对应）。
    init(router: MCPElicitationRouter,
         authority: any MCPElicitationAuthority,
         eventEmitter: MCPElicitationEventEmitter?) {
        MCPElicitationEvents.registrationOnce
        self.router = router
        self.authority = authority
        self.eventEmitter = eventEmitter
    }

    /// 暂停状态（连接层操作超时的活跃时间扣减源；装配点接入）。
    var pauses: MCPElicitationPauseState { pauseState }

    /// 拒绝应答（codex Decline 三连 :215-219 等的合成器）。
    private static func decline(_ content: [String: MCP.Value]? = nil,
                                meta: MCP.Metadata? = nil) -> CreateElicitation.Result {
        CreateElicitation.Result(action: .decline, content: content, _meta: meta)
    }

    /// strict_auto_review 固定拒绝（:462-470）：Decline+_meta{message}。
    private static func strictAutoReviewDecline() -> CreateElicitation.Result {
        let meta = MCP.Metadata(additionalFields: [
            "message": .string(strictAutoReviewDeclineMessage)])
        return decline(meta: meta)
    }

    /// 决策链入口（SDK elicitation handler 直达；暂停区=elicitation_client_
    /// service.rs:100 对应——整个决策+用户等待期间连接操作超时暂停）。
    func handle(serverName: String,
                params: CreateElicitation.Parameters) async throws -> CreateElicitation.Result {
        let pause = pauseState.enter()                                    // :100
        defer { _ = pause }                                               // Guard 释放=Drop
        return try await decide(serverName: serverName, params: params)
    }

    /// 八步决策链（elicitation.rs:214-455 直译；每步源码行号随注）。
    private func decide(serverName: String,
                        params: CreateElicitation.Parameters) async throws -> CreateElicitation.Result {
        // ① auto_deny（:214-220）。
        if router.autoDeny {
            return Self.decline()
        }

        // ② 借 elicitation 夹带工具推荐 → 拒（:222-233）。
        if metaString(params, MCPElicitationMetaKeys.approvalKindKey)
            == MCPElicitationMetaKeys.approvalKindToolSuggestion {
            return Self.decline()
        }

        // ③ authority 缺失→拒（:235-242）。per-server permission profile
        //    门（:249-256）WanWo 无对应概念——结构性省略（呈报）。
        let policy = await authority.approvalPolicy()

        // ④ strict_auto_review（:258-306）：WanWo 无 reviewer 机制——
        //    true 路径恒落 :269-271「无评审器」固定拒绝（fail closed 1:1）。
        switch metaValue(params, MCPElicitationMetaKeys.strictAutoReviewKey) {
        case .bool(true):
            return Self.strictAutoReviewDecline()
        case .bool(false), nil:
            break                                                         // :304
        case .some:
            return Self.strictAutoReviewDecline()                         // :305
        }

        // ⑤ 空表单自动接受（:308-319 + can_auto_accept_elicitation :483-496）。
        let autoApproved = await authority.isPromptAutoApproved(serverName: serverName)
        if autoApproved, Self.canAutoAccept(params) {
            return CreateElicitation.Result(action: .accept,
                                            content: [:])                 // json!({}) 对应
        }

        // ⑥ full-access 表单上浮（:321-341）：WanWo 无 full-access 配置面
        //    ——结构性省略（呈报）；⑦的 reviewer 子步（:351-360）同（无评审器）。

        // ⑦ 政策拒绝（:342-349 + :472-479）：never→true、ask→false。
        if policy == .never {
            return Self.decline()
        }

        // ⑧ 事件汇缺失→拒（:363-369）；公共 ID 自生成（:371-374）；登记
        //    pending（:430-441）；发事件；await oneshot（:454-455）。
        guard let eventEmitter else {
            return Self.decline()
        }
        let publicRequestID = requestIDs.nextID()
        let payload = try Self.eventPayload(serverName: serverName,
                                            publicRequestID: publicRequestID,
                                            params: params)
        do {
            return try await withTaskCancellationHandler {
                try await Self.awaitUserResponse(router: router,
                                                 emitter: eventEmitter,
                                                 payload: payload,
                                                 publicRequestID: publicRequestID)
            } onCancel: {
                router.cancelPending(publicRequestID: publicRequestID)
            }
        }
    }

    /// ⑧等待半边：登记 pending（:430-441）→发事件（:442-453）→await
    /// oneshot（:454-455）；scope 退出（含取消后恢复）即清理 pending
    /// （PendingElicitationRequest.Drop :106-116 对应）。
    ///
    /// 顺序纪律：登记先于发事件（codex :430→:442 同序）——Swift 无「同步
    /// 登记→异步发射→继续 await」单原语，事件投递起独立 Task 与等待并行
    /// （平台适配，呈报）；登记后 Task.isCancelled 自愈检查封闭「onCancel
    /// 先于 insert 到达」的竞态窗口（取消早到→cancelPending 落空→insert 后
    /// 无人唤醒=永久悬挂；codex 无此窗口=await 点取消语义，呈报登记）。
    private static func awaitUserResponse(router: MCPElicitationRouter,
                                          emitter: MCPElicitationEventEmitter,
                                          payload: JSONValue,
                                          publicRequestID: String) async throws -> CreateElicitation.Result {
        defer { router.cancelPending(publicRequestID: publicRequestID) }  // Drop 对应
        Task { await emitter(payload) }                                   // :442-453
        return try await withCheckedThrowingContinuation { continuation in
            router.insert(publicRequestID: publicRequestID, continuation: continuation)
            if Task.isCancelled {
                // 取消在登记前到达的自愈（见上注——竞态窗口封闭）。
                router.cancelPending(publicRequestID: publicRequestID)
            }
        }
    }

    // MARK: meta 读取（SDK Metadata → codex meta() 对应）

    private func metaValue(_ params: CreateElicitation.Parameters,
                           _ key: String) -> JSONValue? {
        switch params {
        case .form(let form): return form._meta?.fields[key].map { JSONValue($0) }
        case .url(let url): return url._meta?.fields[key].map { JSONValue($0) }
        }
    }

    private func metaString(_ params: CreateElicitation.Parameters,
                            _ key: String) -> String? {
        if case .string(let value)? = metaValue(params, key) { return value }
        return nil
    }

    /// can_auto_accept_elicitation（:483-496 1:1）：仅标准 MCP form 且
    /// properties 为空（纯确认型）；url/其他一律 false。
    static func canAutoAccept(_ params: CreateElicitation.Parameters) -> Bool {
        if case .form(let form) = params {
            return form.requestedSchema.properties.isEmpty
        }
        return false
    }

    // MARK: 事件载荷（codex ElicitationRequest :376-429 的 E1 形态）

    /// Form/Url 两型（codex :404-410 第三 Mcp 变体=模式缺省归 form，SDK 解码
    /// 已保证）；OpenAI 私有扩展不移植（呈报）。
    static func eventPayload(serverName: String,
                             publicRequestID: String,
                             params: CreateElicitation.Parameters) throws -> JSONValue {
        let data = try JSONEncoder().encode(params)
        let detail = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let fields) = detail else {
            throw MCPConfigurationError(
                "mcp-client: elicitation parameters must encode to an object")
        }
        var payload: [String: JSONValue] = [
            "serverName": .string(serverName),
            "requestId": .string(publicRequestID),
            "message": fields["message"] ?? .string(""),
        ]
        if case .url(let url) = params {
            payload["mode"] = .string("url")
            payload["url"] = fields["url"] ?? .string("")
            payload["elicitationId"] = fields["elicitationId"] ?? .string("")
        } else {
            payload["mode"] = .string("form")
            payload["requestedSchema"] = fields["requestedSchema"] ?? .object([:])
        }
        return .object(payload)
    }
}

// MARK: - Value→JSONValue 局部桥（Metadata 字段读取用）

private extension JSONValue {
    init(_ value: MCP.Value) {
        if let converted = try? JSONValue.bridges(value) {
            self = converted
        } else {
            self = .null
        }
    }

    private static func bridges(_ value: MCP.Value) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
