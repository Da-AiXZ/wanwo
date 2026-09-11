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
    /// M3 T2.2 设置·新会话默认权限行（PermissionRow.tsx 1:1；P1-4 后唯一
    /// 权限入口——规则 CRUD 页随 F022 砍除）。
    case permissionDefaults
    /// M4-A 件11：设置·MCP server 管理（OpenMinis MCPIntegrationsView 交互
    /// 参照；配置存储 config/mcp-servers/servers.json）。
    case mcpServers
    case none
}

/// App 装配容器：会话仓库 + GRDB 索引 + 端点配置。
@MainActor
final class AppEnvironment: ObservableObject {
    let endpointStore: EndpointStore
    let sessionStore: SessionStore
    /// GRDB 投影库（对 UI 不透明；仅供会话层更新索引）。
    let database: SessionDatabase
    /// M3 T2.2：新会话默认权限预设（设置·权限行持久宿主面；PermissionRow.tsx
    /// 语义——App 级默认，与当前会话旋钮分离）。P1-4：规则库与规则 CRUD 页
    /// 砍除（F022）——权限宿主面只剩本默认源。
    let permissionDefaults: PermissionDefaultStore
    /// M4-A 件11：MCP server 配置仓库（config/mcp-servers/servers.json；
    /// OpenMinis MCPStore 格式为唯一参照，凭据入 Keychain 不入 JSON）。
    let mcpServerStore: MCPServerStore
    /// M4-A 验收增补（lead 批准方案甲）：MCP 激活状态记录器——设置页 MCP 行
    /// "上次激活"直显，config skipped 与 activation failed 双落点覆盖写
    /// （每次会话栈构建都刷新=呈现最新一次结果）。
    let mcpLastActivation = MCPLastActivationStore()
    /// M4-A 件11：serverName 命名空间注册表（dsh 模块级 WeakMap 的 App 级
    /// 单例对应——scope 级互斥、跨会话栈复用）。
    let mcpNamespaces = MCPNamespaceRegistry()

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

    // MARK: - F042/T2.6：会话级模型选择宿主（App 级 per-session 字典）

    private let selectionRegistryLock = NSLock()
    private var sessionModelSelections: [String: SessionModelSelection] = [:]

    /// 取（惰性建）一个会话的模型选择宿主。
    /// T2.6 件2：原 ChatViewModel 实例属性方案随 ChatView StateObject 切页
    /// 销毁而归零（用户 #9——切页面丢选择）；升格 App 级 per-session 字典，
    /// 会话存续期间保持（dsh ModelSelect.tsx state.current=per-session 语义）。
    /// ChatViewModel 销毁不清条目（字典随会话数线性、量小——会话删除时惰性
    /// 清理，呈报）；open() 的 nil 初始化保留（首次打开仍=活动端点+默认）。
    func modelSelection(for sessionID: String) -> SessionModelSelection {
        selectionRegistryLock.lock()
        defer { selectionRegistryLock.unlock() }
        if let existing = sessionModelSelections[sessionID] { return existing }
        let created = SessionModelSelection()
        sessionModelSelections[sessionID] = created
        return created
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
        // M3 T2.2：新会话默认权限预设（config/permission-default.json）。
        // P1-4：permission-rules.jsonl 规则库随 F022 砍除，不再装载。
        self.permissionDefaults = PermissionDefaultStore(
            fileURL: configDir.appendingPathComponent("permission-default.json"))
        // M4-A 件11：MCP server 配置存储（Application Support 约定：config/
        // mcp-servers/servers.json——OpenMinis 载体名语义，文件位置平台适配）。
        self.mcpServerStore = MCPServerStore(
            fileURL: configDir.appendingPathComponent("mcp-servers")
                .appendingPathComponent("servers.json"))

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
                    allowedValues: [.string(SandboxMode.readOnly.rawValue),
                                    .string(SandboxMode.workspaceWrite.rawValue),
                                    .string(SandboxMode.dangerFullAccess.rawValue)])],
                projection: .logOnly,
                pairing: .none))
        }

        // M3 T3 报批登记：plan/mode 扩展事件 schema（E1 通道——T3 批次报批项，
        // dsh plan-mode index.ts:39-48 词汇原件：{active:boolean} log-only 整值
        // 替换、last wins；projection=logOnly，pairing=none）。
        if !ExtensionEventRegistry.shared.isRegistered(
            PlanModeController.modeEventKind) {
            ExtensionEventRegistry.shared.register(ExtensionEventSchema(
                kind: PlanModeController.modeEventKind,
                requiredFields: [ExtensionFieldSchema("active", .bool)],
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
    nonisolated func makeAgentAdapter(selection: SessionModelSelection? = nil,
                                      attachmentStore: AttachmentStore? = nil) async throws -> OpenAICompatAdapter {
        // T2.4 P1-3：会话级选择优先（dsh ModelSelect per-session
        // ModelSelection 语义），缺省回落活动端点（App 级缺省）。
        guard let endpoint = await endpointStore.resolve(selection: selection?.get()) else {
            throw LLMError(message: "没有已启用的模型端点，请到「设置 · Providers」配置。",
                           code: "NO_ENDPOINT")
        }
        guard let apiKey = await endpointStore.apiKey(for: endpoint), !apiKey.isEmpty else {
            throw LLMError(message: "端点「\(endpoint.name)」未配置 API Key。",
                           code: "MISSING_CREDENTIAL")
        }
        // F042：请求图片解析缝（带图 user 消息的请求变体经
        // AttachmentStore.readRequestImage——variantId 缓存确定性）；nil = 不解析。
        var resolver: (@Sendable (ImageAttachmentRef) async throws -> RequestImageAttachment)?
        if let attachmentStore {
            resolver = { ref in
                try attachmentStore.readRequestImage(ref)
            }
        }
        return OpenAICompatAdapter(endpoint: endpoint, apiKey: apiKey,
                                   imageResolver: resolver)
    }

    // MARK: - Agent 栈装配（M2）

    /// 装配 AgentLoop 全家（§十一 M2：registry / pipeline / compactor / spill /
    /// injector / loop；审批缝 = M3 P1-3 重做——审批只由沙箱提权请求触发
    /// （ApprovalCoordinator + UserQuestionService 仍在；M2 AutoApprovalSeam
    /// 占位已废）。
    /// - Parameters:
    ///   - interactionPresenter: 交互呈现缝（ChatViewModel；nil = 无 answerer，
    ///     审批 fail closed unavailable、提问 fail closed NO_PROVIDER）。
    /// - Returns: loop = nil 表示装配失败（无端点/凭据不可读），failureReason 带具体
    ///   原因（ERR-016：原 try? 吞错导致降级横幅只有泛化提示，无法定位）。
    func makeAgentStack(sessionId: String,
                        writer: SessionWriter,
                        callbacks: AgentLoop.Callbacks,
                        interactionPresenter: SessionInteractionPresenter? = nil,
                        modelSelection: SessionModelSelection? = nil)
        async -> (loop: AgentLoop?, failureReason: String?,
                  approvalCoordinator: ApprovalCoordinator?,
                  questionService: UserQuestionService?,
                  permission: PermissionCoordinator?,
                  plan: PlanModeController?,
                  attachmentStore: AttachmentStore?) {
        do {
            _ = try await makeAgentAdapter()
        } catch {
            let reason = (error as? LLMError)?.message ?? String(describing: error)
            return (nil, reason, nil, nil, nil, nil, nil)
        }

        // ERR-022：聊天执行链首次使用前幂等确保内核已 boot（App 启动已后台
        // 预热；此处兜底冷启动竞态——ensure 幂等，isBooted 已真直返）。
        do {
            try await KernelBootCoordinator.ensureKernelBooted()
        } catch {
            return (nil, "内核启动失败：\((error as NSError).localizedDescription)",
                    nil, nil, nil, nil, nil)
        }

        // F042：本会话附件存储（session bucket attachments/；intake 与请求
        // 变体共用一 store——content-addressed，同图跨会话各自隔离）。
        let attachments = AttachmentStore(sessionId: sessionId)

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

        // M3 P1-4 权限装配：每会话 PermissionCoordinator（双旋钮折叠 +
        // /permission + 双动态上下文位；规则引擎/缓存/沉淀随 F022 砍除）。
        // T2.2：新会话缺省双旋钮改读 App 级默认源（设置·权限行持久值），
        // 不再硬编码 ask + workspace-write。
        let permission = PermissionCoordinator(
            writer: writer,
            newSessionDefaults: { [permissionDefaults] in
                permissionDefaults.newSessionKnobs()
            })

        // M4-A 件11 装配（M4-A 收口）：MCP server 连接族——每 server 一实例
        // （dsh apply 1:1），后台激活不等会话栈（呈报）；工具桥注册进本会话
        // 注册表；资源三元经 connections 缝注册（件8 裁决①的请求级失败上报
        // 收口随 runtime.reportRequestFailure 落位）。
        let mcpResolved = mcpServerStore.resolvedClientConfigs()
        for failure in mcpResolved.failures {
            Self.logger.error("mcp config skipped: mcp-server \"\(failure.server)\": " +
                              "\(failure.reason)")
            // 配置侧失败记录（URL 打错等用户可自助修正的原因直显设置页）。
            mcpLastActivation.recordFailure(serverName: failure.server,
                                            message: failure.reason)
        }
        let mcpRuntime = MCPRuntime(configs: mcpResolved.configs,
                                    registry: registry,
                                    namespaces: mcpNamespaces,
                                    permission: permission,
                                    writer: writer,
                                    lastActivation: mcpLastActivation)
        Task { await mcpRuntime.activateAll() }
        for tool in MCPResourceTools.makeAll(connections: mcpRuntime) {
            do {
                _ = try registry.tryRegister(tool)
            } catch {
                Self.logger.error("mcp resource tool registration failed: " +
                                  "\(String(describing: error))")
            }
        }
        // M4-B B7 块1：mcp_server_config（AI 配置工具）——查询无门、写入走
        // 审批缝（SandboxGate.resolveMode + escalationApprover）。注册面与
        // 资源三元同款：环境级稳定注册（不随 server 工具世代重建），冲突
        // tryRegister 可捕获路径同纪律。
        do {
            _ = try registry.tryRegister(
                MCPServerConfigTool(store: mcpServerStore,
                                    lastActivation: mcpLastActivation))
        } catch {
            Self.logger.error("mcp server config tool registration failed: " +
                              "\(String(describing: error))")
        }

        let spill = SpillStore(
            root: WanWoPaths.persistentBase
                .appendingPathComponent("spill", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true))
        let repeatAdviser = RepeatCallAdviser()
        // P1-3：提权审批通道（审批只由 sandbox_permissions 请求触发——dsh
        // escalation.ts:173）。'never' 政策在 dispatch 之前确定性 rejected
        // （dsh user-approval index.ts:266——不呈现、不落审计对）；ask 交给
        // 协调器挂起等真人（fail closed：桥关闭/取消/无 answerer 分别归一
        // cancelled/unavailable）。
        let escalationApprover: SandboxEscalationApprover = {
            [permission, coordinator] toolName, callId, reason in
            if permission.knobs.approval == .never { return .rejected }
            return await coordinator.request(tool: toolName, callId: callId,
                                             reason: reason)
        }
        let pipeline = ToolPipeline(
            registry: registry,
            repeatAdviser: repeatAdviser)
        let compactor = Compactor(makeAdapter: { [weak self, modelSelection] in
            guard let self else {
                throw LLMError(message: "environment released", code: "UNKNOWN")
            }
            // T2.4 P1-3：会话级模型选择随缝传入（压缩摘要与会话主链同源）。
            return try await self.makeAgentAdapter(selection: modelSelection)
        })
        let assembler = PromptAssembler()
        // ERR-025③：system prompt 内容注册（dsh 工具 sections + 基础文案
        // 逐字移植；dsh 环境特有段落见 PromptSections 头注报批单）。
        PromptSections.registerAll(into: assembler)
        // M3 T3 计划模式装配：plan/mode 折叠 + plan:policy 段落（order 500，
        // {{plan_policy}} 变量门控）+ /plan + 常驻 exit_plan_mode。
        let planMode = PlanModeController(writer: writer, assembler: assembler)
        registry.register(ExitPlanModeTool(controller: planMode,
                                           service: questionService))
        var injector = ContextInjector()
        // M3 P1-3：sandbox:policy 动态上下文位（CONTEXT_ORDERS 110——dsh
        // sandbox-policy renderPolicyContext 三段逐字）+ approval-policy 位
        // （115——ASK_SENTENCE/NEVER_SENTENCE 逐字）。两位都走快照通道注入
        // （ERR-024 纪律：不进 system；完整当前值跟随、仅变化才重注入，
        // 缓存前缀不破）。
        injector.sandboxPolicyProvider = { [permission] in
            permission.sandboxPolicyContextLine
        }
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
            makeAdapter: { [weak self, modelSelection, attachments] in
                guard let self else {
                    throw LLMError(message: "environment released", code: "UNKNOWN")
                }
                // T2.4 P1-3：会话级模型选择（@Sendable 缝传值——holder 内
                // NSLock 保护，请求时读取，per-session 生效）。
                // F042：附件解析缝随闭包捕获传入（请求变体确定性身份）。
                return try await self.makeAgentAdapter(selection: modelSelection,
                                                       attachmentStore: attachments)
            },
            callbacks: callbacks,
            // P1-3：本调用生效沙箱模式（四层解析：approved 显式 > 会话末条
            // sandbox/mode 事件 > 新会话默认源 > 部署默认——前三层由
            // PermissionCoordinator 折叠，此处取实时值；approved 显式 stamp
            // 发生在工具体内 SandboxGate.resolveMode）。
            sandboxModeProvider: { [permission] in permission.knobs.sandbox },
            escalationApprover: escalationApprover)
        return (AgentLoop(deps: deps), nil, coordinator, questionService, permission,
                planMode, attachments)
    }
}
