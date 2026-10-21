//
//  GuestRunService.swift
//  WanWo
//
//  【N9b · build_and_run 运行时承载】guest 进程 spawn/stdio 回流/退出码收尾
//  的万我层编排（万我自有代码，零 vendored 改动——登记 docs/gpl-compliance
//  .md §N9/§N10）。官方对照（0.10.3 Builder.swift:321-349 + PEProcess.m:269-284）：
//    · 管道编排：Pipe→FDMapObject.emptyMap + appendFileDescriptor——
//      inPipe.read→STDIN / outPipe.write→STDOUT+STDERR / 持活 fd 100/101
//     （官方注释：防对端关闭杀读）；spawn 后宿主端 Pipe 句柄保持打开，
//      guest 退出→其副本关闭→宿主 read EOF→读循环自然收束。
//    · spawn：PEProcessManager.spawnProcess(withBundleIdentifier:withItems:
//      withKernelSurfaceProcess:doRestartIfRunning:)——items 携带
//      PEMapObject；kernelSurfaceProcess 传 nil（官方同参，落到 kernel_proc_）。
//    · 退出码：exitingCallback（PEProcess.m:284 exitingCallback 钩子——
//      processDidExit→proc_state_change(legacyCode) 同点触发）内读
//      FBProcess.exitContext.underlyingContext.legacyCode（wait4 状态原值，
//      UIKitPrivate.h:170/176 声明面）——低 7 位非零=signal，否则 (raw>>8)
//      &0xFF=exit code；原值一并上报。
//    · 输出流：行级回调接 ctx.onShellLine 缝（bash 工具同缝——工具卡实时
//      追加；0.2s 节流在 UI 侧）；run_log 落盘 Cache/<uuid>/run_log.txt。
//
//  【N10d · C v2 运行会话解耦（用户拍板 10-20 23:47）】结构性矛盾修复：
//  N9 层的「阻塞等待+timeout_ms」编排（官方 .run 本体不等待退出——
//  NXBuilder.swift:294-358 install 完成即 completion 返回，全文零等待/零
//  超时杀）在 N10 浮窗化后与「guest=模拟器式常驻交互面」冲突（手动交互时
//  AI 在工具里干等；自动化场景 AI 每走下一步必须先杀死被测对象）。拆分：
//    · spawnRun（同步段）：管道编排+spawn+登记+run_log 头+读循环启动——
//      工具 spawn 成功即返回（pid 随返）。
//    · GuestRunSession 常驻段（后台队列）：等退出（C-a 拍板默认**不限时**，
//      timeout_ms 可选为保护上限——到点 terminate）→ 收尾（run_log footer→
//      A2 窗口清空判定隐藏→endRun→guest_run 退出事件 modelVisible）。
//    · 退出三态（B 拍板）：①自然退出（exitCode）②超时（timedOut 文案）
//      ③被终止——stop_build（stopRequested 标志）与外部终止（排除法——
//      浮窗关闭钮=终止进程，官方 NXWindowSessionApplication.m:121-135
//      closeWindow 内 [_process terminate] 官方语义）细分。
//    · writer 注入：收尾发生在工具返回后——SessionWriter 为 @unchecked
//      Sendable（append 经 gate NSLock+continuation 串行化，生命周期独立
//      于工具调用），RunSession 持强引用在收尾 Task 中 append 退出事件
//      （工具返回后 append 已核验安全——SessionWriter.swift:67-162）。
//
//  swiftc 雷区纪律：构造器参数位无内嵌复杂表达式、无嵌套函数（全部平铺
//  private/static func）、多行插值拆单步拼接。
//

import Foundation

// MARK: - 事件注册（extensionEvent 通道；装配期幂等，v2.4 报批流程登记）

/// guest run 生命周期事件（BuildEvents.register 装配点同步注册；投影
/// modelVisible——退出码/失败原因进派生历史，AI 下一回合可读，build kind 同款）。
enum RunEvents {
    static let eventKind = "guest_run"

    static func register() {
        let registry = ExtensionEventRegistry.shared
        guard !registry.isRegistered(eventKind) else { return }
        registry.register(ExtensionEventSchema(
            kind: eventKind,
            requiredFields: [
                ExtensionFieldSchema("name", .string),
                ExtensionFieldSchema("result", .string),     // "success" | "failure"
                ExtensionFieldSchema("phase", .string),      // "build" | "prepare" | "spawn" | "exit"
                ExtensionFieldSchema("exit", .string),       // 退出注记（exit=N / signal=N / raw=N / "-"）
                ExtensionFieldSchema("runLog", .string),
                ExtensionFieldSchema("diagnostics", .string),
            ],
            projection: .modelVisible))
    }
}

// MARK: - 退出状态盒（exitingCallback 任意队列触发——NSLock 保护）

final class GuestExitBox: @unchecked Sendable {
    let lock = NSLock()
    /// wait4 状态原值（FBProcess.exitContext.underlyingContext.legacyCode）。
    var rawStatus = -1
    var exitCode = -1
    var signal = 0
    var decoded = false

    /// wait4 状态解码：低 7 位非零=被信号终止（signal=低 7 位，exitCode 置 -1）；
    /// 否则 exitCode=(raw>>8)&0xFF（WEXITSTATUS 语义）。
    func store(raw: Int) {
        lock.lock(); defer { lock.unlock() }
        rawStatus = raw
        if raw >= 0 {
            if (raw & 0x7F) != 0 {
                signal = raw & 0x7F
                exitCode = -1
            } else {
                exitCode = (raw >> 8) & 0xFF
                signal = 0
            }
            decoded = true
        }
    }
}

// MARK: - spawn 结果（C v2：spawn 同步段返回盒）

struct GuestRunSpawnResult {
    let ok: Bool
    let message: String
    let pid: Int
    /// run_log 路径（spawn 前失败为空串——事件 runLog 字段占位用）。
    let runLogPath: String
    let session: GuestRunSession?

    static func failure(_ message: String) -> GuestRunSpawnResult {
        return GuestRunSpawnResult(ok: false, message: message, pid: -1,
                                   runLogPath: "", session: nil)
    }
}

// MARK: - 运行会话（C v2：常驻收尾段的状态盒）

/// 一次 guest 运行的常驻会话：spawn 成功后由后台队列继续读管道+等退出+收尾
/// （工具层 spawn 成功即返回——C v2 解耦本体）。@unchecked Sendable：并发面
/// 说明——tailLines/tailLock 由读队列与收尾段经 tailLock 串行；timedOut 仅
/// 会话队列写读（同队列串行）；stopRequested 由 stop_build 路径在 service
/// lock 内置位、收尾段在 tailLock 内读取（benign bool 语义，timedOut 优先）。
final class GuestRunSession: @unchecked Sendable {
    let pid: Int
    let bundleID: String
    let projectName: String
    let process: PEProcess
    let exitBox = GuestExitBox()
    let exitSemaphore = DispatchSemaphore(value: 0)
    let tailLock = NSLock()
    var tailLines: [String] = []
    /// nil = 不限时（C-a 拍板默认）；非 nil = 保护上限（到点 terminate→timedOut）。
    let timeoutSeconds: TimeInterval?
    let runLogPath: String
    let logHandle: FileHandle?
    let writer: SessionWriter
    let workspaceRoot: URL
    let prepDetail: String
    let onLine: @Sendable (String) -> Void
    /// 超时标志（会话队列私有——到点 terminate 后置位）。
    var timedOut = false
    /// stop_build 终止标志（stopActiveRun 在 service lock+tailLock 内置位）。
    var stopRequested = false

    init(pid: Int,
         bundleID: String,
         projectName: String,
         process: PEProcess,
         timeoutSeconds: TimeInterval?,
         runLogPath: String,
         logHandle: FileHandle?,
         writer: SessionWriter,
         workspaceRoot: URL,
         prepDetail: String,
         onLine: @escaping @Sendable (String) -> Void) {
        self.pid = pid
        self.bundleID = bundleID
        self.projectName = projectName
        self.process = process
        self.timeoutSeconds = timeoutSeconds
        self.runLogPath = runLogPath
        self.logHandle = logHandle
        self.writer = writer
        self.workspaceRoot = workspaceRoot
        self.prepDetail = prepDetail
        self.onLine = onLine
    }
}

// MARK: - GuestRunService

final class GuestRunService: @unchecked Sendable {

    static let shared = GuestRunService()

    /// 活跃 guest 登记（stop_build 接缝——run 态下终止当前 guest 进程）。
    private let lock = NSLock()
    private var activeProcess: PEProcess?
    private var activeBundleID = ""
    /// 【C v2】活跃运行会话（app 路线——收尾段/endRun/重复运行报错的信息源；
    /// utility 路线无会话（开窗即返），登记仅进程）。
    private var activeSession: GuestRunSession?

    // ── 【N10e 修 F/G】utility 终端路线登记扩展（lock 内读写——exiting-
    // callback 任意线程触发）────────────────────────────────────────────
    /// 工程名（退出事件 name 字段——登记时存）。
    private var utilityProjectName = ""
    /// 终端窗口 id（关窗链——closeTerminalWindowWithIdentifier 消费）。
    /// （id_t 导入为 UInt32——无效窗 id 用 UInt32.max 哨兵，与官方 (id_t)-1
    /// 语义一致：closeWindowWithIdentifier 字典查不到即 no-op。）
    private var utilityWindowIdentifier: id_t = UInt32.max
    /// raw 输出 tee（unregister 时写 footer——修 I）。
    private var utilityTeeLog: UtilityTeeLog?
    /// prepare 细目（退出事件 diagnostics 前缀——登记时存）。
    private var utilityPrepDetail = ""
    /// 退出事件发射 writer（unregister 后置 nil 防泄漏——修 G）。
    private var utilityWriter: SessionWriter?
    /// wait4 状态原值（exitingCallback 包装采集——-1=未退出/不可得）。
    private var utilityExitRaw = -1
    /// stop_build 终止标志（stopActiveRun 置位——退出事件 result 区分）。
    private var utilityStopRequested = false

    /// 终止活跃 guest（stop_build 在 run 态下的转语义）。返回说明文案。
    func stopActiveRun() -> String {
        lock.lock()
        let proc = activeProcess
        let bid = activeBundleID
        let session = activeSession
        var isUtility = false
        if let session = session {
            // B 三态之一：stop_build 终止标志（收尾段据此区分外部终止）。
            session.tailLock.lock()
            session.stopRequested = true
            session.tailLock.unlock()
        } else if proc != nil {
            // 【N10e 修 F/G】utility 路线 stop 标志（退出事件 result=failure
            // +「已被 stop_build 终止」文案的依据）。
            utilityStopRequested = true
            isUtility = true
        }
        lock.unlock()
        guard let proc = proc else {
            return "无活跃 guest 进程登记（run 门在持但进程未注册/已退出）"
        }
        _ = proc.terminate()
        var note = "terminate 已发出（SIGKILL——官方 PEProcess.terminate 语义）guest=" + bid
        if isUtility {
            note = note + "；utility 进程退出后终端窗自动关闭（和 app 路线一致——修 F），"
            note = note + "guest_run 退出事件回报退出形态（修 G）"
        } else {
            note = note + "；退出后由 RunSession 收尾（run_log footer→A2 窗口收尾→endRun→guest_run 退出事件）"
        }
        return note
    }

    /// 【N10c】utility 终端路线的进程登记（stop_build 接缝）。utility 的
    /// run 门不长期持有（官方 Builder.swift:367-370 开窗即返回），stop_build
    /// 接线以活跃进程登记为准（BuildAndRunTool 在终端开窗成功后登记）。
    /// 终端窗口关闭=进程 terminate（官方 closeWindow 同款——vendored
    /// NXWindowSessionTerminal.m:203-214 官方原样）。
    /// 【N10e 修 F/G/I】登记扩展：窗口 id（关窗链）+工程名/prep 细目/writer
    /// （退出事件——unregister 时发）+raw 输出 tee（unregister 时写 footer）。
    func registerUtilityProcess(_ process: PEProcess,
                                utilityPath: String,
                                projectName: String,
                                windowIdentifier: id_t,
                                teeLog: UtilityTeeLog?,
                                prepDetail: String,
                                writer: SessionWriter) {
        lock.lock()
        activeProcess = process
        activeBundleID = (utilityPath as NSString).lastPathComponent
        utilityProjectName = projectName
        utilityWindowIdentifier = windowIdentifier
        utilityTeeLog = teeLog
        utilityPrepDetail = prepDetail
        utilityWriter = writer
        utilityExitRaw = -1
        utilityStopRequested = false
        lock.unlock()
    }

    /// 【N10e 修 G】utility 退出状态采集（BuildAndRunTool 挂的 exitingCallback
    /// 包装在官方回调之后调用——任意线程，lock 内写入）。
    func noteUtilityExitRaw(_ raw: Int) {
        lock.lock()
        utilityExitRaw = raw
        lock.unlock()
    }

    /// 【N10c】utility 进程注销（BuildAndRunTool 挂的 exitingCallback 包装
    /// 在官方回调+关窗 dispatch 之后调用——进程退出即清登记，stop_build 不再
    /// 打僵尸进程）。
    /// 【N10e 修 F/G/I】注销序：清登记（含 writer/tee 置 nil 防泄漏）→ tee
    /// footer（run end + 退出注记）→ guest_run 退出事件（modelVisible——
    /// app 路线 RunSession finalize 字段对齐）→ A2 窗口清空判定隐藏（关窗链
    /// 0.25s 动画+字典拆除——1.0s 余量后判定，既有余量语义不变）。
    func unregisterUtilityProcess() {
        lock.lock()
        let tee = utilityTeeLog
        let raw = utilityExitRaw
        let stopRequested = utilityStopRequested
        let projectName = utilityProjectName
        let prepDetail = utilityPrepDetail
        let writer = utilityWriter
        activeProcess = nil
        activeBundleID = ""
        utilityProjectName = ""
        utilityWindowIdentifier = UInt32.max
        utilityTeeLog = nil
        utilityPrepDetail = ""
        utilityWriter = nil
        utilityExitRaw = -1
        utilityStopRequested = false
        lock.unlock()

        // 退出注记（事件 exit 字段/tee footer 同源文案）。
        let exitNote = Self.renderUtilityExitNote(raw: raw)

        // 修 I：tee footer（同队列 FIFO——排在全部输出分块之后；进程死亡的
        // 收尾字节流若晚于 footer 到达为已知微小竞态，观测语义可接受）。
        if let tee = tee {
            let footer = "run end " + ISO8601DateFormatter().string(from: Date())
                + " " + exitNote + "\n"
            tee.writeFooter(footer)
        }

        // 修 G：退出事件（app 路线 finalizeRunSession 事件链对齐——modelVisible；
        // writer 在 unregister 后不再持有——Task 局部强引用消费完即释放）。
        let outcome = Self.composeUtilityExitMessage(raw: raw, stopRequested: stopRequested)
        var diagnostics = prepDetail
        if !diagnostics.isEmpty {
            diagnostics = diagnostics + "；"
        }
        diagnostics = diagnostics + outcome.message
        var runLogField = "-（TTY 直连无 run_log——输出见终端窗口）"
        if let tee = tee {
            runLogField = tee.path + "（utility 终端 raw 输出 tee 工作区副本）"
        }
        if let writer = writer {
            let eventName = projectName
            let eventExit = exitNote
            let eventRunLog = runLogField
            let eventDiagnostics = String(diagnostics.prefix(2000))
            Task {
                _ = try? await writer.append(.extensionEvent(
                    kind: RunEvents.eventKind,
                    payload: .object([
                        "name": .string(eventName),
                        "result": .string(outcome.result),
                        "phase": .string("exit"),
                        "exit": .string(eventExit),
                        "runLog": .string(eventRunLog),
                        "diagnostics": .string(eventDiagnostics),
                    ])))
            }
        }

        // （Swift 导入名：ObjC hideGuestOverlayIfNoWindowsAfterDelay: →
        //  hideGuestOverlayIfNoWindows(afterDelay:)——CI 实证，按导入名调用）
        GuestWindowBridge.hideGuestOverlayIfNoWindows(afterDelay: 1.0)
    }

    /// 是否有活跃 guest 进程登记（app run 门路径 / utility 终端路径通用）。
    var hasActiveRegisteredProcess: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeProcess != nil
    }

    /// 【N10d · C-b】活跃运行会话信息（重复运行报错文案与 run 门失败提示：
    /// 「guest 运行中（pid=X 工程=Y）——stop_build 终止或等其退出」）。仅 app
    /// 路线的 RunSession 有会话；utility 路线（开窗即返）返回 nil。
    func activeRunInfo() -> (pid: Int, projectName: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let session = activeSession else { return nil }
        return (session.pid, session.projectName)
    }

    /// 【C v2 · spawn 同步段】执行一次 guest 拉起并启动常驻会话（管道编排/
    /// spawn/登记/run_log 头/读循环启动；等待与收尾交后台队列——调用方
    /// spawn 成功即返回）。前提：prepareGuestRun 已成功（补片/容器签名/
    /// token/安装齐备）；run 门已由调用方持有（endRun 归收尾段）。
    /// 须在专用队列上跑（ensureActivatedSync 内部 dispatch_sync 主队列——
    /// 禁占协作线程池）。timeoutSeconds 传 nil = 不限时（C-a 拍板默认）。
    @discardableResult
    func spawnRun(project: NXProject,
                  projectName: String,
                  bundleID: String,
                  timeoutSeconds: TimeInterval?,
                  prepDetail: String,
                  onLine: @escaping @Sendable (String) -> Void,
                  writer: SessionWriter,
                  workspaceRoot: URL) -> GuestRunSpawnResult {
        guard !bundleID.isEmpty else {
            return GuestRunSpawnResult.failure("guest bundle id 缺失（无法 spawn）")
        }
        guard let manager = PEProcessManager.shared() else {
            return GuestRunSpawnResult.failure(
                "PEProcessManager 不可用（宿主运行面未初始化——App 启动链异常？）")
        }

        // ── N10b：窗口宿主激活（管道+窗口双形态）────────────────────────
        // 官方 Builder.swift:321-349 .run app 段同形态：FDMapObject 管道照旧
        // + 窗口会话叠加——窗口不是万我层另开，而是 vendored PEProcess（零
        // diff）scene:didCompleteUpdateWithContext:（PEProcess.m:243-267）在
        // guest FBScene 到达时 dispatch_once 自动 NXWindowSessionApplication
        // →openWindowWithSession（进程退出自动关窗 :286-294）。本调用只保证
        // NXWindowServer 单例先于 spawn 以真实 scene 初始化（dispatch_once
        // 单例：若先经 shared 无 scene 形态懒创建，windowScene 恒 nil →
        // session openWindow 恒败——N10 方案 §三 1 时序语义）。
        GuestWindowBridge.ensureActivatedSync()

        // ── 管道编排（官方 Builder.swift:322-346 逐行对照）────────────
        let inPipe = Pipe()
        let outPipe = Pipe()
        guard let map = FDMapObject.emptyMap() else {
            return GuestRunSpawnResult.failure("FDMapObject.emptyMap 创建失败")
        }
        _ = map.appendFileDescriptor(inPipe.fileHandleForReading.fileDescriptor,
                                     withMappingToLoc: STDIN_FILENO)
        _ = map.appendFileDescriptor(outPipe.fileHandleForWriting.fileDescriptor,
                                     withMappingToLoc: STDOUT_FILENO)
        _ = map.appendFileDescriptor(outPipe.fileHandleForWriting.fileDescriptor,
                                     withMappingToLoc: STDERR_FILENO)
        // 持活 fd 100/101（官方注释：someone has to hold the receive pipes
        // even if we close them——防打印进程被杀读）
        _ = map.appendFileDescriptor(inPipe.fileHandleForWriting.fileDescriptor,
                                     withMappingToLoc: 100)
        _ = map.appendFileDescriptor(outPipe.fileHandleForReading.fileDescriptor,
                                     withMappingToLoc: 101)

        // ── spawn（官方 Builder.swift:348 同参）────────────────────────
        // （spawnProcess 返回 pid_t/Int32——pid 以 Int 收敛供会话/文案统一
        //  使用；process(forProcessIdentifier:) 仍取原始 Int32 形态）
        let items: [AnyHashable: Any] = ["PEMapObject": map]
        let spawnedPid: pid_t = manager.spawnProcess(withBundleIdentifier: bundleID,
                                                     withItems: items,
                                                     withKernelSurfaceProcess: nil,
                                                     doRestartIfRunning: true)
        let pid = Int(spawnedPid)
        guard pid > 0 else {
            let msg = "spawnProcess 失败（pid=" + String(pid) + "）——可查 installd 注册态"
                + "（pe_smoke）与 LDEApplicationObject.isLaunchAllowed（工程未安装/被卸载？）"
            return GuestRunSpawnResult.failure(msg)
        }
        guard let process = manager.process(forProcessIdentifier: spawnedPid) else {
            let msg = "spawn 返回 pid=" + String(pid) + " 但无 PEProcess 记录（进程秒退？）"
            return GuestRunSpawnResult.failure(msg)
        }

        // 宿主端写端关闭（官方注释 sanctioned——"even if we close them"：
        // xpc_fd_create 在 appendFileDescriptor 时已捕获 fileport 右——
        // FDObject.m:45/FDMapObject.m:126，guest 侧副本持活管道；guest 退出
        // →副本关闭→宿主读端 EOF→读循环自然收束，不依赖宿主端句柄）
        try? outPipe.fileHandleForWriting.close()

        // ── run_log 落盘（Cache/<uuid>/run_log.txt——N8c 折叠教训对策）──
        let logURL = project.cacheURL.appendingPathComponent("run_log.txt")
        let runLogPath = logURL.path
        let isoStamp = ISO8601DateFormatter().string(from: Date())
        var header = "run start " + isoStamp + " bundle=" + bundleID
            + " pid=" + String(pid)
        if let t = timeoutSeconds {
            header = header + " timeout=" + String(Int(t)) + "s"
        } else {
            header = header + " timeout=none（不限时——C v2 拍板默认）"
        }
        header = header + "\n"
        if !FileManager.default.fileExists(atPath: runLogPath) {
            FileManager.default.createFile(atPath: runLogPath, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.seekToEnd()
        try? logHandle?.write(contentsOf: Data(header.utf8))

        // ── 会话组装 + 活跃登记（stop_build 接缝）─────────────────────
        let session = GuestRunSession(
            pid: pid,
            bundleID: bundleID,
            projectName: projectName,
            process: process,
            timeoutSeconds: timeoutSeconds,
            runLogPath: runLogPath,
            logHandle: logHandle,
            writer: writer,
            workspaceRoot: workspaceRoot,
            prepDetail: prepDetail,
            onLine: onLine)
        lock.lock()
        activeProcess = process
        activeBundleID = bundleID
        activeSession = session
        lock.unlock()

        // ── 退出回调（官方 exitingCallback 钩子同点——先官方语义采集再
        //    signal；收尾由会话队列在 semaphore 之后执行=先官方后万我序）──
        process.exitingCallback = { [weak process] in
            var raw = -1
            if let strong = process {
                let ctxAny: Any? = strong.process?.exitContext
                if let exitCtx = ctxAny as? FBProcessExitContext {
                    raw = Int(exitCtx.underlyingContext.legacyCode)
                }
            }
            session.exitBox.store(raw: raw)
            session.exitSemaphore.signal()
        }

        // ── stdout/stderr 读循环（后台队列；行级 onShellLine——UI 侧节流）─
        let lineFormatter = DateFormatter()
        lineFormatter.dateFormat = "HH:mm:ss.SSS"
        let outHandle = outPipe.fileHandleForReading
        let readQueue = DispatchQueue(label: "wanwo.guestrun.stdout")
        let logHandleRef = logHandle
        readQueue.async {
            var pending = Data()
            // 循环：availableData 阻塞至有数据或全写端关闭（guest 退出→EOF）。
            while true {
                let data = outHandle.availableData
                if data.isEmpty { break }
                pending.append(data)
                while pending.firstIndex(of: UInt8(0x0A)) != nil {
                    guard let nl = pending.firstIndex(of: UInt8(0x0A)) else { break }
                    let lineData = pending.subdata(in: pending.startIndex..<nl)
                    pending.removeSubrange(pending.startIndex...nl)
                    let text = String(data: lineData, encoding: .utf8) ?? ""
                    let clean = OutputSanitizer.sanitizeTerminalOutput(text)
                    if !clean.isEmpty {
                        onLine(clean)
                        session.tailLock.lock()
                        session.tailLines.append(clean)
                        if session.tailLines.count > 200 {
                            session.tailLines.removeFirst(session.tailLines.count - 200)
                        }
                        session.tailLock.unlock()
                        let lineStamp = lineFormatter.string(from: Date())
                        let logText = "[" + lineStamp + "] " + clean + "\n"
                        try? logHandleRef?.write(contentsOf: Data(logText.utf8))
                    }
                }
            }
            // EOF 收尾：残留无换行的末行落账
            if !pending.isEmpty {
                let text = String(data: pending, encoding: .utf8) ?? ""
                let clean = OutputSanitizer.sanitizeTerminalOutput(text)
                if !clean.isEmpty {
                    onLine(clean)
                    session.tailLock.lock()
                    session.tailLines.append(clean)
                    session.tailLock.unlock()
                    let lineStamp = lineFormatter.string(from: Date())
                    let logText = "[" + lineStamp + "] " + clean + "\n"
                    try? logHandleRef?.write(contentsOf: Data(logText.utf8))
                }
            }
        }

        // ── 常驻等待+收尾段（后台队列——工具已返回；C v2 解耦本体）─────
        let sessionQueue = DispatchQueue(label: "wanwo.guestrun.session." + String(pid))
        sessionQueue.async { [weak self] in
            self?.waitForAndFinalize(session)
        }

        let okMsg = "spawn 成功（RunSession 常驻——退出后收尾回报）"
        return GuestRunSpawnResult(ok: true, message: okMsg, pid: pid,
                                   runLogPath: runLogPath, session: session)
    }

    // MARK: 常驻收尾段（会话队列串行——平铺函数，swiftc 雷区纪律）

    /// 等待退出（C-a：默认不限时；timeout 提供时到点 terminate→timedOut 标志
    /// →短等待收尸）后进入收尾。
    private func waitForAndFinalize(_ session: GuestRunSession) {
        var waitResult: DispatchTimeoutResult = .success
        if let t = session.timeoutSeconds {
            waitResult = session.exitSemaphore.wait(timeout: .now() + t)
        } else {
            waitResult = session.exitSemaphore.wait(timeout: .distantFuture)
        }
        if waitResult == .timedOut {
            session.timedOut = true
            _ = session.process.terminate()
            _ = session.exitSemaphore.wait(timeout: .now() + 10)
        }
        finalizeRunSession(session)
    }

    /// 收尾（run_log footer→活跃注销→三态消息→A2 窗口收尾→endRun→退出
    /// 事件 modelVisible）。会话队列串行调用。
    private func finalizeRunSession(_ session: GuestRunSession) {
        // 活跃注销（stop_build 不再打僵尸进程）。
        lock.lock()
        activeProcess = nil
        activeBundleID = ""
        activeSession = nil
        lock.unlock()

        session.tailLock.lock()
        // 观测链补全：尾段缓冲 40→80 行（退出事件 diagnostics 内联消费；
        // 缓冲上限 200 不变——只放宽取用窗口）。
        let tail = session.tailLines.suffix(80).joined(separator: "\n")
        let stopRequested = session.stopRequested
        session.tailLock.unlock()

        session.exitBox.lock.lock()
        let exitRaw = session.exitBox.rawStatus
        let exitCode = session.exitBox.exitCode
        let exitSignal = session.exitBox.signal
        let decoded = session.exitBox.decoded
        session.exitBox.lock.unlock()

        let exitNote = Self.renderExitNote(raw: exitRaw, exitCode: exitCode,
                                           signal: exitSignal, decoded: decoded,
                                           timedOut: session.timedOut)
        let footer = "run end " + ISO8601DateFormatter().string(from: Date())
            + " " + exitNote + "\n"
        try? session.logHandle?.write(contentsOf: Data(footer.utf8))
        try? session.logHandle?.close()

        // B：退出三态呈现（①自然退出 ②超时 ③被终止——stop_build/外部细分）。
        let message = Self.composeExitMessage(
            timedOut: session.timedOut, stopRequested: stopRequested,
            decoded: decoded, exitCode: exitCode, signal: exitSignal,
            raw: exitRaw, timeoutSeconds: session.timeoutSeconds)

        // A2：窗口清空判定隐藏+归还键窗（官方进程退出关窗走 processDidExit
        // 内 dispatch_async(main) 异步链——PEProcess.m:286-294——传 1.0s 余量
        // 防竞态误判；主队列 FIFO 保证判定排在官方 closeWindow dispatch 后）。
        GuestWindowBridge.hideGuestOverlayIfNoWindows(afterDelay: 1.0)

        // run 门放行（C v2：endRun 从工具 defer 移到会话收尾——spawn 成功的
        // 会话独占门生命周期；失败路径由工具层 endRun）。
        BuildService.shared.endRun()

        // 退出事件链（modelVisible——工具返回后 append：SessionWriter 为
        // @unchecked Sendable、gate 串行化、生命周期独立于工具调用，已核验
        // 安全——SessionWriter.swift:67-162）。
        // run_log 副本落工作区（Cache 路径 guest/AI 皆不可读——副本进
        // BuildArtifacts AI fs 直取；N9 观测链装备原样保留）。
        let wsLogPath = BuildAndRunTool.copyRunLogToWorkspace(
            sourcePath: session.runLogPath, workspaceRoot: session.workspaceRoot)
        var runLogField = session.runLogPath
        if !wsLogPath.isEmpty {
            runLogField = runLogField + "（工作区副本：" + wsLogPath + "）"
        }
        var diagnostics = session.prepDetail
        if !diagnostics.isEmpty {
            diagnostics = diagnostics + "；"
        }
        diagnostics = diagnostics + message
        diagnostics = diagnostics + "\n——— guest 输出尾段（最后 ≤80 行）———\n"
        if tail.isEmpty {
            diagnostics = diagnostics
                + "（guest 零输出——若非预期，检查 guest 是否 print/是否 pre-main 挂起）"
        } else {
            diagnostics = diagnostics + tail
        }
        // 事件 result：自然退出（解码成功且无 signal）=success；超时/终止/
        // 状态不可得=failure（B 三态——signal 被杀不再标「正常退出」）。
        let isSuccess = (!session.timedOut && !stopRequested && decoded && exitSignal == 0)
        let writer = session.writer
        let eventName = session.projectName
        let eventExit = exitNote
        let eventRunLog = runLogField
        let eventDiagnostics = String(diagnostics.prefix(2000))
        Task {
            _ = try? await writer.append(.extensionEvent(
                kind: RunEvents.eventKind,
                payload: .object([
                    "name": .string(eventName),
                    "result": .string(isSuccess ? "success" : "failure"),
                    "phase": .string("exit"),
                    "exit": .string(eventExit),
                    "runLog": .string(eventRunLog),
                    "diagnostics": .string(eventDiagnostics),
                ])))
        }
    }

    // MARK: 组装辅助（平铺——swiftc 雷区纪律：无嵌套函数）

    /// B 拍板：退出三态消息（结果消息/run_log 语义同源）。
    /// ①自然退出（exitCode）②超时（timedOut 文案优先）③被终止——
    /// stop_build（stopRequested 标志）与外部终止（排除法：signal 且非
    /// 超时非 stop——浮窗关闭钮=终止进程，官方 closeWindow 语义）。
    static func composeExitMessage(timedOut: Bool, stopRequested: Bool,
                                   decoded: Bool, exitCode: Int, signal: Int,
                                   raw: Int, timeoutSeconds: TimeInterval?) -> String {
        if timedOut {
            var msg = "guest 超时（" + String(Int(timeoutSeconds ?? 0))
                + "s）→ 已 terminate；"
            msg = msg + renderExitNote(raw: raw, exitCode: exitCode,
                                       signal: signal, decoded: decoded,
                                       timedOut: true)
            msg = msg + "；guest 存活至超时（进程未自行退出）——GUI 应用属预期形态；CLI 应用应自行退出"
            return msg
        }
        if stopRequested {
            var msg = "guest 已被 stop_build 终止（SIGKILL）"
            msg = msg + renderExitNote(raw: raw, exitCode: exitCode,
                                       signal: signal, decoded: decoded,
                                       timedOut: false)
            return msg
        }
        if decoded && signal > 0 {
            var msg = "guest 被外部终止（signal=" + String(signal)
                + "，wait4 raw=" + String(raw) + "）"
            msg = msg + "——浮窗关闭钮=终止进程（官方语义：关窗即杀进程，"
                + "NXWindowSessionApplication closeWindow 内 terminate）"
            return msg
        }
        if decoded {
            var msg = "guest 正常退出：exit=" + String(exitCode)
                + "（wait4 raw=" + String(raw) + "）"
            if exitCode != 0 {
                msg = msg + "（非零退出——按输出诊断修复后重跑）"
            }
            return msg
        }
        return "guest 进程退出但退出状态不可得（exitContext 缺失——见 run_log 输出段）"
    }

    /// 退出注记（事件 exit 字段/run_log footer 同源文案）。
    static func renderExitNote(raw: Int, exitCode: Int, signal: Int,
                               decoded: Bool, timedOut: Bool) -> String {
        if !decoded {
            if timedOut {
                return "exit state unavailable（terminate 后退出回调未在 10s 余量内触发）raw=-1"
            }
            return "exit state unavailable raw=-1"
        }
        if signal > 0 {
            return "signal=" + String(signal) + "（wait4 raw=" + String(raw) + "）"
        }
        return "exit=" + String(exitCode) + "（wait4 raw=" + String(raw) + "）"
    }

    // MARK: utility 退出组装辅助（N10e 修 F/G——平铺 static，swiftc 雷区纪律）

    /// 【N10e 修 G】utility 退出注记（事件 exit 字段/tee footer 同源）。
    /// 退出码可及性（考古结论）：exitingCallback 由 PEProcess.processDidExit
    /// 在 :284 触发——同函数 :275 已读 arg1.exitContext.underlyingContext.
    /// legacyCode（wait4 状态原值），故回调时退出码可及（app 路线同点同读）。
    /// raw<0=采集侧防御态（exitContext 缺失——TTY 直连路线如实标注）。
    static func renderUtilityExitNote(raw: Int) -> String {
        if raw < 0 {
            return "exit state unavailable raw=-1（exitContext 缺失——TTY 直连路线）"
        }
        if (raw & 0x7F) != 0 {
            let sig = raw & 0x7F
            return "signal=" + String(sig) + "（wait4 raw=" + String(raw) + "）"
        }
        let code = (raw >> 8) & 0xFF
        return "exit=" + String(code) + "（wait4 raw=" + String(raw) + "）"
    }

    /// 【N10e 修 G】utility 退出三态（①stop_build 终止 ②外部终止=终端窗
    /// 关闭钮 ③自然退出）——result（success/failure）与消息同返（app 路线
    /// composeExitMessage 对齐：自然退出（解码成功且无 signal）=success）。
    static func composeUtilityExitMessage(raw: Int, stopRequested: Bool) -> (result: String, message: String) {
        if stopRequested {
            var msg = "utility 已被 stop_build 终止（SIGKILL）"
            msg = msg + "——终端窗已自动关闭（和 app 路线一致）"
            return ("failure", msg)
        }
        if raw < 0 {
            return ("failure", "utility 进程退出但退出状态不可得（exitContext 缺失——TTY 直连路线，输出见 tee/终端窗口）")
        }
        if (raw & 0x7F) != 0 {
            let sig = raw & 0x7F
            var msg = "utility 被外部终止（signal=" + String(sig)
                + "，wait4 raw=" + String(raw) + "）"
            msg = msg + "——终端窗口关闭钮=终止进程（官方语义），窗口已自动收尾"
            return ("failure", msg)
        }
        let code = (raw >> 8) & 0xFF
        var msg = "utility 正常退出：exit=" + String(code)
        if code != 0 {
            msg = msg + "（非零退出——按 tee 输出诊断修复后重跑）"
        }
        return ("success", msg)
    }
}
