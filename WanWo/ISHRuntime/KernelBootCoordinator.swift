//
//  KernelBootCoordinator.swift
//  WanWo
//
//  【按设计新写 · ERR-022】出处：OpenMinis App 级 boot 形态——
//  IshExecutorBridge（原 ISHExecutionCoordinator.swift:101）同样抛
//  kernelNotBooted，但 OpenMinis App 启动即 boot，用户永远遇不到；
//  WanWo 原 boot 编排只存在于 ShellTestView（M0 诊断页），冷启动后聊天页
//  首次用 bash 必报 kernelNotBooted，必须手动打开诊断页才能解锁。
//  本层把 ShellTestView 的 boot 编排（RootfsInstaller.installIfNeeded →
//  ISHKernel.boot → isBooted 轮询 → FsContextRouter.installHook）提取为
//  共享层：App 启动即后台 boot（AppEnvironment.init 预热）+ 聊天执行链
//  首次使用前幂等 ensure（AppEnvironment.makeAgentStack 兜底）；
//  ShellTestView 改调本层（行为不变）。
//  幂等语义：ISHKernel.shared.isBooted 已真则直返（钩子补装一次）；
//  并发 ensure 合并到同一个在飞 boot 任务；boot 失败不清态，下次调用可重试。
//

import Foundation

/// App 级内核 boot 编排（幂等；并发调用合并到同一个在飞任务）。
enum KernelBootCoordinator {

    /// boot 阶段（UI 进度映射用；语义与原 ShellTestView 编排一致）。
    enum Phase: Sendable {
        case installing
        case booting
    }

    private static let logger = AppLogger(category: "KernelBoot")

    private static let stateLock = NSLock()
    /// 在飞 boot 任务（并发 ensure 合并；完成/失败后清除，失败可重试）。
    private static nonisolated(unsafe) var bootTask: Task<Void, Error>?
    /// fs_context 路径翻译钩子是否已安装（boot 后、任何命令前，一次性）。
    private static nonisolated(unsafe) var hookInstalled = false

    /// 幂等确保内核已 boot。已真直返；否则 rootfs 安装 → 内核 boot（后台线程，
    /// isBooted 轮询兜底）→ fs_context 路径翻译钩子。
    /// - Parameter onPhase: 阶段回调（任意线程调用；UI 侧自行跳 MainActor）。
    /// - Throws: reset 毒标记置位 / rootfs 安装失败 / boot rc 非零 / 轮询超时。
    static func ensureKernelBooted(
        onPhase: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws {
        // 快路：已 boot（幂等直返；钩子补装一次以防历史调用未装钩）。
        if ISHKernel.shared.isBooted {
            installHookOnce()
            return
        }
        // [T-rootfs-reset-terminal-crash] 毒标记：内核每进程只能 boot 一次，
        // reset 后其 fakefs 挂载已失效，本进程内无法恢复——拒绝而非崩溃。
        if RootfsInstaller.shared.didResetWhileBooted {
            throw NSError(domain: "KernelBoot", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "内核已在 rootfs 重置前启动，本进程内无法重新挂载；请重启 App。"
            ])
        }

        // 并发合并：后到调用共享同一个在飞任务（不做双重 boot）。
        let task: Task<Void, Error> = withStateLock {
            if let inFlight = bootTask { return inFlight }
            let created = Task { try await performBoot(onPhase: onPhase) }
            bootTask = created
            return created
        }
        do {
            try await task.value
        } catch {
            clearBootTask()
            throw error
        }
        clearBootTask()
        installHookOnce()
    }

    // MARK: - Private

    /// boot 编排本体（与原 ShellTestView.bootIfNeeded 步骤一比一）。
    private static func performBoot(
        onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws {
        // 1. rootfs 安装（自带 .arch 标签 / move-aside / zip 解析器）。
        onPhase(.installing)
        do {
            try RootfsInstaller.shared.installIfNeeded()
        } catch {
            throw NSError(domain: "KernelBoot", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "rootfs 安装失败：\((error as NSError).localizedDescription)"
            ])
        }

        // 并发方可能已在本任务执行期间完成 boot（幂等保护，不重复 boot）。
        if ISHKernel.shared.isBooted { return }

        // 2. 内核启动（bootWithRootPath 重量级，后台线程；轮询 isBooted 兜底）。
        onPhase(.booting)
        let rootPath = RootfsInstaller.shared.rootfsPath.path
        let bootResult: Int32 = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let rc = ISHKernel.shared.boot(withRootPath: rootPath)
            guard rc == 0 else { return rc }
            for _ in 0..<300 {
                if ISHKernel.shared.isBooted { return 0 }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return -99
        }.value

        guard bootResult == 0 else {
            throw NSError(domain: "KernelBoot", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "boot 失败 rc=\(bootResult)"
            ])
        }
        logger.info("kernel booted (aarch64) at \(rootPath, privacy: .public)")
    }

    /// 3. fs_context 路径翻译钩子（boot 后、任何命令前，一次性）。
    private static func installHookOnce() {
        withStateLock {
            guard !hookInstalled else { return }
            hookInstalled = true
            FsContextRouter.shared.installHook()
        }
    }

    private static func clearBootTask() {
        withStateLock { bootTask = nil }
    }

    private static func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
