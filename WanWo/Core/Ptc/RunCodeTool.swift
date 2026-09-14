//
//  RunCodeTool.swift
//  WanWo
//
//  【M5-B 批 P3 · run_code 工具本体（子派发调度 + ptc-dispatch 事件对）】
//  出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/core/tools/src/ptc.ts（678 行全文）：
//    - :20      RUN_CODE_NAME = 'run_code'
//    - :30-35   RunCodeFlavor{description, codeDescription}
//    - :43-52   TYPESCRIPT_FLAVOR 两文案逐字（PYTHON_FLAVOR :59-68 不移植——
//               Python 后端 P5 二期，resolveFlavor :112-129 简化单语言，登记②）
//    - :93-96   RUN_CODE_DESCRIPTION_PARAM_DESCRIPTION 逐字
//    - :138-143 CodeRunFailedError（code 'CODE_RUN_FAILED'）——WanWo run 不
//               throws 纪律（P1 裁定）→ 结构化失败形态（code/name 随行）
//    - :150-166 jsonNormalizeArgs 双快照（登记③：JSONValue 值类型退化恒等）
//    - :169/:176 JSON_INDENT='  ' / MAX_JSON_INDENT_CHARS=10
//    - :184-251 renderJsonValue 迭代渲染器 1:1（对象键序差异登记⑯）
//    - :254-256 renderValue（string 直出）
//    - :259/:312-326 output schema+render 面 → ToolOutput 直出（登记④）
//    - :266-280 RunCodeBridgeOptions 四能力 → init 注入缝（登记⑤）
//    - :321-325 render：logs.join('\n') + rendered；空态文案 :324 逐字
//    - :327-647 execute 主流程（:328-330 description 非空校验文案逐字；
//      :337-345 run-scoped abort → RunScope+Task cancellation 登记⑥；
//      :357-456 单驱动车道调度器 → PtcDispatchLane actor；:461 runOver
//      每次重读；:463-599 binding 三拒文案逐字 + settle 即解析；
//      :606-614 functions 枚举 registry.schemas 跳过 run_code——Swift 字典
//      own-key 天然等价（P1 登记③同源）；:619-627 runtime.run + errorClass
//      {name:'ToolCallError', memberNameProperty:'toolName'} 逐字；
//      :628-634 finally abort('run_code settled')+drain；:636-638
//      CodeRunFailedError 文案逐字）
//    - :650-655 presentCall（generic 卡 + title=description + 程序随行，登记⑬）
//  dsh-upstream-m5/packages/core/tools/src/types.ts：
//    - :11-17   PtcDispatchStartEventData{rootCallId, parentCallId, subCallId,
//               name, arguments}
//    - :20-23   PtcDispatchEventData extends + {isError, content}
//    - :25-57   两事件 doc（log-only：deriveMessages 忽略——子调用永不重入
//               模型上下文；UI 按 subCallId 配对、time 定时序）
//  E1 通道：SessionEvent.extensionEvent(kind, payload)（SessionEvent:153）+
//  ExtensionEventRegistry schema{kind, projection, pairing}——E3
//  HookSessionEvents 同款注册/追加形态（schema 字段类型面差异登记⑰）。
//
//  ── 关键裁定（呈报项，随件登记）─────────────────────────────────────────
//  ① 子派发对话可见性 = hooks 跑、对话事件不落。证据链：
//    · dsh types.ts:50-51 "Log-only: deriveMessages() ignores it, so
//      sub-calls never re-enter model context"（子调用不进模型历史）；
//    · dsh scheduler.prepare 含 pre-execute waterfall（ptc.ts:344-345
//      "prepare = pre-execute/guards"）——hooks 跑；
//    · WanWo 最简挂接 = ToolPipeline.run（管线一体：PreToolUse/PostToolUse
//      hooks + guard + timeout + spill + adviser；本就零对话事件——
//      ToolPipeline.swift:41-43 "tool/call 与 tool/result 由调度器按 model
//      order 落盘；本方法只负责管线本身"）。子派发 = 纯 pipeline.run ⇒
//      两面同时成立，零新增面、零 ToolPipeline 改动。
//  ② shapeDispatchLog 暂不接。dsh listener 允许把持久副本替换为 preview+
//    locator（spill 后端注入）；WanWo F037 spill 已在 pipeline.run 内替换
//    共享 text（ToolPipeline.applySpill），ptc-dispatch 的 content 直落子
//    调用产出文本，无第二持久副本可替换。登记差异：dsh 程序 value 不受
//    listener 影响、WanWo 程序 binding 值与日志副本同源（同一 text 面，
//    spill 替换同时作用于两者）。
//  ③ jsonNormalizeArgs 双快照 → 恒等。JSONValue 是 Swift 值类型，语义复制
//    天然独立（dispatched/logged 互不串扰——"a tool mutating its args
//    cannot desync this record" ptc.ts:514-517 注释语义）；三条拒文
//    （lossy/undefined/detach 失败）在类型面不可达，保留函数形态作锚位。
//  ④ output schema+render 面 → ToolOutput 直出。dsh output.schema 是结构化
//    输出声明（logs required array + result json），render 把它组合成模型
//    可见文本；WanWo ToolOutput 无结构化输出面，工具体直接按 render 语义
//    组装文本（render 逻辑 1:1，声明面折入）。
//  ⑤ RunCodeBridgeOptions 四能力映射：requireRuntime/peekRuntime → init
//    注入 runtime（单语言简化，登记②）；maxParallel → maxParallelSubCalls
//    （装配传入，默认 10）；shapeDispatchLog → 裁定②不接。
//  ⑥ run-scoped AbortController → RunScope + Task cancellation（J1/P1 登记④
//    延续）：外层取消 → scope.abort("canceled")（dsh onOuterAbort
//    abort(exec.signal.reason) 等价；reason 文案取 CodeRunFailure.abort
//    通道同款 'canceled'）；run 落定 → scope.abort("run_code settled")
//    （ptc.ts:632 逐字）；abort 即取消全部在飞 body Task（dsh in-flight
//    dispatch 的 executor kills on this signal 等价——Task.cancel 协作收敛）。
//  ⑦ logWork 旁路集 → commit 内联 await。dsh 把 settle 事件 append 作为
//    旁路 Task（程序值先解析、append 不阻塞绑定）+ maxParallel 反压；WanWo
//    SessionWriter.append 是本地 JSONL 直写，内联 await 在序内完成（更强
//    反压、drainDispatches 天然清空）——"every settle event is appended
//    inside the open run_code turn" 不变量以更强形式成立。
//  ⑧ 车道 actor 化。dsh 单驱动 lane 用 wake promise + driving 旗；Swift
//    actor 串行化承担同一序不变量：唤醒续延在 actor 同步段内注册（无丢
//    唤醒——dsh :398-400 "create the wakeup promise before inspecting
//    state" 的 actor 等价保障）；启动/提交有序阶段不重叠，仅 body 并发。
//  ⑨ 序内阶段差异。dsh prepare（pre-execute）在车道内、body（around+dispatch）
//    并发、finalize/finish（post-execute）在车道 commit 内；WanWo 管线一体
//    （裁定①），车道序内阶段 = start 事件落盘 + settle 事件落盘，body 含
//    全管线。exclusive 屏障覆盖 body+settle append（dsh 覆盖 body+post）——
//    WanWo post 在 body 内，屏障语义等价成立。
//  ⑩ image deferContext / concludesTurn / additionalContexts 不移植：WanWo
//    ToolExecutionContext 无 defer/conclude 缝；本会话工具族无图像产出
//    （attachment 走 meta 面）；登记，随缝补齐再接。
//  ⑪ 绑定值面。dsh binding 解析 = result.value（工具结构化值）；WanWo
//    ToolOutput 只有 text（模型可见面），程序以 JSON string 收到产出文本
//    ——curate 义务不变（ptc.ts:49 "Only what you print or return is
//    program output — curate it"）。
//  ⑫ description 缺失同拒。dsh 对 undefined 的 .trim 会 TypeError；WanWo
//    类型面把缺失归入同一逐字文案（不产出 JS TypeError 形态）。
//  ⑬ presentCall 映射：card 'generic'/kind 'execute' → ToolCardIntent
//    .generic；rawInput(args.code) → detail（程序随行展示面）。presentResult
//    刻意不接（dsh :656-658 注释同语义：generic 卡兜底读持久结果）。
//  ⑭ 子派发上下文：callId = subCallId，其余（sessionId/turn/step/workspace/
//    spill/onShellLine/completeLLM/sandboxMode/escalationApprover）全透传；
//    dsh input 的 rootCallId/agent/parent/signal 无对应缝——rootCallId 落
//    事件时与 parentCallId 同值（WanWo 无 rootCallId 字段、嵌套深度恒 1：
//    run_code 不在 bindings 集，不能嵌套），agent/parent/signal 不落。
//  ⑮ 在飞子调用的取消收敛：ToolTimeout 不放弃工具体（F019 既有语义），
//    取消只在 pipeline/ToolTimeout 入口检查生效——已入体的工具跑至自然
//    收敛、产出照常提交；dsh executor kills on signal 为强杀，登记差异。
//    未入体（排队未启动）的条目 = 弃单（ptc.ts:530-532 文案逐字，不落
//    start 事件——types.ts:33-34 "a call abandoned in the queue logs
//    nothing"）。
//  ⑯ 对象键序：dsh Object.keys = 插入序；JSONValue.object 是 Swift 字典
//    （无序）——渲染按典序（确定性近似）。数组序保真。
//  ⑰ 事件 schema 字段面：arguments 值域开放（ExtensionFieldSchema 闭集
//    类型无法表达 any JSON）不入 requiredFields（在场性由 append 构造保证
//    ——ptc.ts:32-33 "normalized BEFORE dispatch, so this append can never
//    fail on payload shape"）；content 以单 text 块数组承载（dsh ContentBlock[]
//    的 WanWo 文本面）。
//
//  装配（AppEnvironment）：schema 注册进 init（HookSessionEvents 同位），
//  工具注册在 makeAgentStack 的 pipeline 创建之后（lane 闭包捕获同一
//  registry/pipeline/writer；ShellTool.jobs 同款注入缝）。
//

import Foundation

// MARK: - 事件词汇（types.ts:11-23 事件对 + E1 通道）

/// tool/ptc-dispatch-start 与 tool/ptc-dispatch 扩展事件对（types.ts:25-57
/// doc 逐句语义随注册项承载）：一次子派发启动/落定各一条，log-only——
/// deriveMessages 忽略（子调用永不重入模型上下文），UI 按 subCallId 配对。
enum PtcDispatchEvents {
    /// wire kind（ptc.ts:509/:534 session.append 事件名 1:1）。
    static let startKind = "tool/ptc-dispatch-start"
    /// wire kind（同上）。
    static let dispatchKind = "tool/ptc-dispatch"

    // MARK: 注册（E1 通道 schema；装配期由 AppEnvironment 调用，幂等）

    /// 注册两事件 schema（派单拍板⑤：走 extensionEvent 通道，M3 已建；
    /// projection = .logOnly 无 pairing——E3 HookSessionEvents 同款形态）。
    /// - start：required {rootCallId, parentCallId, subCallId, name}——
    ///   arguments 值域开放不入 required（登记⑰）。
    /// - dispatch：required 上四键 + {isError, content}——content 以单
    ///   text 块数组承载（登记⑰）。
    static func registerEventSchemas() {
        let registry = ExtensionEventRegistry.shared
        let identityFields: [ExtensionFieldSchema] = [
            ExtensionFieldSchema("rootCallId", .string),
            ExtensionFieldSchema("parentCallId", .string),
            ExtensionFieldSchema("subCallId", .string),
            ExtensionFieldSchema("name", .string),
        ]
        if !registry.isRegistered(startKind) {
            registry.register(ExtensionEventSchema(
                kind: startKind,
                requiredFields: identityFields,
                projection: .logOnly,
                pairing: .none))
        }
        if !registry.isRegistered(dispatchKind) {
            registry.register(ExtensionEventSchema(
                kind: dispatchKind,
                requiredFields: identityFields + [
                    ExtensionFieldSchema("isError", .bool),
                    ExtensionFieldSchema("content", .array),
                ],
                projection: .logOnly,
                pairing: .none))
        }
    }

    // MARK: 追加（dsh session.append 的 WanWo 形态——async throws，E1 写侧门）

    /// 追加一条 tool/ptc-dispatch-start（types.ts:11-17 字段 1:1；arguments
    /// = 双快照的 logged 孪生值——ptc.ts:514-517 "SIBLING parse" 语义，值
    /// 类型语义天然独立）。
    @discardableResult
    static func appendDispatchStart(to writer: SessionWriter,
                                    rootCallId: String,
                                    parentCallId: String,
                                    subCallId: String,
                                    name: String,
                                    arguments: JSONValue) async throws -> SessionEvent {
        try await writer.append(.extensionEvent(kind: startKind, payload: .object([
            "rootCallId": .string(rootCallId),
            "parentCallId": .string(parentCallId),
            "subCallId": .string(subCallId),
            "name": .string(name),
            "arguments": arguments,
        ])))
    }

    /// 追加与 start 按 subCallId 配对的 tool/ptc-dispatch（types.ts:20-23：
    /// isError + content = 子调用完整模型可见产出，经 tool/result 同词汇）。
    @discardableResult
    static func appendDispatch(to writer: SessionWriter,
                               rootCallId: String,
                               parentCallId: String,
                               subCallId: String,
                               name: String,
                               arguments: JSONValue,
                               isError: Bool,
                               content: JSONValue) async throws -> SessionEvent {
        try await writer.append(.extensionEvent(kind: dispatchKind, payload: .object([
            "rootCallId": .string(rootCallId),
            "parentCallId": .string(parentCallId),
            "subCallId": .string(subCallId),
            "name": .string(name),
            "arguments": arguments,
            "isError": .bool(isError),
            "content": content,
        ])))
    }
}

// MARK: - 语言 flavor（ptc.ts:30-52 / :93-96）

/// 语言特定 run_code schema 文案（ptc.ts:30-35——description 与 code 参数
/// 描述同源成对，model 可见面与 SDK 语言永不错配）。
struct RunCodeFlavor {
    /// 工具 description（模型可见）。
    let description: String
    /// code 参数描述。
    let codeDescription: String

    /// ptc.ts:43-52 TYPESCRIPT_FLAVOR 逐字（无 runtime 时的退化缺省；WanWo
    /// 装配恒有 P2 runtime——resolveFlavor 简化单语言，登记②）。
    static let typescript = RunCodeFlavor(
        description:
            "Execute a TypeScript program against the available tools. Takes two required "
            + "arguments: `code`, the BODY of an async function (erasable syntax only; top-level "
            + "`await` and `return` work), and `description`, a short summary of what the program "
            + "does. Call tools as `await tools.name(args)` per the declarations in the system "
            + "prompt. Only what you print or return is program output — curate it. Image-bearing "
            + "subtool results are attached after the run.",
        codeDescription: "The program: the body of an async TypeScript function.")

    /// ptc.ts:93-96 RUN_CODE_DESCRIPTION_PARAM_DESCRIPTION 逐字（语言无关——
    /// UI 标签契约跨 runtime 同一）。
    static let descriptionParamDescription =
        "Clear, concise description of what this program does in active voice, "
        + "5-10 words (shown in the UI). Examples: \"Count TODO markers across packages\"; "
        + "\"Read failing test and its fixture\"; \"Rename config key in every cordis.yml\"."
}

// MARK: - run 作用域（ptc.ts:337-345 的 Swift 映射，登记⑥）

/// run-scoped 中止状态（dsh AbortController 等价）：
/// · 外层取消（Task cancellation）→ abort("canceled")；
/// · run 落定（finally）→ abort("run_code settled")（ptc.ts:632 逐字）；
/// · abort 即取消全部在飞 body Task（协作收敛，登记⑮）。
/// 状态读取一律走方法（ptc.ts:458-461 "re-read through a call"——中止态
/// 跨 await 真实变化，直接属性重读会被控制流收窄吞掉）。
final class RunCodeRunScope: @unchecked Sendable {
    private let lock = NSLock()
    private var aborted = false
    private var reason: String?
    private var bodies: [Task<Void, Never>] = []

    /// 燃烧 run 作用域（幂等：首个 reason 胜出——dsh signal.reason 语义）。
    func abort(reason: String) {
        lock.lock()
        let alreadyAborted = aborted
        if !aborted {
            aborted = true
            self.reason = reason
        }
        let snapshot = bodies
        bodies.removeAll()
        lock.unlock()
        guard !alreadyAborted else { return }
        for task in snapshot { task.cancel() }
    }

    /// 登记在飞 body；已中止则立即取消（abort 与 launch 的竞态收口）。
    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if aborted {
            lock.unlock()
            task.cancel()
            return
        }
        bodies.append(task)
        lock.unlock()
    }

    func isAborted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return aborted
    }

    /// 中止原因（dsh String(signal.reason)；未中止时空串）。
    func abortReason() -> String {
        lock.lock()
        defer { lock.unlock() }
        return reason ?? ""
    }
}

// MARK: - 绑定拒绝形态（ptc.ts:465/531/592/597）

/// binding 拒绝（dsh plain Error + message 形态；LocalizedError.errorDescription
/// = worker :504 messageOf 的取文通道——P2 桥按此通道物化 ToolCallError）。
struct RunCodeBindingError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// run_code 程序失败（ptc.ts:138-143 CodeRunFailedError：code
/// 'CODE_RUN_FAILED'，name 'CodeRunFailedError'）。WanWo run 不 throws 纪律
/// （P1 裁定）→ 工具体以结构化失败形态交付，身份随行不丢失。
struct CodeRunFailedError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static let code = "CODE_RUN_FAILED"     // ptc.ts:140
    static let errorName = "CodeRunFailedError"  // ptc.ts:141
}

/// 提交序计数器（ptc.ts:341 `let dispatches = 0` + :468 `++dispatches`——
/// JS 单线程原子自增的 Swift 形态；编号 = 提交序）。
final class PtcDispatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }
}

// MARK: - 调度条目（ptc.ts:357-370 PendingDispatch）

/// 调度器队列条目。不可变身份三方只读；settled/parkedOutput/mode 车道独占
/// （actor 内读写）；延续面（绑定等待 ↔ commit/弃单）锁保护恰好一次结算
/// （P2 finish 幂等同纪律）。
final class PtcDispatchEntry: @unchecked Sendable {
    /// 子工具名（binding 名）。
    let name: String
    /// `<parentCallId>:ptc:<n>`（ptc.ts:469 逐字形态）。
    let subCallId: String
    /// 派发实参（双快照 dispatched 面）。
    let argsDispatched: JSONValue
    /// 落盘实参（双快照 logged 孪生面）。
    let argsLogged: JSONValue

    // 车道独占状态（仅在 PtcDispatchLane actor 内读写）。
    /// 本条目启动时的分类；exclusive 屏障持有至 commit 完成（ptc.ts:369）。
    var mode: ToolExecutionMode?
    /// body 已落定产出（commit 游标等待位，ptc.ts:367）。
    var settled = false
    var parkedOutput: ToolOutput?

    // 延续面（锁保护；恰好一次结算）。
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ToolOutput, Error>?
    private var outcome: Result<ToolOutput, Error>?

    init(name: String, subCallId: String,
         argsDispatched: JSONValue, argsLogged: JSONValue) {
        self.name = name
        self.subCallId = subCallId
        self.argsDispatched = argsDispatched
        self.argsLogged = argsLogged
    }

    /// 绑定等待点（ptc.ts:481 `new Promise` 的 Swift 形态）。
    func awaitOutcome() async throws -> ToolOutput {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ToolOutput, Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                cont.resume(with: outcome)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    /// 车道 commit：以产出结算（恰好一次；先 resume 后续事件 append——
    /// ptc.ts:486-495 "The program gets its value NOW"）。
    func fulfill(_ output: ToolOutput) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let cont = continuation
        continuation = nil
        if let cont {
            lock.unlock()
            cont.resume(returning: output)
        } else {
            outcome = .success(output)
            lock.unlock()
        }
    }

    /// 弃单 / 启动落盘失败：以错误结算（恰好一次）。
    func reject(_ error: Error) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        let cont = continuation
        continuation = nil
        if let cont {
            lock.unlock()
            cont.resume(throwing: error)
        } else {
            outcome = .failure(error)
            lock.unlock()
        }
    }
}

// MARK: - 单驱动车道调度器（ptc.ts:357-456，登记⑧⑨）

/// 每 run 的单驱动车道：提交序启动（start 事件落盘）、提交序结算（绑定
/// resolve + settle 事件落盘）；并发分类启动前 fail-closed 重分类；exclusive
/// 屏障持有至 commit 完成；runOver 时弃单队列未启动条目；三队列全空 =
/// 静默退出。仅 body（管线全量）并发——登记⑨。
actor PtcDispatchLane {
    private let maxParallel: Int
    private let scope: RunCodeRunScope
    /// 启动前重分类（ptc.ts:417-418/529——registry 变更可翻转 exclusive）。
    private let classify: @Sendable (PtcDispatchEntry) -> ToolExecutionMode
    /// body 阶段：子派发管线全量（裁定①——hooks/guard/timeout/spill/adviser）。
    private let runBody: @Sendable (PtcDispatchEntry) async -> ToolOutput
    /// 序内启动阶段：ptc-dispatch-start 落盘（ptc.ts:534-540）。
    private let appendStart: @Sendable (PtcDispatchEntry) async throws -> Void
    /// 序内提交阶段：ptc-dispatch 落盘（ptc.ts:498-521；append 失败内捕）。
    private let appendSettle: @Sendable (PtcDispatchEntry, ToolOutput) async -> Void

    private var pendingQueue: [PtcDispatchEntry] = []
    private var commitQueue: [PtcDispatchEntry] = []
    private var inFlight = 0
    private var exclusiveActive = false
    private var driverTask: Task<Void, Never>?
    private var wakeContinuation: CheckedContinuation<Void, Never>?

    init(maxParallel: Int,
         scope: RunCodeRunScope,
         classify: @escaping @Sendable (PtcDispatchEntry) -> ToolExecutionMode,
         runBody: @escaping @Sendable (PtcDispatchEntry) async -> ToolOutput,
         appendStart: @escaping @Sendable (PtcDispatchEntry) async throws -> Void,
         appendSettle: @escaping @Sendable (PtcDispatchEntry, ToolOutput) async -> Void) {
        self.maxParallel = maxParallel
        self.scope = scope
        self.classify = classify
        self.runBody = runBody
        self.appendStart = appendStart
        self.appendSettle = appendSettle
    }

    // MARK: 提交（ptc.ts:584-586 wakeup + void drive()）

    /// 绑定提交一笔子派发；驱动车道按需唤醒。
    func submit(_ entry: PtcDispatchEntry) {
        pendingQueue.append(entry)
        ensureDriver()
        wake()
    }

    /// 等到车道静默（ptc.ts:448-456 drainDispatches 的车道半；事件 append
    /// 内联于 commit——登记⑦，settle 事件天然而然全部落在 run 落定前）。
    func drain() async {
        ensureDriver()
        if let task = driverTask {
            _ = await task.value
        }
    }

    // MARK: 驱动循环（ptc.ts:392-446 drive 1:1）

    private func ensureDriver() {
        guard driverTask == nil else { return }
        driverTask = Task { [weak self] in await self?.driveLoop() }
    }

    private func driveLoop() async {
        defer { driverTask = nil }
        while true {
            if await stepOnce() { continue }
            // 此刻无可调度工作。但 stepOnce 返回与 waitForWake 注册之间存在
            // 挂起窗口——submit/bodyDidSettle 的唤醒若落在此窗口即丢失
            // （CI 实证 testAbandoned 挂死）。dsh :387-389 同构：唤醒源
            // （signal promise）先于状态检查创建——Swift actor 形态 = 注册
            // 续延与闭包内终态重查同 actor 域原子（唤醒源序列化于其后，
            // 零丢失）。
            await waitForWake()
        }
    }

    private func waitForWake() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // 本闭包在 actor 同步段执行：注册之后的全部唤醒源（submit/
            // bodyDidSettle/requestStop）串行化于闭包之后。闭包内终态重查：
            // 若状态已可调度（唤醒源先到）→ 立即唤醒，外层循环再推进。
            wakeContinuation = cont
            if canProgress() { wake() }
            // 静默：外层循环 stepOnce false → 空判定 → return（挂起等下一个
            // 唤醒源）。
        }
    }

    /// 可调度判定（stepOnce 的工作分支同谓词——waitForWake 闭包重查用）。
    private func canProgress() -> Bool {
        if let head = commitQueue.first, head.settled { return true }
        if let head = pendingQueue.first {
            if scope.isAborted() { return true }
            let mode = classify(head)
            let capacity = !exclusiveActive
                && (mode == .exclusive ? inFlight == 0 : inFlight < maxParallel)
            if capacity { return true }
        }
        return false
    }

    private func wake() {
        if let cont = wakeContinuation {
            wakeContinuation = nil
            cont.resume()
        }
    }

    /// 单次推进：提交队首已落定条目，或按容量启动 pending 队首；返回是否
    /// 做了功（true = 循环立即再推进）。
    private func stepOnce() async -> Bool {
        // ① 提交队首已落定条目（ptc.ts:401-409）。
        if let head = commitQueue.first, head.settled {
            commitQueue.removeFirst()
            await commit(head)
            // 屏障覆盖至 commit 完成（ptc.ts:406-407——序内 post 面全含；
            // WanWo post 在 body 内，登记⑨）。
            if head.mode == .exclusive { exclusiveActive = false }
            return true
        }
        if let head = pendingQueue.first {
            // ② 弃单（ptc.ts:412-416）：run 已落定/中止，队列未启动条目
            //    以逐字文案拒绝、不落 start 事件（types.ts:33-34）。
            if scope.isAborted() {
                pendingQueue.removeFirst()
                head.reject(RunCodeBindingError(message:
                    "run_code run is over (\(scope.abortReason())); "
                    + "\(head.name) tool call abandoned"))
                return true
            }
            // ③ 启动时重分类（fail closed；ptc.ts:417-418）。
            let mode = classify(head)
            // ④ 容量判定（ptc.ts:419-420）。
            let capacity = !exclusiveActive
                && (mode == .exclusive ? inFlight == 0 : inFlight < maxParallel)
            if capacity {
                if mode == .exclusive { exclusiveActive = true }
                head.mode = mode
                pendingQueue.removeFirst()
                // commitQueue 先入队再启动（ptc.ts:425-427——提交序保证；
                // settled 翻转前提交游标不动它）。
                commitQueue.append(head)
                await start(head)
                return true
            }
        }
        return false
    }

    /// 序内启动阶段（ptc.ts:533-554 WanWo 形态）：start 事件落盘（车道内）
    /// → 启动 body（并发；管线全量，登记⑨）。
    private func start(_ entry: PtcDispatchEntry) async {
        do {
            try await appendStart(entry)
        } catch {
            // E1 写侧门拒绝（dsh session.append 不抛——WanWo 差异，fail
            // visible）：该子调用以结构化失败结算，commit 照常交付绑定与
            // settle 事件（isError 审计面完整）。
            entry.settled = true
            entry.parkedOutput = ToolOutput.failure(
                "ptc-dispatch-start append failed: \(String(describing: error))",
                code: "EVENT_APPEND_FAILED", name: "SessionWriteError")
            return
        }
        launch(entry)
    }

    /// body 启动（ptc.ts:546-549 dispatch 阶段）：管线全量跑在车道外；
    /// 完成回车道落定（settled 翻转 + 唤醒提交游标）。
    private func launch(_ entry: PtcDispatchEntry) {
        let body = Task { [runBody] in
            let output = await runBody(entry)
            await self.bodyDidSettle(entry, output)
        }
        scope.register(body)
        inFlight += 1
    }

    /// body 落定回执（ptc.ts:547-548 parked/settled 翻转的 Swift 形态）。
    private func bodyDidSettle(_ entry: PtcDispatchEntry, _ output: ToolOutput) {
        entry.settled = true
        entry.parkedOutput = output
        inFlight -= 1
        wake()
    }

    /// 序内提交阶段（ptc.ts:555-583 WanWo 形态）：绑定结算 NOW → settle
    /// 事件落盘（内联 await = 登记⑦；append 失败记日志不回滚）。
    private func commit(_ entry: PtcDispatchEntry) async {
        guard let output = entry.parkedOutput else { return } // 不可达：settled 翻转时已 park
        // 先结算后落盘：程序值绝不等待事件 append（ptc.ts:486-495 注释）。
        entry.fulfill(output)
        await appendSettle(entry, output)
    }
}

// MARK: - JSON 呈现（ptc.ts:169-256 逐函数移植）

/// 程序 completion value 的模型可见呈现（两空格 JSON 契约）。
enum JSONRender {
    /// ptc.ts:169 JSON_INDENT 逐字。
    static let jsonIndent = "  "
    /// ptc.ts:176 MAX_JSON_INDENT_CHARS——ECMAScript 对 space 字符串的帽；
    /// 渲染器对总缩进施同一帽，更深子树折叠为紧凑形态。
    static let maxJsonIndentChars = 10

    /// ptc.ts:254-256 renderValue：string 直出（不引号），其余走渲染器。
    static func renderValue(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return renderJsonValue(value)
    }

    // MARK: 迭代渲染器（ptc.ts:184-251 renderJsonValue 1:1）

    private enum RenderTask {
        case text(String)
        case value(JSONValue, depth: Int, compact: Bool)
    }

    /// 无递归遍历 + 缩进有界（紧凑折叠当 (depth+1)*2 > 10——ptc.ts:203）。
    /// 对象键序：dsh 插入序 → WanWo 字典典序（登记⑯，确定性近似）。
    static func renderJsonValue(_ value: JSONValue) -> String {
        var chunks: [String] = []
        var tasks: [RenderTask] = [.value(value, depth: 0, compact: false)]
        while let task = tasks.popLast() {
            switch task {
            case .text(let text):
                chunks.append(text)

            case .value(let current, let depth, let wasCompact):
                switch current {
                case .null:
                    chunks.append("null")
                case .bool(let flag):
                    chunks.append(flag ? "true" : "false")
                case .int(let number):
                    chunks.append(String(number))
                case .double(let number):
                    chunks.append(doubleString(number))
                case .string(let text):
                    // 嵌套字符串 = JSON.stringify（:198-200）。
                    chunks.append(CodeRuntimeSeam.jsonQuoted(text))
                case .array(let items):
                    let compact = wasCompact || (depth + 1) * jsonIndent.count > maxJsonIndentChars
                    let childDepth = depth + 1
                    chunks.append("[")
                    if items.isEmpty {
                        chunks.append("]")
                        continue
                    }
                    // 尾界：'\n' + indent(depth) + ']'（indent 用本层深度）。
                    tasks.append(.text(compact ? "]"
                        : "\n\(String(repeating: jsonIndent, count: depth))]"))
                    // 逆序压栈 → 正序弹出（:212-223）。
                    for index in stride(from: items.count - 1, through: 0, by: -1) {
                        tasks.append(.value(items[index], depth: childDepth, compact: compact))
                        let prefix = compact
                            ? (index == 0 ? "" : ",")
                            : "\(index == 0 ? "\n" : ",\n")"
                                + String(repeating: jsonIndent, count: childDepth)
                        tasks.append(.text(prefix))
                    }
                case .object(let fields):
                    let compact = wasCompact || (depth + 1) * jsonIndent.count > maxJsonIndentChars
                    let childDepth = depth + 1
                    chunks.append("{")
                    if fields.isEmpty {
                        chunks.append("}")
                        continue
                    }
                    tasks.append(.text(compact ? "}"
                        : "\n\(String(repeating: jsonIndent, count: depth))}"))
                    let keys = fields.keys.sorted()
                    for index in stride(from: keys.count - 1, through: 0, by: -1) {
                        let key = keys[index]
                        guard let item = fields[key] else { continue } // 不可达：键取自本表
                        tasks.append(.value(item, depth: childDepth, compact: compact))
                        let prefix = compact
                            ? "\(index == 0 ? "" : ",")\(CodeRuntimeSeam.jsonQuoted(key)):"
                            : "\(index == 0 ? "\n" : ",\n")"
                                + String(repeating: jsonIndent, count: childDepth)
                                + "\(CodeRuntimeSeam.jsonQuoted(key)): "
                        tasks.append(.text(prefix))
                    }
                }
            }
        }
        return chunks.joined()
    }

    /// JS String(number) 的 Swift 近似（P2 jsNumberString 同形；整数不落
    /// .0，指数补零差异登记——render-only 呈现面）。
    static func doubleString(_ value: Double) -> String {
        guard value.isFinite else { return "null" } // 防御：无损 JSON 面不可达
        if value == value.rounded() && abs(value) < 1e21 {
            return String(Int64(value))
        }
        return String(value)
    }
}

// MARK: - run_code 工具（ptc.ts:293-678 createRunCodeTool）

/// PTC mode 工具本体：模型写 TypeScript 程序，经 `tools.<name>(args)` 桥到
/// 注册表可见工具的嵌套执行（native 并发契约下单车道调度）；每个子派发以
/// ptc-dispatch-start/ptc-dispatch 事件对留痕，仅外层策划后的结果进模型
/// 历史（ptc.ts 模块 doc 逐句）。
struct RunCodeTool: AgentTool {
    /// ptc.ts:20 RUN_CODE_NAME 逐字。
    static let runCodeName = "run_code"

    let name = Self.runCodeName
    /// 静态 spec 的 description（ptc.ts:303 占位语义——WanWo 单语言恒
    /// TYPESCRIPT_FLAVOR，登记②）。
    let description = RunCodeFlavor.typescript.description

    /// 参数 schema（ptc.ts:304-311：required code+description，双文案与
    /// flavor 同源）。
    let parameters: JSONValue = .schemaObject(properties: [
        "code": .stringSchema(description: RunCodeFlavor.typescript.codeDescription),
        "description": .stringSchema(description: RunCodeFlavor.descriptionParamDescription),
    ], required: ["code", "description"])

    /// 无工具级 deadline（dsh defineTool 缺省；程序预算由 runtime 配置持有）。
    let timeoutMs: Int? = nil

    // MARK: 注入缝（ptc.ts:266-280 RunCodeBridgeOptions，登记⑤）

    /// 子派发管线（裁定①：ToolPipeline 复用——hooks 跑、对话事件不落）。
    let pipeline: ToolPipeline
    /// ptc-dispatch 事件落盘（E1 通道）。
    let writer: SessionWriter
    /// 代码运行时（P2 JSCodeRuntime；requireRuntime 单语言简化，登记②）。
    let runtime: CodeRuntimeProtocol
    /// 并行类子调用重叠帽（ptc.ts:277——registry 传入的 validated
    /// maxParallelSubCalls；装配缺省 10）。
    let maxParallelSubCalls: Int

    private static let logger = AppLogger(category: "RunCodeTool")

    init(pipeline: ToolPipeline,
         writer: SessionWriter,
         runtime: CodeRuntimeProtocol,
         maxParallelSubCalls: Int = 10) {
        self.pipeline = pipeline
        self.writer = writer
        self.runtime = runtime
        self.maxParallelSubCalls = maxParallelSubCalls
    }

    // MARK: 双快照（ptc.ts:150-166，登记③）

    /// 派发/落盘两份独立实参。JSONValue 值类型语义 → 恒等即可（语义复制
    /// 天然独立，"SIBLING parse" 隔离成立）；三条拒文在类型面不可达。
    static func jsonNormalizeArgs(_ value: JSONValue)
        -> (dispatched: JSONValue, logged: JSONValue) {
        (value, value)
    }

    // MARK: presentCall（ptc.ts:650-655，登记⑬）

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .generic,
                       title: args.objectValue?["description"]?.stringValue ?? "",
                       detail: args.objectValue?["code"]?.stringValue)
    }
    // presentResult 刻意不接（dsh :656-658：generic 卡兜底读持久结果）。

    // MARK: execute（ptc.ts:327-647）

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // ptc.ts:328-330——description 非空校验（文案逐字；缺失同拒，登记⑫）。
        let description = args.objectValue?["description"]?.stringValue
        guard let description,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("invalid description: expected a non-empty string")
        }
        // schema required 兜底（dsh defineTool 参数校验同位；WanWo 无声明
        // 面校验器，工具体自检）。
        guard let code = args.objectValue?["code"]?.stringValue else {
            return .failure("missing required parameter \"code\"", code: "INVALID_ARGS")
        }

        let scope = RunCodeRunScope()
        let lane = makeLane(scope: scope, ctx: ctx)

        // ptc.ts:337-345 run-scoped abort（登记⑥）：外层取消入 → abort
        //（"canceled"）；run 落定 → finally abort("run_code settled")。
        return await withTaskCancellationHandler {
            await runProgram(code: code, ctx: ctx, scope: scope, lane: lane)
        } onCancel: {
            scope.abort(reason: "canceled")
        }
    }

    // MARK: 车道装配（ptc.ts:357-456 的闭包面）

    private func makeLane(scope: RunCodeRunScope,
                          ctx: ToolExecutionContext) -> PtcDispatchLane {
        let registry = pipeline.registry
        let parentCallId = ctx.callId
        let writer = self.writer
        return PtcDispatchLane(
            maxParallel: maxParallelSubCalls,
            scope: scope,
            // ptc.ts:529——启动前按 registry 现状重分类（fail closed）。
            classify: { entry in
                registry.executionMode(name: entry.name, args: entry.argsDispatched)
            },
            // body = 子派发管线全量（裁定①）；上下文只换 callId（登记⑭）。
            runBody: { entry in
                let subCtx = ToolExecutionContext(
                    sessionId: ctx.sessionId,
                    turn: ctx.turn,
                    step: ctx.step,
                    callId: entry.subCallId,
                    workspace: ctx.workspace,
                    spill: ctx.spill,
                    onShellLine: ctx.onShellLine,
                    completeLLM: ctx.completeLLM,
                    sandboxMode: ctx.sandboxMode,
                    escalationApprover: ctx.escalationApprover)
                return await pipeline.run(toolName: entry.name,
                                          args: entry.argsDispatched,
                                          ctx: subCtx,
                                          isSubDispatch: true)
            },
            // start 事件（ptc.ts:534-540——rootCallId/parentCallId/subCallId/
            // name/arguments(logged) 1:1；rootCallId=parentCallId，登记⑭）。
            appendStart: { entry in
                try await PtcDispatchEvents.appendDispatchStart(
                    to: writer,
                    rootCallId: parentCallId,
                    parentCallId: parentCallId,
                    subCallId: entry.subCallId,
                    name: entry.name,
                    arguments: entry.argsLogged)
            },
            // settle 事件（ptc.ts:498-521——isError + content（tool/result
            // 同词汇的单 text 块，登记⑰）；append 失败记日志不回滚）。
            appendSettle: { entry, output in
                do {
                    _ = try await PtcDispatchEvents.appendDispatch(
                        to: writer,
                        rootCallId: parentCallId,
                        parentCallId: parentCallId,
                        subCallId: entry.subCallId,
                        name: entry.name,
                        arguments: entry.argsLogged,
                        isError: output.isError,
                        content: .object([
                            "type": .string("text"),
                            "text": .string(output.text),
                        ]))
                } catch {
                    Self.logger.error("ptc-dispatch append failed for "
                                      + "\(entry.subCallId): \(String(describing: error))")
                }
            })
    }

    // MARK: 程序运行（ptc.ts:606-643）

    private func runProgram(code: String,
                            ctx: ToolExecutionContext,
                            scope: RunCodeRunScope,
                            lane: PtcDispatchLane) async -> ToolOutput {
        // functions 集（ptc.ts:606-614）：枚举 registry 可见集、跳过 run_code
        // 本名；Swift 字典 own-key 天然等价（P1 登记③同源）。
        var functions: [String: CodeBindingFunction] = [:]
        let counter = PtcDispatchCounter()
        for schema in pipeline.registry.schemas() where schema.name != Self.runCodeName {
            functions[schema.name] = makeBinding(name: schema.name, ctx: ctx,
                                                 scope: scope, lane: lane,
                                                 counter: counter)
        }

        // ptc.ts:619-627——runtime.run{program, bindings:[tools], errorClass
        // {name:'ToolCallError', memberNameProperty:'toolName'} 逐字}。
        let result = await runtime.run(CodeRunRequest(
            program: code,
            bindings: [CodeBindingNamespace(
                global: "tools",
                functions: functions,
                errorClass: CodeBindingErrorClass(name: "ToolCallError",
                                                  memberNameProperty: "toolName"))]))

        // ptc.ts:628-634 finally——先燃 run 作用域（在飞 body 协作收敛、
        // 队列未启动弃单），再等车道静默（settle 事件全部落盘——事件恒在
        // run_code 开放回合内，types.ts:52-54）。
        scope.abort(reason: "run_code settled")
        await lane.drain()

        // ptc.ts:636-638——CodeRunFailedError 文案逐字（error 是字段不是
        // rejection；WanWo 结构化失败形态交付，code/name 随行）。
        if let error = result.error {
            let logsText = result.logs.isEmpty
                ? ""
                : "\nCaptured output:\n\(result.logs.joined(separator: "\n"))"
            return ToolOutput.failure(
                "code run failed (\(error.kind.rawValue)): \(error.message)\(logsText)",
                code: CodeRunFailedError.code,
                name: CodeRunFailedError.errorName)
        }

        // ptc.ts:640-643 + :321-325 render——logs.join('\n') + rendered，
        // 空段滤除，全空态文案逐字。
        let joinedLogs = result.logs.joined(separator: "\n")
        let rendered = result.value.map { JSONRender.renderValue($0) } ?? ""
        var parts: [String] = []
        if !joinedLogs.isEmpty { parts.append(joinedLogs) }
        if !rendered.isEmpty { parts.append(rendered) }
        return .success(parts.isEmpty ? "(run_code completed with no output)"
                                      : parts.joined(separator: "\n"))
    }

    // MARK: binding 工厂（ptc.ts:463-599）

    private func makeBinding(name: String,
                             ctx: ToolExecutionContext,
                             scope: RunCodeRunScope,
                             lane: PtcDispatchLane,
                             counter: PtcDispatchCounter) -> CodeBindingFunction {
        return { args in
            // ptc.ts:464-466——run 已落定/中止：不派发（文案逐字）。
            if scope.isAborted() {
                throw RunCodeBindingError(message:
                    "run_code run is over (\(scope.abortReason())); \(name) not dispatched")
            }
            // ptc.ts:467——双快照（登记③）。
            let normalized = RunCodeTool.jsonNormalizeArgs(args)
            // ptc.ts:468-469——提交序编号 + subCallId 形态逐字。
            let n = counter.next()
            let subCallId = "\(ctx.callId):ptc:\(n)"
            let entry = PtcDispatchEntry(name: name, subCallId: subCallId,
                                         argsDispatched: normalized.dispatched,
                                         argsLogged: normalized.logged)
            // ptc.ts:584-586——提交进车道，等待结算（弃单/落盘失败经 reject）。
            await lane.submit(entry)
            let output = try await entry.awaitOutcome()
            // ptc.ts:591-593——结算后重读 runOver：来自已终结 run 的产出
            // 丢弃（文案逐字）。
            if scope.isAborted() {
                throw RunCodeBindingError(message:
                    "run_code run is over (\(scope.abortReason())); \(name) result discarded")
            }
            // ptc.ts:597——isError 产出 = binding 拒绝（worker 物化为
            // ToolCallError，memberNameProperty 'toolName' 暴露成员名；
            // 文本 = 模型可见失败面全量）。
            if output.isError {
                throw RunCodeBindingError(message: output.text)
            }
            // 值面（登记⑪）：子调用产出文本以 JSON string 交付程序。
            return .string(output.text)
        }
    }
}

// MARK: - 引擎面包屑事件（真机批 B1）

/// JSCore 引擎面包屑的事件通道（诊断导出面；logOnly——不进模型上下文）。
/// JSCodeRuntime 的 onTrace 回调经装配接 writer，事件流导出即含 `[jscore]`
/// 打点，run_code 挂死取证用。
enum JscoreTraceEvents {
    static let traceKind = "jscore/trace"

    static func registerEventSchemas() {
        let registry = ExtensionEventRegistry.shared
        guard !registry.isRegistered(traceKind) else { return }
        registry.register(ExtensionEventSchema(
            kind: traceKind,
            requiredFields: [ExtensionFieldSchema("note", .string)],
            projection: .logOnly,
            pairing: .none))
    }
}

/// 全方位诊断事件（真机批 B：通知/调度/引擎各面打点的统一通道——
/// logOnly 不进模型上下文；AppEnvironment.diagTrace 写入）。
enum DiagTraceEvents {
    static let traceKind = "diag/trace"

    static func registerEventSchemas() {
        let registry = ExtensionEventRegistry.shared
        guard !registry.isRegistered(traceKind) else { return }
        registry.register(ExtensionEventSchema(
            kind: traceKind,
            requiredFields: [ExtensionFieldSchema("note", .string)],
            projection: .logOnly,
            pairing: .none))
    }
}
