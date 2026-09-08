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
    /// M3 T2 权限管理页（规则 CRUD + 预设说明；T1 偏差 6 补齐）。
    case permissions
    case none
}

/// App 装配容器：会话仓库 + GRDB 索引 + 端点配置。
@MainActor
final class AppEnvironment: ObservableObject {
    let endpointStore: EndpointStore
    let sessionStore: SessionStore
    /// GRDB 投影库（对 UI 不透明；仅供会话层更新索引）。
    let database: SessionDatabase
    /// M3 T2：权限规则库（App 级共享 user 层 JSONL；flock 排他 + 签名去重）。
    let permissionRules: PermissionRulesStore

    /// 会话列表版本号（创建/删除/标题落盘时 +1，驱动侧栏刷新）。
    @Published var sessionsRevision = 0
    @Published var selection: RootSelection = .none
    /// 待决交互镜像（侧栏琥珀点数据源；dsh 2026-07-23 笔记——sidebar mirrors
    /// every blocked interaction with an amber warning dot，优先级高于运行中圆环）。
    @Published private(set) var pendingInteractionSessionIDs: Set<String> = []

    /// 待决交互状态登记（ChatViewModel 在审批/提问 present 与 settle 时调用）。
    func notePendingInteraction(sessionId: String, active: Bool) {
        if active {
            pendingInteractionSessionIDs.insert(sessionId)
        } else {
            pendingInteractionSessionIDs.remove(sessionId)
        }
    }

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
        self.permissionRules = PermissionRulesStore(
            fileURL: configDir.appendingPathComponent("permission-rules.jsonl"))

        // M3 T2 报批登记：approval/policy 扩展事件 schema（E1 通道——T2 批次
        // 报批项，已批；projection=logOnly，pairing=none，policy ∈ {ask, never}）。
        if !ExtensionEventRegistry.shared.isRegistered(
            PermissionCoordinator.policyEventKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: PermissionCoordinator.policyEventKind,
                requiredFields: [ExtensionFieldSchema(
                    "policy", .string,
                    allowedValues: [.string(ApprovalPolicy.ask.rawValue),
                                    .string(ApprovalPolicy.never.rawValue)])],
                projection: .logOnly,
                pairing: .none))
        }
        // M3 T2.1 补批登记：sandbox/mode 扩展事件 schema（01 笔记
        // sandbox-policy"sandbox/mode 事件+fold+写路径"原件词汇——团队主理人
        // 补批，修 T2 偏差 1 沙箱旋钮内存态缺口；mode 与矩阵 SandboxMode 词汇
        // 一致，projection=logOnly，pairing=none）。
        if !ExtensionEventRegistry.shared.isRegistered(
            PermissionCoordinator.sandboxEventKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: PermissionCoordinator.sandboxEventKind,
                requiredFields: [ExtensionFieldSchema(
                    "mode", .string,
                    allowedValues: [.string(ApprovalDecisionMatrix.SandboxMode.readOnly.rawValue),
                                    .string(ApprovalDecisionMatrix.SandboxMode.workspaceWrite.rawValue),
                                    .string(ApprovalDecisionMatrix.SandboxMode.dangerFullAccess.rawValue)])],
                projection: .logOnly,
                pairing: .none))
        }

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
    /// injector / loop；审批缝 = M3 T1 CompositeApprovalSeam 四步管线 +
    /// ApprovalCoordinator + UserQuestionService，M2 AutoApprovalSeam 占位已废）。
    /// - Parameters:
    ///   - interactionPresenter: 交互呈现缝（ChatViewModel；nil = 无 answerer，
    ///     审批 fail closed unavailable、提问 fail closed NO_PROVIDER）。
    /// - Returns: loop = nil 表示装配失败（无端点/凭据不可读），failureReason 带具体
    ///   原因（ERR-016：原 try? 吞错导致降级横幅只有泛化提示，无法定位）。
    func makeAgentStack(sessionId: String,
                        writer: SessionWriter,
                        callbacks: AgentLoop.Callbacks,
                        interactionPresenter: SessionInteractionPresenter? = nil)
        async -> (loop: AgentLoop?, failureReason: String?,
                  approvalCoordinator: ApprovalCoordinator?,
                  questionService: UserQuestionService?,
                  permission: PermissionCoordinator?) {
        do {
            _ = try await makeAgentAdapter()
        } catch {
            let reason = (error as? LLMError)?.message ?? String(describing: error)
            return (nil, reason, nil, nil, nil)
        }

        // ERR-022：聊天执行链首次使用前幂等确保内核已 boot（App 启动已后台
        // 预热；此处兜底冷启动竞态——ensure 幂等，isBooted 已真直返）。
        do {
            try await KernelBootCoordinator.ensureKernelBooted()
        } catch {
            return (nil, "内核启动失败：\((error as NSError).localizedDescription)",
                    nil, nil, nil)
        }

        let registry = ToolRegistry()
        registry.register(ShellTool(sessionId: sessionId))
        FsTools.registerAll(into: registry, sessionId: sessionId)
        WebTools.registerAll(into: registry)

        // M3 T1 审批装配（m3-scope-brief §二.3-5）：
        //   · ApprovalDecisionMatrix —— workspace-write 最简矩阵（T1 缺省档）；
        //   · ApprovalCoordinator —— turn-enclosed + 审计对 + first answer wins；
        //   · UserQuestionService —— ask_user_question 的 answerer 缝。
        let coordinator = ApprovalCoordinator(writer: writer,
                                              presenter: interactionPresenter)
        let questionService = UserQuestionService(presenter: interactionPresenter)
        registry.register(AskUserTool(service: questionService))

        // M3 T2 权限装配：每会话 PermissionCoordinator（双旋钮折叠 + 规则引擎
        // + 会话审批缓存 + 沉淀 + /permission）；规则库 App 级共享。
        let permission = PermissionCoordinator(writer: writer, rules: permissionRules)

        let spill = SpillStore(
            root: WanWoPaths.persistentBase
                .appendingPathComponent("spill", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true))
        let repeatAdviser = RepeatCallAdviser()
        let pipeline = ToolPipeline(
            registry: registry,
            // M3 T1 四步管线 + T2：规则引擎先行（prefix/network 取最严）→
            // 未命中矩阵启发式兜底 → 会话缓存 → never 短路 → 协调器；
            // policyProvider = approval 旋钮实时折叠值。
            approvalSeam: CompositeApprovalSeam(
                matrix: ApprovalDecisionMatrix(sandboxMode: .workspaceWrite),
                coordinator: coordinator,
                policyProvider: { [permission] in permission.knobs.approval },
                permission: permission),
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
        // M3 T2：approval-policy 动态上下文位（CONTEXT_ORDERS 115）——快照
        // 通道注入（ERR-024 纪律：不进 system；完整当前值跟随、仅变化才重
        // 注入，缓存前缀不破）。
        injector.approvalPolicyProvider = { [permission] in
            permission.approvalPolicyContextLine
        }

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
        return (AgentLoop(deps: deps), nil, coordinator, questionService, permission)
    }
}
