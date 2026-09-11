//
//  MCPConnection.swift
//  WanWo
//
//  【M4-A 件3 · 连接监督】dsh connection.ts:98-352 startConnection 全量
//  语义移植：世代模型（新 Client+transport = 一个世代）、有界指数退避
//  重连、同步串行链、5s 世代关闭竞速、稳定窗口预算重置、耗尽即注销
//  （fail closed）。
//
//  两项已批裁决的平台落地：
//  ①裁决①（请求失败驱动 generationDown）：Swift transport（Transport 协议，
//    swift-sdk-refs/Transport.swift:6-20）无 onclose 回调——dsh connection.ts:248
//    的 `generation.onclose` 信号源不存在。断线感知改由「请求失败」驱动：
//    connect/enqueueSync 失败走 catch 路径（与 dsh 同构），已建立世代上的
//    请求失败由上层经 reportRequestFailure 转入 generationDown。已知偏差
//    （登记）：SSE 断流不冒泡 → 断线感知延迟到下一次请求发生；无正确性
//    影响，仅感知延迟。dsh onclose 自带 transport 关闭，Swift 需主动
//    disconnect（fire-and-forget，见 generationDown）。
//  ②裁决②（连接看门狗 30s）：Swift SDK 0.12.1 的 connect 内 initialize
//    挂起无内建超时且不响应取消（#256 关联）——connectWithWatchdog 以
//    settle-once 结果箱 + 独立 watchdog Task 实现；正式语义定义见
//    MCPConstants.connectWatchdogTimeoutMs 与件3 汇报。
//
//  并发形态说明（dsh 单线程事件循环 → Swift 结构化并发，逐点对拍见汇报）：
//  - dsh 正确性依赖 await 后的 isCurrent 守卫而非事件循环原子性，故监督器
//    用 final class + NSLock 短临界区（状态读改写进锁、副作用出锁），
//    与 dsh 的可推演性等价；
//  - reconnectTimer → Task.sleep（Task 不保持进程存活，unref 语义无对应物）；
//  - Promise.withResolvers → MCPGenerationCloseSignal（多消费者广播 +
//    可取消等待者，taskgroup 竞速防泄漏的必要件）；
//  - syncChain Promise 链 → MCPSerialTaskChain（链尾吞错、drain 排空）；
//  - `2 ** (n-1)` → 迭代封顶计算（防 Int 溢出，数学等价：
//    min(maxDelay, initial·2^(n-1))）。
//

import Foundation
import MCP

// MARK: - 世代关闭信号（connection.ts:242/248-254 的 close promise）

/// dsh `Promise.withResolvers()` 的 closed promise + onclose 观察位：
/// - `finish()` = dsh `closed.resolve()`（connection.ts:250），广播且幂等；
/// - `isClosed` = dsh `closeObserved` / `hasClosed()`（connection.ts:244-245）；
/// - `wait()` = dsh `await closed.promise`，支持多消费者（promise 语义）
///   并响应任务取消——dsh promise await 不响应取消，此处的取消响应是
///   waitForClose 任务组防泄漏的必要件（平台适配，汇报登记）。
final class MCPGenerationCloseSignal: @unchecked Sendable {

    private let lock = NSLock()
    private var waiters: [ObjectIdentifier: WaiterSlot] = [:]
    /// dsh closeObserved（connection.ts:244）。
    private(set) var isClosed = false

    /// 关闭广播（dsh closed.resolve 1:1）：置位并唤醒全部等待者；重复调用
    /// 无效果（幂等，dsh promise resolve 语义）。
    func finish() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let slots = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for slot in slots { slot.resume(observed: true) }
    }

    /// 等待关闭：返回 true = 观察到关闭；false = 等待被取消。
    func wait() async -> Bool {
        let slot = WaiterSlot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // attach 返回 false = finish/cancel 先到，slot 内部已 resume；
                // 结果统一从 slot.result 读回（覆盖先到取消与先到关闭两分支）。
                _ = slot.attach(continuation)
                if slot.attached {
                    lock.lock()
                    waiters[ObjectIdentifier(slot)] = slot
                    lock.unlock()
                }
            }
            lock.lock()
            waiters[ObjectIdentifier(slot)] = nil
            lock.unlock()
            return slot.result
        } onCancel: {
            slot.cancel()
        }
    }

    /// 单个等待者的可取消挂起点：关闭→resume(true)；取消→resume(false)。
    /// 取消与注册的竞态（onCancel 先于 attach）由 cancelRequested 标志桥接。
    private final class WaiterSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false
        private var observed = false
        private var cancelRequested = false
        /// 供调用方判断是否需要登记进 waiters 表（false=已终结，未挂起）。
        var attached = false
        /// 恢复时的观察结果（true=关闭）。
        var result: Bool { lock.lock(); defer { lock.unlock() }; return observed }

        /// 返回 true = 已登记等待；false = 已终结（continuation 已被 resume）。
        func attach(_ c: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished || cancelRequested {
                c.resume()
                return false
            }
            continuation = c
            attached = true
            return true
        }

        func cancel() {
            lock.lock()
            let c = continuation
            continuation = nil
            if finished {
                lock.unlock()
                return
            }
            finished = true
            observed = false
            lock.unlock()
            c?.resume()
        }

        func resume(observed value: Bool) {
            lock.lock()
            let c = continuation
            continuation = nil
            if finished {
                lock.unlock()
                return
            }
            finished = true
            observed = value
            lock.unlock()
            c?.resume()
        }
    }
}

// MARK: - 一次性结果箱（看门狗竞速，裁决②）

/// settle-once 结果箱：首个 settle 获胜，其余调用无效果。主路径只
/// await wait()（挂起在 continuation 上，5s/30s 内必有 settle 方，
/// 有界）；与 taskgroup 竞速的区别在于兼容「挂起不响应取消」的一侧
/// （connect 的 initialize continuation），避免组退出被卡。
/// internal：件5 的 callToolUncached 超时竞速复用同一形态（dsh
/// RequestOptions.timeout 的 Swift 侧无内建对应物）。
final class MCPSettleOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var value: Value?
    private var settled = false

    func settle(_ v: Value) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        value = v
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: v)
    }

    func wait() async -> Value {
        await withCheckedContinuation { (c: CheckedContinuation<Value, Never>) in
            lock.lock()
            if settled, let v = value {
                lock.unlock()
                c.resume(returning: v)
                return
            }
            continuation = c
            lock.unlock()
        }
    }
}

// MARK: - 串行任务链（connection.ts:161-170 syncChain）

/// dsh syncChain Promise 链 1:1：所有 syncTools 调用（初始同步与通知重
/// 同步、跨全部世代）在此串行，任何两个同步的「注销旧集/注册新集」换手
/// 不会交错（connection.ts:155-160 注释语义）。
/// - `enqueue` 返回的任务可 await（错误透传给入队方——dsh :163 run 语义）；
/// - 链尾吞错（dsh :168 `run.catch(() => {})`——入队方拥有上报责任）；
/// - `drain` = dsh `await syncChain`（dispose 排空点）。
final class MCPSerialTaskChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// 入队一个同步操作；返回其任务（调用方可 await 拿错误）。
    func enqueue(_ op: @escaping @Sendable () async throws -> Void) -> Task<Void, any Error> {
        lock.lock(); defer { lock.unlock() }
        let prior = tail
        let run = Task<Void, any Error> {
            // 等前序完成；链尾已吞错（Task<Void, Never>），此处防御性再吞。
            try? await prior?.value
            try await op()
        }
        // 新链尾 = 吞错包装（dsh :168），链在失败后继续。
        tail = Task { _ = try? await run.value }
        return run
    }

    /// 排空当前链（dsh :346 `await syncChain`）；无错误抛出（链尾吞错）。
    func drain() async {
        lock.lock()
        let t = tail
        lock.unlock()
        _ = await t?.value
    }
}

// MARK: - 错误与结果类型

/// 连接看门狗超时错误（M4-A 裁决②自建——Swift SDK 0.12.1 connect 无内建
/// 超时；dsh 无对应物，Node SDK initialize 默认超时不可移植）。
struct MCPConnectTimeoutError: Error, CustomStringConvertible {
    let label: String
    let timeoutMs: Int
    /// M4-B B7：stdio 变体的模型可读提示（http 恒 nil——文案不变）。模型
    /// 据此从超时错误文本推断"server 可能慢启动"并选择 mcp_server_config
    /// 调大 startup_timeout_seconds 重试（用户决策③的反馈闭环）。
    var hint: String?
    var description: String {
        var text = "\(label): connection attempt timed out after \(timeoutMs)ms"
        if let hint { text += " — \(hint)" }
        return text
    }
}

/// 首次连接尝试的结果（connection.ts:93-96 ConnectionOutcome 1:1）。
/// @unchecked：dsh error 类型为 unknown（任意错误值）；Swift 侧任意错误
/// 不保证 Sendable，监督器只在锁内读写。
struct MCPConnectionOutcome: @unchecked Sendable {
    /// 初始连接或工具同步失败的错误；成功为 nil。
    let error: (any Error)?
}

// MARK: - 连接监督器（connection.ts:98-352 startConnection）

/// 单个 MCP server 的受监督连接（dsh startConnection 闭包状态的 WanWo
/// 形态）：持有世代（client+transport）、重连循环与活注册集。生命周期
/// 由 McpClient.activate/deactivate 驱动（index.ts:173-177 effect 语义）。
final class McpConnectionSupervisor: @unchecked Sendable {

    private static let logger = AppLogger(category: "McpConnection")

    /// 连接超时的模型可读提示（纯函数；internal=可测性放宽先例=件12
    /// collectPaginated）。stdio=慢启动指引（B7 返工文案：config 是会话栈
    /// 构建时捕获的快照——重连读旧 startupTimeoutMs，新值只对新会话栈生效，
    /// 文案必须指到「新会话」而非「reconnect」，否则模型引导用户重连→
    /// 仍超时→困惑循环）；http 恒 nil（http 超时语义不同，不指向配置工具
    /// ——文案不变锚点）。
    static func connectTimeoutHint(for transport: MCPTransport) -> String? {
        guard case .stdio = transport else { return nil }
        return "if this MCP server is slow to start (e.g. it compiles " +
            "or downloads dependencies on first run), increase its " +
            "startup_timeout_seconds via mcp_server_config, then start " +
            "a new session to apply it"
    }

    // ---- 不变状态（构造即定，无锁读）----
    private let config: MCPClientConfig
    private let policy: MCPReconnectPolicy
    private let label: String
    /// 常规同步选项（connection.ts:125-129 opts）。
    private let opts: MCPToolBridgeOptions
    /// 首次同步选项：failOnStartupError 时冲突改为上抛
    /// （connection.ts:130-135——早期通知不得消耗严格 startup 语义）。
    private let startupOpts: MCPToolBridgeOptions
    /// 工具同步缝（dsh 直接 import 的 syncTools；WanWo 经协议注入）。
    private let toolSync: MCPToolSyncing
    /// elicitation 决策链缝（件9；nil=不声明 elicitation 能力——fail closed，
    /// 件5 imageProjector 同款装配纪律）。
    private let elicit: MCPElicitationHandling?
    /// 同步串行链（connection.ts:161）。
    private let chain = MCPSerialTaskChain()

    // ---- 可变状态（connection.ts:137-150；锁内读改写、副作用出锁）----
    private let lock = NSLock()
    /// connection.ts:137 disposed。
    private var disposed = false
    /// connection.ts:139 当前世代（连接中或已连接；退避等待与最终失败后为 nil）。
    private var client: Client?
    /// connection.ts:141 与 client 配对的关闭信号（dispose 前捕获）。
    private var closeSignal: MCPGenerationCloseSignal?
    /// connection.ts:143 活注册集（仅 enqueueSync 与 dispose/give-up 换手）。
    private var disposers: MCPToolDisposers = [:]
    /// connection.ts:144 reconnectTimer → 重连等待任务。
    private var reconnectTask: Task<Void, Never>?
    /// connection.ts:146 当前断线内连续失败次数。
    private var failedAttempts = 0
    /// connection.ts:148 当前世代完成 connect+初始同步的时刻（ms；down 时 nil）。
    private var connectedAt: Int?
    /// connection.ts:150 首次尝试的真实错误（startup-await 诊断用）。
    private var firstAttemptError: (any Error)?
    /// connection.ts:308 settling——在飞（或最近一次已 settle）的连接尝试；
    /// dispose await 之求静默。重连时被覆盖，awaitReady 绑定初始尝试。
    private var settlingTask: Task<Void, Never>?
    /// awaitReady 专用的首次尝试任务（dsh :313 ready 绑定首次 settling；
    /// Optional 仅为 init 内 Task 创建先于赋值的 Swift 完整性规则，实际
    /// init 返回时恒非 nil，此后永不覆盖）。
    private var initialSettlingTask: Task<Void, Never>?

    // MARK: 生命周期

    /// 构造即启动首次连接尝试（dsh :308 `settling = connectGeneration(true)`
    /// ——状态声明后立即执行）。
    init(config: MCPClientConfig, policy: MCPReconnectPolicy, toolSync: MCPToolSyncing,
         elicit: MCPElicitationHandling? = nil) {
        self.config = config
        self.policy = policy
        self.label = "mcp-client(\(config.serverName))"
        self.toolSync = toolSync
        self.elicit = elicit
        var regular = MCPToolBridgeOptions(
            registrationFailure: .contain,
            serverName: config.serverName,
            toolCallTimeoutMs: config.toolCallTimeoutMs)
        self.opts = regular
        // connection.ts:133-135：仅首次同步在 failOnStartupError 下用严格模式。
        if config.failOnStartupError { regular.registrationFailure = .throwError }
        self.startupOpts = regular
        let first = Task { [weak self] in
            guard let self else { return }
            await self.connectGeneration(startup: true)
        }
        self.initialSettlingTask = first
        self.settlingTask = first
    }

    // MARK: 对外句柄（connection.ts:99-112 ConnectionHandle）

    /// dsh `ready`（:100-105/:313-323）：首次尝试 settle 后报告结果。
    /// Task.value 可重复 await，与 promise 多处 await 语义一致。
    /// 时序对拍：dsh 注释（:317-319）——settling.then 是微任务而 stdio
    /// onclose 是宏任务，成功初始同步后的崩溃不能在本续体前翻转 client；
    /// Swift 侧 generationDown 由请求失败驱动（异步入口），恢复后锁内读
    /// client，同构成立。
    func awaitReady() async -> MCPConnectionOutcome {
        _ = await initialSettlingTask?.value
        lock.lock()
        let current = client
        let firstError = firstAttemptError
        lock.unlock()
        // :320-322——client 非 nil = 初始 connect+sync 成功；否则监督器已在
        // 重试（错误已记日志）或已放弃（错误已记日志）。
        if current != nil { return MCPConnectionOutcome(error: nil) }
        return MCPConnectionOutcome(error: firstError
            ?? MCPConfigurationError("\(label): initial connection failed"))
    }

    /// dsh `dispose`（:107-111/:327-349）：停止重连、关闭活世代、等在飞
    /// 尝试与排队同步静默，然后注销本 server 仍持有的全部工具。幂等。
    func dispose() async {
        lock.lock()
        disposed = true                                       // :328
        let timer = reconnectTask                             // :329-331
        reconnectTask = nil
        let current = client                                  // :333
        let currentClosed = closeSignal                       // :334
        client = nil                                          // :335
        closeSignal = nil                                     // :336
        lock.unlock()
        timer?.cancel()                                       // clearTimeout
        // B5：dispose 直达（插件 reload/停用）可能未经 generationDown——
        // stdio guest 进程组在此终结（先杀→后断开：transport 收 EOF，
        // disconnect 与 5s 竞速立刻获胜）。重 spawn 前的 factory reap 幂等。
        reapStdioSession(reason: "disposed")
        if let current {
            // :338 close 吞错 → Swift：后台断开+finish（HTTP 断开时长不受
            // 控，主路径若 inline await 将失去 5s 竞速上限；平台适配见汇报）。
            let signal = currentClosed
            Task { await current.disconnect(); signal?.finish() }
            // :339-341——isClosed 快路径与 await 竞速拆开写（`||` 右侧 await
            // 落 autoclosure，CI 工具链实证不支持并发）。
            if let currentClosed {
                let quiesced: Bool
                if currentClosed.isClosed {
                    quiesced = true
                } else {
                    quiesced = await waitForClose(currentClosed)
                }
                if !quiesced {
                    Self.logger.error(
                        "\(self.label): generation did not close within " +
                        "\(MCPConstants.generationCloseTimeoutMs)ms during disposal — " +
                        "server shutdown may be incomplete")
                }
            }
        }
        // :343-344 静默而非仅请求：在飞尝试 settle 前必已入队其同步，
        // await 两者后 disposers 终局。
        if let settling = settlingTask { _ = await settling.value }   // :345
        await chain.drain()                                           // :346
        lock.lock()
        let final = disposers                                         // :347
        disposers = [:]                                               // :348
        lock.unlock()
        for dispose in final.values { dispose() }
    }

    /// 裁决①入口：已建立世代上的请求失败由上层调用（dsh onclose 的语义
    /// 对应物）。isCurrent 守卫使并发的失败信号天然幂等（:172 注释语义）。
    func reportRequestFailure(generation: Client) {
        generationDown(generation)
    }

    /// 当前世代只读快照（M4-A 件11 McpClient.readyClient 的取数半边；
    /// down/disposed 后为 nil——调用方 fail closed 抛错）。
    func currentClient() -> Client? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    // MARK: 内部：stdio 世代进程回收（M4-B B5 监督面）

    /// stdio guest 进程组回收（ledger 三段分工的 B5 段）：generationDown/
    /// dispose/giveUp/失败世代兜底四落点经 ledger.reap 终结 guest 进程组
    /// 并关闭双 fd。dsh 同构：TS SDK StdioClientTransport 的 close 会杀
    /// child（stdio.ts:202-206 abort 链）——Swift StdioTransport 是 fd 注入
    /// 形态、无进程所有权（B4 三坑①），kill 归属在 WanWo。
    /// 行为链（核① 5s 竞速的兑现路径）：reap→terminate（closeStdin→
    /// SIGTERM→200ms→SIGKILL，minis 坑位④优雅+回退压缩形态）→guest 死→
    /// stdout EOF→StdioTransport readLoop 退出→Client 消息循环退出→
    /// disconnect 完成→signal.finish——waitForClose 的 5s 竞速在正常内核
    /// 下宽裕获胜；内核僵死时 5s 上限兜底（既有语义不变）。
    /// http 条目无 ledger 记录，reap 返回 false——日志只在真实回收时打。
    private func reapStdioSession(reason: String) {
        let reaped = MCPStdioSessionLedger.shared.reap(serverName: config.serverName)
        if reaped {
            Self.logger.info("\(self.label): stdio server process terminated (\(reason))")
            // 方案乙最小化：回收落点事件落诊断文件（reason 直接指认归属路径）。
            MCPDiagnosticsLog.shared.record(
                level: "info", category: "MCPConnection", server: config.serverName,
                event: "stdio server process terminated (\(reason))")
        }
    }

    // MARK: 内部：世代守卫与下行

    /// dsh :152-153——世代只在「仍是当前世代且插件存活」时可行动。
    private func isCurrent(_ generation: Client) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !disposed && client === generation
    }

    private func isDisposed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return disposed
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// dsh :172-178 generationDown——每世代一次的下行决策（isCurrent 守卫
    /// 使竞态的关闭/错误信号幂等）。
    private func generationDown(_ generation: Client) {
        let signal: MCPGenerationCloseSignal? = withLock {
            guard !disposed, client === generation else { return nil }
            client = nil                       // :175
            let s = closeSignal
            closeSignal = nil                  // :176
            return s
        }
        guard signal != nil else { return }    // 守卫未过（含 dispose 竞态）
        // 裁决①平台适配：dsh onclose 由 transport close 事件触发且自带
        // 关闭；Swift transport 无 onclose——fire-and-forget 主动断开并在
        // 完成后广播关闭信号（waitForClose 的等待者在此解除）。强捕获
        // generation：所有权已在锁内清空，weak 捕获会在 disconnect 前释放
        // （dsh 同构：generation 在 close 闭包链上存活到关闭完成）。
        if let signal {
            Task {
                await generation.disconnect()
                signal.finish()
            }
        }
        // B5：stdio guest 进程组随世代下行终结（dsh 同构——TS transport
        // close 杀 child）。isCurrent 守卫已过=本世代进程仍登记在 ledger；
        // 重连新世代 spawn 前 factory 会再次 reap（幂等 no-op）。
        reapStdioSession(reason: "generation down")
        scheduleReconnect()                    // :177
    }

    // MARK: 内部：同步串行链（connection.ts:162-170）

    /// dsh enqueueSync 1:1：读旧注册集传参，换手写回由串行链保证不交错。
    /// `options` 缺省用 opts（dsh :162 默认参数）。
    private func enqueueSync(_ generation: Client,
                             options: MCPToolBridgeOptions? = nil) -> Task<Void, any Error> {
        let resolved = options ?? opts
        return chain.enqueue { [weak self] in
            guard let self, self.isCurrent(generation) else { return }   // :164
            let previous = self.withLock { self.disposers }
            let next = try await self.toolSync.syncTools(
                client: generation, options: resolved, previous: previous)
            self.withLock { self.disposers = next }
        }
    }

    // MARK: 内部：关闭竞速（connection.ts:180-190）

    /// dsh waitForClose 1:1：等 transport 侧关闭信号，但不让坏死的传输把
    /// 拆除永久卡住——5s 竞速上限（fail closed）。
    private func waitForClose(_ signal: MCPGenerationCloseSignal) async -> Bool {
        // hasClosed() 快路径（dsh :185——已 resolve 的 promise 立即真）。
        if signal.isClosed { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await signal.wait() }          // 关闭→true；取消→false
            group.addTask {
                // dsh :183 setTimeout(unref)——Task.sleep 不保持进程存活，
                // unref 语义无对应物（平台适配）。
                try? await Task.sleep(
                    nanoseconds: UInt64(MCPConstants.generationCloseTimeoutMs) * 1_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()   // 两个子任务都响应取消→组干净退出（无泄漏挂起）
            return first
        }
    }

    // MARK: 内部：重连调度（connection.ts:192-225）

    /// dsh scheduleReconnect 1:1。锁内完成状态读改写与决策，副作用（日志、
    /// give-up 排链、重连任务创建）出锁执行。
    private func scheduleReconnect() {
        enum Next {
            case disabledLost          // :196
            case disabledFailed        // :197
            case giveUp                // :206-214
            case retry(delayMs: Int, lost: Bool, attempts: Int)  // :216-224
        }
        let next: Next = withLock {
            let lostEstablishedConnection = connectedAt != nil       // :193
            if !policy.enabled {                                     // :194
                // dsh disabled 分支不清 connectedAt/failedAttempts（:199 return）。
                return lostEstablishedConnection ? .disabledLost : .disabledFailed
            }
            // :201-203——存活越过稳定窗口（=maxDelayMs，最长退避间隔）的连接
            // 已终结上一次断线：预算清零；crash-loop 型 server 即使短暂连上
            //也会耗尽上限而非无限重启。
            if connectedAt != nil, nowMs() - connectedAt! >= policy.maxDelayMs {
                failedAttempts = 0
            }
            connectedAt = nil                                        // :204
            failedAttempts += 1                                      // :205
            if failedAttempts > policy.maxAttempts {                 // :206
                return .giveUp
            }
            // :216 delay = min(maxDelay, initial·2^(n-1))——迭代封顶计算，
            // 防 `2 ** (n-1)` 在 maxAttempts 大时溢出（数学等价）。
            var delayMs = policy.initialDelayMs
            for _ in 1..<failedAttempts {
                delayMs = min(policy.maxDelayMs, delayMs * 2)
            }
            return .retry(delayMs: delayMs, lost: lostEstablishedConnection,
                          attempts: failedAttempts)
        }
        switch next {
        case .disabledLost:
            // :195-196——HMR reload → WanWo 语义 = server 重载（无 HMR 概念，
            // 平台适配已在汇报登记）。
            Self.logger.error(
                "\(self.label): connection lost and reconnect is disabled — " +
                "registered tools will fail until a server reload or Host restart")
        case .disabledFailed:
            // :197
            Self.logger.error(
                "\(self.label): connection failed and reconnect is disabled — " +
                "no tools were registered; reload the plugin or restart the Host to connect")
        case .giveUp:
            // :207-212——give-up 注销排入串行链，不得与在飞同步的换手竞速
            // （链内 isCurrent 检查保护）。
            chain.enqueue { [weak self] in
                guard let self else { return }
                let d = self.withLock { self.disposers }
                for dispose in d.values { dispose() }
                self.withLock { self.disposers = [:] }
            }
            // B5：giveUp 只注销工具不杀进程——kill 责任在 generationDown
            // （giveUp 必经其 scheduleReconnect 到达，彼时已 reap）。此处
            // 幂等兜底 no-op，防未来路径演化漏杀（职责分工：disposers 排
            // 链=工具注销；ledger.reap=进程组终结）。
            reapStdioSession(reason: "give-up backstop")
            // :213
            Self.logger.error(
                "\(self.label): giving up after " +
                "\(self.policy.maxAttempts) consecutive failed reconnect attempts — " +
                "tools unregistered; reload the plugin or restart the Host to reconnect")
            // 方案乙最小化：giveUp 事件落诊断文件（世代循环终点）。
            MCPDiagnosticsLog.shared.record(
                level: "error", category: "MCPConnection", server: config.serverName,
                event: "giving up after \(self.policy.maxAttempts) consecutive " +
                       "failed reconnect attempts — tools unregistered")
        case .retry(let delayMs, let lost, let attempts):
            // :217-218
            let action = lost ? "connection lost; reconnecting" : "connection failed; retrying"
            Self.logger.warning(
                "\(self.label): \(action) in \(delayMs)ms " +
                "(attempt \(attempts)/\(self.policy.maxAttempts))")
            // 方案乙最小化：重连循环事件落诊断文件（世代节奏时间线）。
            MCPDiagnosticsLog.shared.record(
                level: "warn", category: "MCPConnection", server: config.serverName,
                event: "\(action) in \(delayMs)ms (attempt \(attempts)/" +
                       "\(self.policy.maxAttempts))")
            // :219-224——Timer → Task.sleep（unref 语义无对应物，平台适配）。
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.runRetryAttempt()
            }
            withLock { reconnectTask = task }
        }
    }

    /// dsh :220-221 定时器触发：清定时器句柄，启动下一次尝试并换手 settling。
    private func runRetryAttempt() async {
        withLock { reconnectTask = nil }
        let attempt = Task { [weak self] in
            guard let self else { return }
            await self.connectGeneration(startup: false)
        }
        withLock { settlingTask = attempt }
        await attempt.value
    }

    // MARK: 内部：连接尝试（connection.ts:237-305）

    /// dsh connectGeneration 1:1：新 transport+client（SDK 把 Protocol 与
    /// transport 终身绑定，每次尝试全新实例），connect，排队初始工具同步。
    /// 失败一律经 attemptFailure 漏斗；成功即接通请求失败驱动的下行路径。
    /// 永不抛出。
    private func connectGeneration(startup: Bool) async {
        // :238-241——client info 照抄 dsh 值（平台适配：标识不变更）；
        // Capabilities() 默认全 nil = 不声明能力（dsh capabilities: {}）。
        // elicitation 能力仅当决策链在场时声明（件9；SDK Capabilities.Elicitation
        // init 默认 form 在场、url 需显式——Client.swift:117，两型都声明）。
        let capabilities: Client.Capabilities
        if elicit != nil {
            capabilities = Client.Capabilities(
                elicitation: .init(form: .init(), url: .init()))
        } else {
            capabilities = Client.Capabilities()
        }
        let generation = Client(name: "dsh-mcp-client", version: "0.0.1",
                                capabilities: capabilities)
        let signal = MCPGenerationCloseSignal()            // :242 closed
        withLock {                                         // :246-247
            client = generation
            closeSignal = signal
        }
        // 件9：elicitation handler 注册先于 connect（SDK withMethodHandler
        // actor 注册，Client.swift:826-843；与 onNotification 同位纪律——
        // 早期 elicitation/create 请求不落空）。
        if let elicit {
            await generation.withElicitationHandler { [elicit, serverName = config.serverName] params in
                try await elicit.handle(serverName: serverName, params: params)
            }
        }
        // :255-270——ToolListChanged 注册先于 connect：初始同步期间的列表
        // 变化排队在其后而非丢失。
        await generation.onNotification(ToolListChangedNotification.self) { [weak self] message in
            guard let self else { return }
            _ = message                                    // dsh handler 忽略载荷（:259）
            guard self.isCurrent(generation) else { return }     // :260
            Self.logger.info("\(self.label): tool list changed, re-syncing")  // :261
            do {
                _ = try await self.enqueueSync(generation).value   // :263
            } catch {
                // :265-267——取数阶段失败：旧世代仍注册、disposers 仍持有
                // 它——继续服务上一份好名单。
                if !self.isDisposed() {
                    Self.logger.error(
                        "\(self.label): tool re-sync failed: " +
                        "\(String(describing: error))")
                }
            }
        }
        // :271-278 try 块（connect → close 检查 → 初始同步入队）。
        do {
            // :272——每次尝试全新 transport（dsh createTransport(config)）。
            let transport = try MCPTransportFactory.makeTransport(for: config)
            // 裁决②：连接看门狗（initialize 挂起无内建超时且不响应取消）。
            // B5：stdio 读 config.startupTimeoutMs（用户裁决③平台层启动
            // 超时），http 恒默认 30s。B7：stdio 超时错误附模型可读提示
            //（慢启动→mcp_server_config 调大重试的反馈闭环）。
            let timeoutHint = Self.connectTimeoutHint(for: config.transport)
            let connectResult = await connectWithWatchdog(
                generation, transport: transport, timeoutMs: config.startupTimeoutMs,
                timeoutHint: timeoutHint)
            switch connectResult {
            case .success:
                break
            case .failure(let error):
                await attemptFailure(generation, signal: signal, error: error)
                return
            }
            // :273-277——connect 返回时 close 已观察（防御性；Swift 中唯一
            // 来源是并发的 dispose 抢先清除所有权）。
            if signal.isClosed {
                generationDown(generation)
                return
            }
            // :278——startup 标志属于尝试而非共享同步队列（:230-232 注释）。
            _ = try await enqueueSync(generation, options: startup ? startupOpts : opts).value
        } catch {
            await attemptFailure(generation, signal: signal, error: error)
            return
        }
        // :297-305 成功路径。
        // :298-301——成功后 close 已观察（防御性，来源同 :273）。
        if signal.isClosed {
            generationDown(generation)
            return
        }
        // :302
        guard isCurrent(generation) else { return }
        withLock { connectedAt = nowMs() }                 // :303
        let attempts = withLock { failedAttempts }
        if attempts > 0 {                                  // :304
            Self.logger.info(
                "\(self.label): reconnected and re-synced tools " +
                "(attempt \(attempts)/\(self.policy.maxAttempts))")
        }
    }

    /// dsh :279-296 catch 路径 1:1：记首次错误→（活监督器）warn→断开并竞速
    /// 关闭→未关则停重连（fail closed）→正常下行。
    private func attemptFailure(_ generation: Client,
                                signal: MCPGenerationCloseSignal,
                                error: any Error) async {
        withLock {
            if firstAttemptError == nil { firstAttemptError = error }   // :280
        }
        // :282-283——dispose 先清所有权再关世代，故只有活监督器报告尝试失败。
        if isCurrent(generation) {
            Self.logger.warning(
                "\(self.label): connection attempt failed: " +
                "\(String(describing: error))")
        }
        // :284-285——close 吞错 + 关闭竞速。Swift：断开放后台（时长不受控），
        // 主路径 await waitForClose 保 5s 上限（平台适配，汇报登记）。
        // isClosed 快路径与 await 竞速拆开写（`||` 右侧 await 落 autoclosure）。
        Task { await generation.disconnect(); signal.finish() }
        let quiesced: Bool                                            // :285
        if signal.isClosed {
            quiesced = true
        } else {
            quiesced = await waitForClose(signal)
        }
        // :286 attemptSettled 仅被 onclose 消费（Swift 无 onclose——省略，汇报登记）。
        guard isCurrent(generation) else { return }                     // :287
        if !quiesced {                                                  // :288
            withLock {                                                  // :289-290
                client = nil
                closeSignal = nil
            }
            // B5：此路径不走 generationDown（重连已停）——stdio guest 进程
            // 若仍在（如 initialize 悬置）将成为孤儿，就地终结；kill 同时
            // 让悬置 transport 立即收 EOF，"overlapping server processes"
            // 的顾虑源头上消除。
            reapStdioSession(reason: "failed generation did not close — killing stdio server")
            Self.logger.error(                                          // :291
                "\(self.label): failed generation did not close within " +
                "\(MCPConstants.generationCloseTimeoutMs)ms — reconnect stopped to avoid " +
                "overlapping server processes; reload the plugin or restart the Host to retry")
            return
        }
        generationDown(generation)                                      // :294
    }

    // MARK: 内部：连接看门狗（M4-A 裁决②）

    /// 语义定义（正式版，已落台账；M4-B B5 stdio 变体修订）：
    /// - 常量：http 条目恒 `MCPConstants.connectWatchdogTimeoutMs = 30_000`；
    ///   stdio 条目=`config.startupTimeoutMs`（startupTimeoutSeconds，空=
    ///   60s 默认，值域 1-900——用户裁决③平台层启动超时，锚点 minis
    ///   config.py:32/:34；guest 进程启动+initialize 全程在该窗口 settle）；
    /// - 触发条件：单次连接尝试中 `client.connect(transport)`（含传输建立
    ///   + initialize 往返）超时窗内未 settle（成功或抛错）；
    /// - 复位条件：connect 在窗口内 settle——看门狗 Task 立即取消，结果箱
    ///   settle-once 保证先到方获胜、后到方 no-op；
    /// - 超时后动作：本尝试按失败处理，走 attemptFailure 同路径（warn →
    ///   后台 disconnect + 关闭竞速 → generationDown → scheduleReconnect
    ///   退避；stdio 的 guest 进程组由 generationDown 的 ledger.reap 终结）。
    ///   悬置的 connect 任务不强杀（Swift 无此能力）：attemptFailure
    ///   的 disconnect 会 resume 其 initialize continuation（Client.swift:287
    ///   resume 全部 pendingRequests），任务随后自然结束；悬置窗口零 CPU。
    private func connectWithWatchdog(_ generation: Client,
                                     transport: any Transport,
                                     timeoutMs: Int,
                                     timeoutHint: String?) async -> Result<Initialize.Result, any Error> {
        let box = MCPSettleOnce<Result<Initialize.Result, any Error>>()
        let connectTask = Task {
            do {
                box.settle(.success(try await generation.connect(transport: transport)))
            } catch {
                box.settle(.failure(error))
            }
        }
        let watchdogTask = Task { [label, timeoutHint] in
            // 睡眠响应取消（connect 先 settle 时立即退出）。
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            box.settle(.failure(MCPConnectTimeoutError(label: label, timeoutMs: timeoutMs,
                                                       hint: timeoutHint)))
        }
        let result = await box.wait()   // 有界：watchdog 必在超时点 settle
        watchdogTask.cancel()
        return result
    }

    // MARK: 内部：时钟

    /// dsh `Date.now()` 墙钟 ms（稳定窗口与连接时刻计算）。
    private func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
