//
//  GuestRunService.swift
//  WanWo
//
//  【N9b · build_and_run 运行时承载】guest 进程 spawn/stdio 回流/退出码收尾
//  的万我层编排（万我自有代码，零 vendored 改动——登记 docs/gpl-compliance
//  .md §N9）。官方对照（0.10.3 Builder.swift:321-349 + PEProcess.m:269-284）：
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
//      &0xFF=exit code；原值一并上报（signal 解析细粒度后置，先原值直出）。
//    · 输出流：行级回调接 ctx.onShellLine 缝（bash 工具同缝——工具卡实时
//      追加；0.2s 节流在 UI 侧，Host 不再叠层）；run_log 落盘
//      Cache/<uuid>/run_log.txt（时间戳+stdout/stderr 全量+退出码——AI 事后
//      可读，N8c 折叠教训对策）。
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

// MARK: - 单次运行结果

struct GuestRunOutcome {
    let ok: Bool
    let message: String
    let exitCode: Int
    let signal: Int
    /// wait4 状态原值（-1=未取得——退出回调未触发/上下文缺失）。
    let exitRaw: Int
    let timedOut: Bool
    let runLogPath: String
    let outputTail: String
}

// MARK: - GuestRunService

final class GuestRunService: @unchecked Sendable {

    static let shared = GuestRunService()

    /// 活跃 guest 登记（stop_build 接缝——run 态下终止当前 guest 进程）。
    private let lock = NSLock()
    private var activeProcess: PEProcess?
    private var activeBundleID = ""

    /// 终止活跃 guest（stop_build 在 run 态下的转语义）。返回说明文案。
    func stopActiveRun() -> String {
        lock.lock()
        let proc = activeProcess
        let bid = activeBundleID
        lock.unlock()
        guard let proc = proc else {
            return "无活跃 guest 进程登记（run 门在持但进程未注册/已退出）"
        }
        _ = proc.terminate()
        var note = "terminate 已发出（SIGKILL——官方 PEProcess.terminate 语义）guest=" + bid
        note = note + "；退出码随 exitingCallback 回流 run_log，run 门已放行"
        return note
    }

    /// 执行一次 guest 拉起与收尾（同步阻塞——调用方须在专用队列上跑，
    /// 本方法内部 semaphore/availableData 均阻塞当前线程；工具层经
    /// withCheckedContinuation+专用 DispatchQueue 包装）。
    /// 前提：prepareGuestRun 已成功（补片/容器签名/token/安装齐备）。
    func performRun(project: NXProject,
                    bundleID: String,
                    timeoutSeconds: TimeInterval,
                    onLine: @escaping @Sendable (String) -> Void) -> GuestRunOutcome {
        let emptyOutcome = GuestRunOutcome(ok: false, message: "", exitCode: -1,
                                           signal: 0, exitRaw: -1, timedOut: false,
                                           runLogPath: "", outputTail: "")
        guard !bundleID.isEmpty else {
            return Self.makeFailure(from: emptyOutcome, message: "guest bundle id 缺失（无法 spawn）")
        }
        guard let manager = PEProcessManager.shared() else {
            return Self.makeFailure(from: emptyOutcome,
                                    message: "PEProcessManager 不可用（宿主运行面未初始化——App 启动链异常？）")
        }

        // ── 管道编排（官方 Builder.swift:322-346 逐行对照）────────────
        let inPipe = Pipe()
        let outPipe = Pipe()
        guard let map = FDMapObject.emptyMap() else {
            return Self.makeFailure(from: emptyOutcome, message: "FDMapObject.emptyMap 创建失败")
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
        let items: [AnyHashable: Any] = ["PEMapObject": map]
        let pid = manager.spawnProcess(withBundleIdentifier: bundleID,
                                       withItems: items,
                                       withKernelSurfaceProcess: nil,
                                       doRestartIfRunning: true)
        guard pid > 0 else {
            let msg = "spawnProcess 失败（pid=" + String(pid) + "）——可查 installd 注册态"
                + "（pe_smoke）与 LDEApplicationObject.isLaunchAllowed（工程未安装/被卸载？）"
            return Self.makeFailure(from: emptyOutcome, message: msg)
        }
        guard let process = manager.processForProcessIdentifier(pid) else {
            let msg = "spawn 返回 pid=" + String(pid) + " 但无 PEProcess 记录（进程秒退？）"
            return Self.makeFailure(from: emptyOutcome, message: msg)
        }

        // 宿主端写端关闭（官方注释 sanctioned——"even if we close them"：
        // xpc_fd_create 在 appendFileDescriptor 时已捕获 fileport 右——
        // FDObject.m:45/FDMapObject.m:126，guest 侧副本持活管道；guest 退出
        // →副本关闭→宿主读端 EOF→读循环自然收束，不依赖宿主端句柄）
        try? outPipe.fileHandleForWriting.close()

        // ── 活跃登记（stop_build 接缝）────────────────────────────────
        lock.lock()
        activeProcess = process
        activeBundleID = bundleID
        lock.unlock()

        // ── run_log 落盘（Cache/<uuid>/run_log.txt——N8c 折叠教训对策）──
        let logURL = project.cacheURL.appendingPathComponent("run_log.txt")
        let runLogPath = logURL.path
        let isoStamp = ISO8601DateFormatter().string(from: Date())
        let header = "run start " + isoStamp + " bundle=" + bundleID
            + " pid=" + String(pid)
            + " timeout=" + String(Int(timeoutSeconds)) + "s\n"
        if !FileManager.default.fileExists(atPath: runLogPath) {
            FileManager.default.createFile(atPath: runLogPath, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.seekToEnd()
        try? logHandle?.write(contentsOf: Data(header.utf8))

        // ── 退出回调（官方 exitingCallback 钩子同点）──────────────────
        let exitBox = GuestExitBox()
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.exitingCallback = { [weak process] in
            var raw = -1
            if let strong = process {
                let ctxAny: Any? = strong.process?.exitContext
                if let exitCtx = ctxAny as? FBProcessExitContext {
                    raw = Int(exitCtx.underlyingContext.legacyCode)
                }
            }
            exitBox.store(raw: raw)
            exitSemaphore.signal()
        }

        // ── stdout/stderr 读循环（后台队列；行级 onShellLine——UI 侧节流）─
        let lineFormatter = DateFormatter()
        lineFormatter.dateFormat = "HH:mm:ss.SSS"
        let tailLock = NSLock()
        var tailLines: [String] = []
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
                        tailLock.lock()
                        tailLines.append(clean)
                        if tailLines.count > 200 {
                            tailLines.removeFirst(tailLines.count - 200)
                        }
                        tailLock.unlock()
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
                    tailLock.lock()
                    tailLines.append(clean)
                    tailLock.unlock()
                    let lineStamp = lineFormatter.string(from: Date())
                    let logText = "[" + lineStamp + "] " + clean + "\n"
                    try? logHandleRef?.write(contentsOf: Data(logText.utf8))
                }
            }
        }

        // ── 等待退出（超时→terminate→短等待收尸）──────────────────────
        var timedOut = false
        let waitResult = exitSemaphore.wait(timeout: .now() + timeoutSeconds)
        if waitResult == .timedOut {
            timedOut = true
            _ = process.terminate()
            _ = exitSemaphore.wait(timeout: .now() + 10)
        }

        // ── 活跃注销 + 结果组装 ────────────────────────────────────────
        lock.lock()
        activeProcess = nil
        activeBundleID = ""
        lock.unlock()

        tailLock.lock()
        let tail = tailLines.suffix(40).joined(separator: "\n")
        tailLock.unlock()

        exitBox.lock.lock()
        let exitRaw = exitBox.rawStatus
        let exitCode = exitBox.exitCode
        let exitSignal = exitBox.signal
        let decoded = exitBox.decoded
        exitBox.lock.unlock()

        let exitNote = Self.renderExitNote(raw: exitRaw, exitCode: exitCode,
                                           signal: exitSignal, decoded: decoded,
                                           timedOut: timedOut)
        let footer = "run end " + ISO8601DateFormatter().string(from: Date())
            + " " + exitNote + "\n"
        try? logHandle?.write(contentsOf: Data(footer.utf8))
        try? logHandle?.close()

        if timedOut {
            var msg = "guest 超时（" + String(Int(timeoutSeconds))
                + "s）→ 已 terminate；" + exitNote
            if decoded {
                msg = msg + "；输出尾段见 run_log"
            }
            return GuestRunOutcome(ok: false, message: msg, exitCode: exitCode,
                                   signal: exitSignal, exitRaw: exitRaw,
                                   timedOut: true, runLogPath: runLogPath,
                                   outputTail: tail)
        }
        guard decoded else {
            return Self.makeFailure(from: emptyOutcome,
                                    message: "guest 进程退出但退出状态不可得（exitContext 缺失——见 run_log 输出段）",
                                    runLogPath: runLogPath, outputTail: tail)
        }
        var okMsg = "guest 正常退出：" + exitNote
        if exitCode != 0 {
            okMsg = okMsg + "（非零退出——按输出诊断修复后重跑）"
        }
        return GuestRunOutcome(ok: true, message: okMsg, exitCode: exitCode,
                               signal: exitSignal, exitRaw: exitRaw,
                               timedOut: false, runLogPath: runLogPath,
                               outputTail: tail)
    }

    // MARK: 组装辅助（平铺——swiftc 雷区纪律：无嵌套函数）

    private static func makeFailure(from base: GuestRunOutcome,
                                    message: String,
                                    runLogPath: String = "",
                                    outputTail: String = "") -> GuestRunOutcome {
        return GuestRunOutcome(ok: false, message: message,
                               exitCode: base.exitCode, signal: base.signal,
                               exitRaw: base.exitRaw, timedOut: base.timedOut,
                               runLogPath: runLogPath, outputTail: outputTail)
    }

    /// 退出注记（结果/事件/run_log footer 三处同源文案）。
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
}
