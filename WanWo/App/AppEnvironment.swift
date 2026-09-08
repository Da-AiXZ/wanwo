//
//  AppEnvironment.swift
//  WanWo
//
//  【按设计新写】出处：10-design §四（App/AppEnvironment：依赖注入容器）、
//  §7.1（M1 信息架构子集装配）。M0 的 ISHRuntime/Platform/Vendor 不在此装配
//  （ShellTestView 自举，保持 M0 独立可回归）。
//

import Foundation
import SwiftUI

/// 根导航选择目标（§7.1 M1 子集 + M0 回归入口 + M2.8 只读诊断入口）。
enum RootSelection: Hashable {
    case session(id: String)
    case providers
    case shellTest
    /// M2.8 只读事件流诊断页（dsh ui-trajectory 最小移植；F060 M8.2 前置）。
    case eventStream
    case none
}

/// App 装配容器：会话仓库 + GRDB 索引 + 端点配置。
@MainActor
final class AppEnvironment: ObservableObject {
    let endpointStore: EndpointStore
    let sessionStore: SessionStore
    /// GRDB 投影库（对 UI 不透明；仅供会话层更新索引）。
    let database: SessionDatabase

    /// 会话列表版本号（创建/删除/标题落盘时 +1，驱动侧栏刷新）。
    @Published var sessionsRevision = 0
    @Published var selection: RootSelection = .none

    private static let logger = AppLogger(category: "env")

    init() {
        let base = WanWoPaths.persistentBase
        let sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        let configDir = base.appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDir,
                                                 withIntermediateDirectories: true)

        // GRDB 投影库（打开失败则以临时路径兜底一次，保证 App 可启动；错误进日志）。
        var database: SessionDatabase?
        do {
            database = try SessionDatabase(
                path: base.appendingPathComponent("wanwo-index.sqlite3").path)
        } catch {
            Self.logger.fault("session database open failed: \(String(describing: error))")
        }
        let db = database ?? (try? SessionDatabase(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-index-fallback.sqlite3").path))!
        self.database = db
        self.sessionStore = SessionStore(root: sessionsRoot, database: db)
        self.endpointStore = EndpointStore(fileURL: configDir.appendingPathComponent("providers.json"))

        // 启动列表零对账（启动空窗根治）：索引是写路径同步维护的持久表，
        // 首帧 listSessions 直查持久索引即秒出——启动路径不做任何 JSONL 扫描。
        // 后台增量校验兜底外部变更：mtime/size 基线比对，零变化静默完成；
        // 变化/新增文件只重扫该文件（轻量探针，header + 尾部事件）；索引空而
        // JSONL 存在（新装/删重装）→ 快速重建。完成后 bump sessionsRevision。
        Task { [weak self] in
            await self?.sessionStore.verifyIncremental()
            await MainActor.run { self?.sessionsRevision += 1 }
        }

        // ERR-022：App 级内核 boot（OpenMinis 形态）——启动即后台预热，
        // 聊天链路不再依赖诊断页（ShellTestView）手动 boot。失败仅记日志：
        // 聊天执行链首次使用前 makeAgentStack 会再次幂等 ensure 并向用户
        // 报告具体失败原因（与 ERR-016 的 failureReason 口径一致）。
        Task {
            do {
                try await KernelBootCoordinator.ensureKernelBooted()
            } catch {
                Self.logger.fault("app-level kernel boot failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - 会话

    func loadSessions() async -> [SessionSummary] {
        await sessionStore.listSessions()
    }

    func createSession() async -> SessionSummary? {
        let summary = try? await sessionStore.createSession(cwd: WanWoPaths.linuxBaseDir + "/workspace")
        sessionsRevision += 1
        return summary
    }

    func deleteSession(id: String) async {
        // 先关闭可能开放的写柄（排他写所有权归还），再删除。
        await sessionStore.closeWriter(id: id)
        try? await sessionStore.deleteSession(id: id)
        if case .session(let selectedID) = selection, selectedID == id {
            selection = .none
        }
        sessionsRevision += 1
    }

    // MARK: - 模型接入

    /// 由当前启用端点构造 adapter（端点与 key 同代取用——dsh 凭据配对语义）。
    func makeAdapter() throws -> (OpenAICompatAdapter, EndpointConfig) {
        guard let endpoint = endpointStore.activeEndpoint() else {
            throw LLMError(message: "没有已启用的模型端点，请到「设置 · Providers」配置。",
                           code: "NO_ENDPOINT")
        }
        guard let apiKey = endpointStore.apiKey(for: endpoint), !apiKey.isEmpty else {
            throw LLMError(message: "端点「\(endpoint.name)」未配置 API Key。",
                           code: "MISSING_CREDENTIAL")
        }
        return (OpenAICompatAdapter(endpoint: endpoint, apiKey: apiKey), endpoint)
    }

    /// nonisolated adapter 工厂（AgentLoop/Compactor 的 @Sendable makeAdapter 缝用）。
    /// async：EndpointStore 为 MainActor 隔离，activeEndpoint/apiKey 需 await 跳主线程取用。
    nonisolated func makeAgentAdapter() async throws -> OpenAICompatAdapter {
        guard let endpoint = await endpointStore.activeEndpoint() else {
            throw LLMError(message: "没有已启用的模型端点，请到「设置 · Providers」配置。",
                           code: "NO_ENDPOINT")
        }
        guard let apiKey = await endpointStore.apiKey(for: endpoint), !apiKey.isEmpty else {
            throw LLMError(message: "端点「\(endpoint.name)」未配置 API Key。",
                           code: "MISSING_CREDENTIAL")
        }
        return OpenAICompatAdapter(endpoint: endpoint, apiKey: apiKey)
    }

    // MARK: - Agent 栈装配（M2）

    /// 装配 AgentLoop 全家（§十一 M2：registry / pipeline / compactor / spill /
    /// injector / loop；审批缝 = AutoApprovalSeam 仅 M2 占位，M3 换审批卡 answerer）。
    /// - Returns: loop = nil 表示装配失败（无端点/凭据不可读），failureReason 带具体
    ///   原因（ERR-016：原 try? 吞错导致降级横幅只有泛化提示，无法定位）。
    func makeAgentStack(sessionId: String,
                        writer: SessionWriter,
                        callbacks: AgentLoop.Callbacks) async -> (loop: AgentLoop?, failureReason: String?) {
        do {
            _ = try await makeAgentAdapter()
        } catch {
            let reason = (error as? LLMError)?.message ?? String(describing: error)
            return (nil, reason)
        }

        // ERR-022：聊天执行链首次使用前幂等确保内核已 boot（App 启动已后台
        // 预热；此处兜底冷启动竞态——ensure 幂等，isBooted 已真直返）。
        do {
            try await KernelBootCoordinator.ensureKernelBooted()
        } catch {
            return (nil, "内核启动失败：\((error as NSError).localizedDescription)")
        }

        let registry = ToolRegistry()
        registry.register(ShellTool(sessionId: sessionId))
        FsTools.registerAll(into: registry, sessionId: sessionId)
        WebTools.registerAll(into: registry)

        let spill = SpillStore(
            root: WanWoPaths.persistentBase
                .appendingPathComponent("spill", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true))
        let repeatAdviser = RepeatCallAdviser()
        let pipeline = ToolPipeline(
            registry: registry,
            // 【仅 M2 占位】自动批准 answerer（照记 approval 事件保审计）；M3 换真审批卡。
            approvalSeam: AutoApprovalSeam(writer: writer),
            repeatAdviser: repeatAdviser)
        let compactor = Compactor(makeAdapter: { [weak self] in
            guard let self else {
                throw LLMError(message: "environment released", code: "UNKNOWN")
            }
            return try await self.makeAgentAdapter()
        })
        let assembler = PromptAssembler()
        // ERR-025③：system prompt 内容注册（dsh 工具 sections + 基础文案
        // 逐字移植；dsh 环境特有段落见 PromptSections 头注报批单）。
        PromptSections.registerAll(into: assembler)
        let injector = ContextInjector()

        let deps = AgentLoop.Dependencies(
            sessionId: sessionId,
            writer: writer,
            assembler: assembler,
            registry: registry,
            pipeline: pipeline,
            compactor: compactor,
            spill: spill,
            injector: injector,
            makeAdapter: { [weak self] in
                guard let self else {
                    throw LLMError(message: "environment released", code: "UNKNOWN")
                }
                return try await self.makeAgentAdapter()
            },
            callbacks: callbacks)
        return (AgentLoop(deps: deps), nil)
    }
}
