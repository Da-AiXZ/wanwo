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
    /// M4-D D7：设置·技能管理（启停覆盖层+迁移导入）。
    case skills
    /// M6.4（B3）：设置·外挂载文件夹管理（F071；MountedFoldersManager 状态面）。
    case mounts
    case none
}

/// App 装配容器：会话仓库 + GRDB 索引 + 端点配置。
@MainActor
final class AppEnvironment: ObservableObject {
    let endpointStore: EndpointStore
    let sessionStore: SessionStore
    /// R1 诚实化：App 级会话真值源（当前会话/列表纪元）。运行状态真值=下方
    /// pendingInteractionSessionIDs + activeRunSessionIDs 两个既有镜像（M6.6 B4 建）。
    /// 存储属性赋值在 init 内 sessionStore 之后（两阶段初始化：先于首个 self 捕获闭包）。
    let appState: WOAppState
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
    /// M4-D D7：技能启停覆盖层宿主（config/skills-settings.json；Application
    /// Support 约定与 providers/permission-default/mcp-servers 同族）。
    let skillSettingsStore: SkillSettingsStore
    /// M5-A G1：资源护栏 Swift 门面（App 级单例——HookConfigLoader 等既有
    /// App 级组件同位装配）。职责：前后台 scenePhase → begin/end
    /// BackgroundCPUGovernor 接线（转发方=WanWoApp 既有 onChange 模式）+
    /// 250ms 内存喂送定时器（init 启动）+ governor zone/fork guard stalls
    /// 状态快照暴露（G2 压测观测面）。
    let resourceGovernor = IshResourceGovernor()
    /// M5-A J2：后台作业注册表（App 级单例——dsh ctx.jobs 一 context 一份
    /// 对应）。J1 缝的本地实现；J3 三工具与完成通知将挂本实例。
    let jobRegistry = LocalJobRegistry()
    /// M7 件 C：子 agent 运行时（providers 注册表 + activation 注册表——dsh
    /// ctx.subagents 进程级服务对应；App 级单例同 jobRegistry 位）。
    let subagentRuntime = SubagentRuntime()
    /// M7 件 C：providers/物化器一次性装配旗标（@MainActor 域属性，免锁）。
    private var subagentRuntimeWired = false
    /// M5-A J3：per-session 完成通知 listener 注销器（makeAgentStack 同会话
    /// 重建栈时先摘旧再挂新——dsh tool-jobs 插件单 listener 语义对应；
    /// MainActor 域属性，免锁）。
    private var jobNoticeDisposers: [String: () -> Void] = [:]
    /// M5-A J4：作业完成本地通知器（07 F007——用户不在看 App 时的可见性面；
    /// App 级单例同 resourceGovernor/jobRegistry 位）。注入缝经 JobNotifier
    /// 可变闭包（测试桩替换）。
    let jobNotifier = JobNotifier()
    /// M7 件 G（F043）：长期记忆账本（独立 GRDB 库 memory-index.sqlite3——
    /// 理由见 MemoryDatabase 头注：E1 禁碰/生命周期独立/codex 拓扑同构）。
    let memoryDatabase: MemoryDatabase
    /// M7 件 G：memory 工件面（memoryPersistentDir 树 + 快照清单——适配③）。
    let memoryStorage: MemoryStorage
    /// M7 件 G：Phase1/Phase2/触发器（App 级单例同 subagentRuntime 位；
    /// runner/seams 在 init 尾 bind——两阶段初始化纪律同 workspaceNavigator）。
    let memoryPhase1: MemoryPhase1
    let memoryPhase2: MemoryPhase2
    let memoryTrigger: MemoryTrigger
    /// M7 件 L（F046）：Agent Teams 服务（journal/花名册/邮箱/任务板/活动——
    /// App 级单例；seams 在 init 尾 configure——两阶段初始化纪律同 memoryPhase2）。
    let teamService: TeamService
    /// M7 件 L：Team loop 目录（Lead 运行态供值——TeamSeams.leadStatus 消费；
    /// makeAgentStack 登记每个装配栈的 loop 公开缝引用）。
    let teamLoops = TeamLoopDirectory()
    /// 真机批 B 全方位诊断：会话 writer 注册表（diagTrace 写事件流用）。
    /// nonisolated(unsafe)：NSLock 自保护（diagTrace 标 nonisolated 供
    /// 非隔离上下文调用——闭包/调度/通知各面）。
    nonisolated(unsafe) private let writerRegistryLock = NSLock()
    nonisolated(unsafe) private var sessionWriters: [String: SessionWriter] = [:]
    /// M6.5（B3）：workspace registry（F073 存储锚点 + dsh 语义；语义源
    /// dsh workspace.zh.md :12-316，裁定见 WorkspaceRegistry 文件头）。
    let workspaceRegistry: WorkspaceRegistry
    /// M6.5（B3）：workspace controller（dsh 七动词门面 + follow 快照流）。
    let workspaceController: WorkspaceController
    /// UI 对齐批 1（A）：会话创建流 workspace 驱动导航器（dsh navigation.ts
    /// 1:1——connectWorkspace 复用扫描四条件 + startSession 目标解析 +
    /// watchNavigation 启动语义 + recentWorkspace；详见 WorkspaceNavigator 头注）。
    let workspaceNavigator: WorkspaceNavigator
    /// M6.5 验收对齐（10-design:1077「切 workspace 后会话隔离生效」）：新会话
    /// cwd 注入点——选中的工作区 path（nil = 缺省 /var/wanwo/workspace，回落
    /// 既有行为）。侧栏工作区选择 UI 随 B4 左侧栏欠账批；本批先落注入链路。
    @Published var selectedWorkspaceID: String?

    /// 【UI 修复批 2 · review 接线】hero 空态草稿交接缝：hero composer 发送时
    /// 写入（startSession 之前），ChatView onAppear 消费进会话草稿框后清零。
    /// dsh 语义：hero 的输入文本就是新会话的 composer draft（onPick 开会话
    /// 文本不丢）——未接线前 hero 发送丢字（用户每次新建对话必撞）。
    @Published var pendingFirstDraft: String?
    /// hero 附件交接缝（预会话图片 → 新会话 VM.addDraftImages；非发布——
    /// 交接读一次即清，消费方 WOChatView.onAppear）。
    var pendingDraftImages: [ChatViewModel.DraftImageCandidate] = []
    /// hero 一步发送旗（原型 hero 发送=建会话并立即提交首条消息——打字→发送
    /// →用户消息直达；非发布，消费方 WOChatView 读后清）。
    var pendingAutoSubmit = false
    /// 新会话挂组 toast（digest-H「已挂到工作区「X」」；消费方 WORootFrame
    /// 底部 overlay，WOToast onDone 清）。
    @Published var attachToast: String?

    /// 全方位诊断统一入口：任意组件的打点写进对应会话的事件流
    /// （diag/trace，logOnly 不进模型上下文）——用户一个窗口看全貌。
    nonisolated func diagTrace(sessionId: String, _ note: String) {
        writerRegistryLock.lock()
        let writer = sessionWriters[sessionId]
        writerRegistryLock.unlock()
        guard let writer else {
            // 真机批 B2：吞错可见化——此前注册表未命中时静默 return，diag
            // 零事件无法区分「没打点」与「打点丢了」。
            Self.logger.warning("[diag] no writer for session " + sessionId
                                + "; dropped: " + note)
            return
        }
        Task {
            do {
                _ = try await writer.append(.extensionEvent(
                    kind: "diag/trace",
                    payload: .object(["note": .string(note)])))
            } catch {
                Self.logger.error("[diag] append failed: "
                                  + String(describing: error) + " note=" + note)
            }
        }
    }
    /// M5-B S2：沙箱 provider 注册表——本地 iSH 后端默认（S1）；远程 E2B
    /// opt-in 经 enableRemoteSandbox 装配（validateConnection 通过才可选用）。
    /// confine 消费面接线留 P2——本件不动 ShellTool（行为零变化）。
    var sandboxRegistry = SandboxProviderRegistry(
        local: LocalSandboxProvider(), remote: nil)

    /// M5-B S2：远程沙箱 opt-in。apiKey 缺省解析（env `E2B_API_KEY` >
    /// Info.plist `E2BAPIKey`——RemoteSandboxConfig.resolveAPIKey）不落代码/
    /// 日志；validateConnection 未通过时结构化吞掉（注册表回落本地唯一候选）。
    /// - Parameter config: 调用方构造的配置（apiKey 可传 nil 触发缺省解析）。
    /// - Returns: 连通验证报告；配置缺 apiKey（校验拒绝）= nil。
    func enableRemoteSandbox(apiKey: String? = nil) async -> RemoteConnectionReport? {
        let resolved = apiKey
            ?? RemoteSandboxConfig.resolveAPIKey(
                env: ProcessInfo.processInfo.environment,
                infoPlist: Bundle.main.infoDictionary)
        guard let resolved else { return nil }
        guard let provider = try? RemoteSandboxProvider(
            config: RemoteSandboxConfig(apiKey: resolved)) else { return nil }
        let report = await provider.validateConnection()
        if report.ok {
            sandboxRegistry = SandboxProviderRegistry(
                local: sandboxRegistry.local, remote: provider)
        }
        return report
    }

    /// 会话列表版本号（创建/删除/标题落盘时 +1，驱动侧栏刷新）。
    @Published var sessionsRevision = 0
    /// a①（吞错面修复）：会话删除失败的用户可见反馈——此前 deleteSession
    /// 的 try? 静默吞掉异常，用户看到行「消失又回来」、重试怎么点都没用。
    /// 非 nil 时由 SessionsSidebarView 以 alert 呈现，呈现后清零。
    @Published var sessionActionError: String?
    /// f②（bug f-1，lead 批准）：事件流 replay 结果缓存——key=会话 id +
    /// sessionsRevision 快照双键失效（删除/新增会话即失效），进过一次的
    /// 会话秒开、消除重复 replay 堆积。容量 2（插入序淘汰），MainActor 域。
    let eventStreamReplayCache = EventStreamReplayCache()
    @Published var selection: RootSelection = .none
    /// 【批3 A】设置面板当前分区（nil = 面板关闭——dsh SettingsRoot activeId
    /// undefined 语义）。面板挂 RootView 全窗 overlay（取舍见 SettingsPanelView
    /// 头注：detail 区不切换，免 preSettings 记忆与 NavigationStack 状态丢失）。
    @Published var settingsPane: SettingsPane?

    /// 【批3 A】打开设置面板（缺省 Providers 分区；深链 wanwo://settings/
    /// permissions → openSettings(at: .permissions)——OffloadPermissionManager
    /// deny 文案落点，B1c 闭环勿断）。
    func openSettings(at pane: SettingsPane = .providers) {
        settingsPane = pane
    }

    /// 【批3 A】关闭设置面板（dsh close 回调 activeId=undefined 语义）。
    func closeSettings() {
        settingsPane = nil
    }
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

    /// M6.6（B4）：运行中会话镜像（侧聊父会话状态行数据源——主对话
    /// 运行中/空闲；ChatViewModel 在 onPhaseChange / onTurnEnd 登记）。
    @Published private(set) var activeRunSessionIDs: Set<String> = []

    /// 运行态登记（running = 回合进行中；false = 回合收束）。
    func noteRunState(sessionId: String, running: Bool) {
        if running {
            activeRunSessionIDs.insert(sessionId)
        } else {
            activeRunSessionIDs.remove(sessionId)
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
        let configDir = base.appendingPathComponent("config", isDirectory: true)
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

        // M4-E+ P1（项目锚点存储半边）：分组迁移器——时序硬约束：SessionDatabase
        // v3 迁移（groups 表 + sessionIndex.groupId 列 + default seed）已在上方
        // db 打开时完成，本迁移器在其后、SessionStore 构造前同步执行（brief §5.2）：
        //   · 旧 base/sessions 下 *.jsonl → groups/default/sessions/
        //   · persistentBase 直下 UUID 形状且含已知 bucket 的会话桶目录 →
        //     groups/default/<sid>/
        //   · GRDB groupId IS NULL 回填 'default'
        // fail-open（源数据绝不删除，单项失败记日志继续，下次启动重试）；幂等
        // ——重复运行 no-op，常态第二次启动起零动静。
        _ = GroupStoreMigrator(base: base, database: db).migrate()

        // M4-E+ P1：SessionStore root 注入分组维度路径（groups/default/sessions）
        // ——brief §5.2「SessionStore(root:) 注入点改 groups/<gid>/sessions（
        // AppEnvironment:104→123 一处）」，SessionStore 本体签名不动；db 留在
        // base 根=跨分组全局索引，不动。
        let sessionsRoot = GroupStore.groupSessionsRoot(
            base: base, groupID: GroupStore.defaultGroupID)
        try? FileManager.default.createDirectory(at: sessionsRoot,
                                                 withIntermediateDirectories: true)
        self.sessionStore = SessionStore(root: sessionsRoot, database: db)
        // R1 诚实化（11-ui-design §十二 R1）：App 级会话真值源装配——
        // ①当前会话 ②列表失效信号→纪元 bump（运行状态③直接消费下方既有镜像）。
        let appState = WOAppState()
        self.appState = appState
        sessionStore.setExternalListSignal { [weak appState] in
            Task { @MainActor [weak appState] in
                appState?.bumpSessionList()
            }
        }

        // M6.5（B3）：workspace registry + controller（F073 锚点 + dsh 语义）。
        // header 缝 = 直读分组维度 sessions/<id>.jsonl 首行（SessionLogScanner
        // 轻量探针——绝不读事件正文，dsh bootstrap 纪律）；attach 校验与
        // bootstrap 分组共用。realpath/存在性缝用默认实现（挂载 + 静态 fakefs
        // 两面，见 WorkspaceRegistry.GuestPathCanonicalizer）。
        let headerReader: @Sendable (String) -> SessionHeader? = { sid in
            guard let url = Self.sessionFileURL(sid) else { return nil }
            guard let probe = try? SessionLogScanner.probeLightweight(fileURL: url) else {
                return nil
            }
            return probe.header
        }
        let registry = WorkspaceRegistry(database: db, headerProvider: headerReader)
        self.workspaceRegistry = registry
        self.workspaceController = WorkspaceController(registry: registry)

        // 批12+（2026-09-27 用户拍板）：bootstrap 不再自动建工作区记录（下方
        // 调用已移除）；**存量自动记录一次性清理**——path==桶根 的记录按删除
        // C 语义连会话清（用户自建工作区路径为 DirectoryPicker 真实目录，不可
        // 能等于桶根）。会话删除走 actor 异步 API → 启动后 Task 收口（此刻无
        // 开启写柄，竞争面为零）。
        for record in registry.list() where record.path == WanWoPaths.workspaceLinuxDir {
            let orphanSessionIds = record.sessionIds
            let orphanRecordID = record.id
            Task { [sessionStore, workspaceController] in
                for sid in orphanSessionIds {
                    try? await sessionStore.deleteSession(id: sid)
                }
                _ = try? workspaceController.delete(id: orphanRecordID)
            }
        }

        // UI 对齐批 1（A）：navigation.ts 语义移植——缝闭包注入（weak self；
        // 测试面同构注入桩，不触真身）。createSessionInWorkspace = createSession
        // (cwd: ws.path) + attachSession 的 B3 既有注入链收口。
        // 赋值点在依赖（database/workspaceRegistry/workspaceController）初始化后、init 内
        // 首个 self 捕获闭包之前——Swift 两阶段初始化：逃逸闭包 [weak self] 捕获
        // 须待全部存储属性完成阶段一（CI 35124325714 实证 :371 Task 捕获被否）。

        // 首启 bootstrap（dsh :122——按 header cwd 分组一次；标记最后写）。
        // 批12+（2026-09-27 用户拍板）：**不再自动建工作区记录**——调用移除；
        // 存量自动记录的清理随删工作区 C 批（连会话删语义）。
        // _ = registry.bootstrapIfNeeded()

        // 【工作区模型修正】项目目录快照初始推送（boot 后 performMount 兜底
        // 补注册 meta.db——既有项目在 kernel 冷启动完成前 adopt 的兜底面）。
        let projectDirs = registry.list()
            .map(\.path)
            .filter { WanWoPaths.isProjectsGuestPath($0) && $0 != WanWoPaths.projectsLinuxDir }
        IshExecutorBridge.setProjectDirectories(projectDirs)

        // M6.4（B3）：外挂载激活——启动后台解析全部 bookmark 并持安全 scope
        // （MountedFoldersManager.activateAll；绝不阻塞主线程，5s 竞速纪律在件内）。
        MountedFoldersManager.shared.activateAll()

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
        // M4-D D7：技能启停覆盖层（config/skills-settings.json；Application
        // Support 约定与 providers/permission-default/mcp-servers 同族）。
        self.skillSettingsStore = SkillSettingsStore(
            fileURL: configDir.appendingPathComponent("skills-settings.json"))
        // M4-D D7 验收实证：bundled 安装原在 makeAgentStack（会话栈构建时机）——
        // 首次启动无会话时 Skills 页 .bundled 为空（"新建对话后才出现"）。移到
        // App 级 init（App 启动即安装；fail open——bundled 技能可选）。
        do {
            try BundledSkillInstaller.install(
                files: BundledSkillInstaller.bundledFiles(),
                targetRoot: WanWoPaths.skillsPersistentDir
                    .appendingPathComponent(".bundled", isDirectory: true))
        } catch {
            Self.logger.error("bundled skills install failed: " +
                              "\(String(describing: error))")
        }

        // M7 件 G（F043）：memory 组件装配（fail-open 兜底同 SessionDatabase
        // 既有纪律——打开失败落临时路径，App 可启动、管线自愈）。
        // 账本/工件/Phase1/Phase2/触发器五件一起装配；runner/seams 在 init 尾
        // bind（两阶段初始化——self 捕获须待全部存储属性完成阶段一）。
        let memoryDB: MemoryDatabase?
        do {
            memoryDB = try MemoryDatabase(
                path: base.appendingPathComponent("memory-index.sqlite3").path)
        } catch {
            Self.logger.fault("memory database open failed: \(String(describing: error))")
            memoryDB = nil
        }
        let resolvedMemoryDB = memoryDB ?? (try? MemoryDatabase(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-memory-fallback.sqlite3").path))!
        self.memoryDatabase = resolvedMemoryDB
        let resolvedMemoryStorage = MemoryStorage(
            rootURL: WanWoPaths.memoryPersistentDir,
            manifestURL: configDir.appendingPathComponent("memory-snapshot.json"))
        self.memoryStorage = resolvedMemoryStorage
        self.memoryPhase1 = MemoryPhase1(database: resolvedMemoryDB, complete: { _ in
            // 占位缝：configure 前不可达（触发器仅在装配后启动管线）。
            throw LLMError(message: "memory phase-1 not configured", code: "UNKNOWN")
        })
        self.memoryPhase2 = MemoryPhase2(database: resolvedMemoryDB)
        self.memoryTrigger = MemoryTrigger(database: resolvedMemoryDB,
                                           storage: resolvedMemoryStorage)
        // M7 件 L（F046）：Team 服务占位创建（missing 缝——真缝在 init 尾
        // configure；闭包捕获 self 须待全部存储属性完成阶段一）。
        self.teamService = TeamService(seams: .missing)

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

        // M4-E E3 报批登记：hook/invoked / hook/result 扩展事件 schema（E1
        // 通道——M4-E 批次报批项，dsh hook-protocol events.ts 事件对原件词汇；
        // projection=logOnly 审计记录；invoked↔result 以 handlerId 应答配对
        // ——SessionInvariant 先关后开序；dialect 封闭值域未知即拒）。
        HookSessionEvents.registerEventSchemas()

        // M5-B P3 报批登记：tool/ptc-dispatch-start / tool/ptc-dispatch 扩展
        // 事件 schema（E1 通道——M5-B 批次派单拍板⑤，dsh tools types.ts:25-57
        // 事件对原件词汇；projection=logOnly（子调用永不重入模型上下文），
        // pairing=none（UI 按 subCallId 配对、time 定时序，非 SessionInvariant
        // 应答对））。
        PtcDispatchEvents.registerEventSchemas()
        JscoreTraceEvents.registerEventSchemas()
        DiagTraceEvents.registerEventSchemas()

        // 【批3 编译五】noops 占位创建：Seams 真闭包捕获 self，而逃逸闭包
        // 捕获 self 须待全部存储属性完成阶段一（Swift 两阶段初始化）——
        // 真缝在 init 尾 bind（见 workspaceNavigator.attach 前）。
        workspaceNavigator = WorkspaceNavigator(seams: .noops)

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

        // M5-A G1：资源护栏喂送定时器启动（App 生命周期常驻，幂等）。喂送
        // 必须持续而非仅前台——内核 stale 规则（Vendor/ish/kernel/mm.h:110-111）
        // 把 >2s 未喂判为死采样器 fail-closed 进 BRAKE；首喂早于 guest boot
        // 是期望行为（main.c:367-370 "Prime the feed BEFORE the guest boots"）。
        resourceGovernor.start()

        // M5-A J2：job controller 挂接（'tool-jobs' 名称等价——servesOwner
        // 门控放行 producer start；J3 三工具装配时与 dsh tool-jobs 插件
        // 语义对齐）。App 生命周期常驻，disposer 不取。
        jobRegistry.attachController(name: "tool-jobs")

        // 万我 M6.1 增（B1c ④审批接线）：offload askOnce 审批缝 → SwiftUI
        // 审批卡（OpenMinis OffloadPermissionDialog 同款，呈现语义对齐原件
        // pendingRequest + respond）。OffloadPermissionManager 为 App 级单例
        // （内核分发点经 checkForKernel 触达），缝装配同位其他 App 级
        // manager（resourceGovernor/jobRegistry 先例）；呈现卡挂 RootView
        // （.offloadPermissionDialog()，全局覆盖——offload 审批可来自任意
        // 会话的内核分发点，非单会话面）。
        OffloadApprovalPresenter.shared.install()



        // UI 对齐批 1（A）：watchNavigation 启动语义（navigation.ts:157-200）
        // ——订阅 sessionsRevision + 工作区 follow 快照流，就绪后无选中会话
        // 即自动 connectWorkspace(recent) 并打开。
        // 【批3 编译五】init 尾 bind 真缝：此处全部存储属性已完成阶段一，
        // Seams 闭包捕获 self 方才合法（noops 占位见上）。
        workspaceNavigator.bind(seams: WorkspaceNavigator.Seams(
            workspaces: { [weak self] in self?.workspaceRegistry.list() ?? [] },
            sessions: { [weak self] in self?.database.list() ?? [] },
            currentSessionID: { [weak self] in
                if case .session(let id) = self?.selection { return id }
                return nil
            },
            clearSelection: { [weak self] in self?.selection = .none },
            openSession: { [weak self] in self?.selection = .session(id: $0) },
            createSessionInWorkspace: { [weak self] in
                await self?.createSession(inWorkspace: $0)
            },
            archivedSessionIDs: { [weak self] in
                self?.workspaceRegistry.archivedSessionIDs() ?? []
            },
            probeSession: { [weak self] in self?.sessionNavProbe($0) },
            isReady: { [weak self] in (self?.sessionsRevision ?? 0) >= 1 }))
        workspaceNavigator.attach(environment: self)

        // 【批2 B⑦】权限判定观测缝接线：判定注记 → diagTrace（进会话事件流
        // diag/trace，logOnly 不进模型上下文——AppEnvironment.diagTrace 既有
        // 通道）。内核路径无会话上下文 → sessionId=OFFLOAD_GLOBAL_SESSION_ID
        // 全局桶（OffloadPermissionManager.checkPermission 解析后回落）——无
        // writer 时 diagTrace 降级 OSLog 警告，判定留痕不丢（简报 B⑦「落全局
        // 注记」的形态拍板：注记统一走既有 diag 通道，全局桶即全局注记面）。
        // 闭包捕获 self 须在全部存储属性初始化之后（init 末尾，同上方
        // navigator 纪律）。
        OffloadPermissionManager.shared.decisionObserver = { [weak self] sessionId, note in
            self?.diagTrace(sessionId: sessionId, "[offload-perm] " + note)
        }

        // 【批3 下载落点 2026-09-27】装配期注册会话工作区路径解析器（同上方
        // decisionObserver 的 init 末尾捕获纪律）——BrowserTabPool 下载落点经
        // 此取 guestWorkspacePath（项目真目录 Downloads/，废桶死角修正）。
        BrowserUseSessionStore.workspacePathResolver = { [weak self] sid in
            guard let self else { return nil }
            let path = self.guestWorkspacePath(for: sid)
            return path.isEmpty ? nil : path
        }

        // M7 件 G（F043）：memory 管线缝 bind（init 末尾——self 捕获纪律同上方
        // workspacePathResolver/decisionObserver）。装配行号随交付报告呈报。
        // ①Phase2：整合 runner（受限子会话——ChildMaterializer 模式复用）+
        //   工件 storage + 元数据 cwd 供值缝。
        // ②Phase1：连接事实（活动端点冻结——管线运行期不观察配置变化，dsh
        //   凭据同代配对语义）。
        // ③触发器：宿主缝（前台/空闲镜像 + 只读枚举 + 模型窗缺省）。
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.memoryPhase2.configure(MemoryPhase2.Configuration(
                storage: self.memoryStorage,
                runner: { [weak self] prompt in
                    guard let self else {
                        throw LLMError(message: "environment released", code: "UNKNOWN")
                    }
                    try await self.runMemoryConsolidationSession(prompt: prompt)
                },
                cwdFor: { threadId in
                    guard let url = AppEnvironment.sessionFileURL(threadId),
                          let probe = try? SessionLogScanner.probeLightweight(fileURL: url),
                          let cwd = probe.header.cwd, !cwd.isEmpty else {
                        return WanWoPaths.workspaceLinuxDir
                    }
                    return cwd
                }))
            if let endpoint = self.endpointStore.activeEndpoint(),
               let apiKey = await self.endpointStore.apiKey(for: endpoint),
               !apiKey.isEmpty {
                await self.memoryPhase1.configure(
                    baseURL: endpoint.baseURL, apiKey: apiKey, model: endpoint.model)
            }
            self.memoryTrigger.attach(MemoryTrigger.HostSeams(
                listSessions: { [weak self] in
                    await self?.sessionStore.listSessions() ?? []
                },
                readSessionEvents: { sid in
                    guard let url = AppEnvironment.sessionFileURL(sid) else { return nil }
                    guard let log = try? JsonlEventLog.open(
                        fileURL: url, writeMode: false, expectedID: sid) else {
                        return nil
                    }
                    return await log.snapshotEvents()
                },
                activeRunSessionIDs: { [weak self] in
                    await MainActor.run { self?.activeRunSessionIDs ?? [] }
                },
                isForeground: { [weak self] in
                    await MainActor.run { self?.isAppForegroundActive ?? false }
                },
                phase1: self.memoryPhase1,
                phase2: self.memoryPhase2,
                contextWindowTokens: { nil },
                sessionCWD: { sid in
                    guard let url = AppEnvironment.sessionFileURL(sid),
                          let probe = try? SessionLogScanner.probeLightweight(fileURL: url),
                          let cwd = probe.header.cwd, !cwd.isEmpty else {
                        return WanWoPaths.workspaceLinuxDir
                    }
                    return cwd
                }))

            // M7 件 L（F046）：Team 服务真缝绑定（AgentLoop/SubagentRuntime
            // 冻结件一律经公开缝调用；所需新缝清单见交付报告）。
            teamService.configure(seams: TeamSeams(
                appendEvent: { [weak self] rootId, kind, payload in
                    guard let self else {
                        throw LLMError(message: "environment released", code: "UNKNOWN")
                    }
                    // journal appendAndFlush 的 append+落盘半边（append 返回即
                    // 持久——SessionWriter.append 落盘语义，flush 等价承载）。
                    let opened = try await self.sessionStore.openWriter(id: rootId)
                    _ = try await opened.writer.append(
                        .extensionEvent(kind: kind, payload: payload))
                },
                readEvents: { sessionId in
                    guard let url = AppEnvironment.sessionFileURL(sessionId) else {
                        return nil
                    }
                    guard let log = try? JsonlEventLog.open(
                        fileURL: url, writeMode: false, expectedID: sessionId) else {
                        return nil
                    }
                    return await log.snapshotEvents()
                },
                allSessionIds: { [weak self] in
                    await self?.sessionStore.listSessions().map(\.id) ?? []
                },
                leadSteer: { [weak self] rootId, text, senderId in
                    // target=Lead 投递分支（批1 steer 语义缝——mailbox
                    // dispatchOnce :249-253 对应）。所需缝：InboxSource 增
                    // `.teamMessage(senderId: String)` case（AgentLoop.swift
                    // :39-40 subagentMessage case 后插）；当前以
                    // .subagentMessage 过渡（非 directHuman 语义等价）。
                    guard let self, let loop = self.teamLoops.get(rootId) else {
                        throw TeamError("team lead is not live",
                                        code: "TEAM_INVALID_TARGET")
                    }
                    await loop.steer(text, source: .subagentMessage(childId: senderId))
                },
                deliverToTeammate: { [weak self] rootId, targetId, text in
                    // teammate 分支（SubagentRuntime.sendMessage 公开缝——宿主
                    // 仲裁形态 from=rootId，dsh steerHostSubagentPrompt 同族；
                    // inactive 目标缝内惰性冷恢复/remountIfNeeded 承载）。
                    // source=.subagentMessage 透传（主理人合并 2026-09-28：缝
                    // 已就位——teammate 收 team 消息不计 directHuman authority，
                    // QA-6 P1-5 误判防线闭环）。
                    guard let self else {
                        throw TeamError("environment released", code: "TEAM_INVALID_TARGET")
                    }
                    _ = try await self.subagentRuntime.sendMessage(
                        from: rootId, to: targetId, text: text,
                        source: .subagentMessage(childId: rootId))
                },
                interruptTeammate: { [weak self] childId, callerSessionId in
                    guard let self else { return false }
                    return try await self.subagentRuntime.interrupt(
                        childId: childId, callerSessionId: callerSessionId)
                },
                memberStatuses: { [weak self] rootId in
                    guard let self else { return [:] }
                    let listings = await self.subagentRuntime.listAgents(
                        callerSessionId: rootId, includeDescendants: false)
                    return Dictionary(uniqueKeysWithValues:
                        listings.map { ($0.subagentId, $0.status) })
                },
                leadStatus: { [weak self] rootId in
                    guard let self, let loop = self.teamLoops.get(rootId) else { return nil }
                    switch await loop.currentPhase() {
                    case .running, .maintenance: return "running"
                    case .idle: return "idle"
                    }
                },
                sessionCwd: { sessionId in
                    guard let url = AppEnvironment.sessionFileURL(sessionId),
                          let probe = try? SessionLogScanner.probeLightweight(fileURL: url),
                          let cwd = probe.header.cwd, !cwd.isEmpty else { return nil }
                    return cwd
                },
                startTeammate: { [weak self] provider, request in
                    guard let self else {
                        throw TeamError("environment released", code: "TEAM_INVALID_TARGET")
                    }
                    // QA-6 P1-3：fork teammate 真继承 Lead 完成回合（dsh fork
                    // 语义）——缝内读 root 日志 + completedTurnPrefix 切片（批1
                    // ForkInProcessProvider 切片语义复用；spawn/fresh 不读）。
                    var parentLogEvents: [SessionEvent] = []
                    if provider == "fork" {
                        if let url = AppEnvironment.sessionFileURL(request.parentSessionId),
                           let log = try? JsonlEventLog.open(
                            fileURL: url, writeMode: false,
                            expectedID: request.parentSessionId) {
                            parentLogEvents = ForkInProcessProvider.completedTurnPrefix(
                                await log.snapshotEvents())
                        }
                    }
                    return try await self.subagentRuntime.startContinuable(
                        provider: provider, request: request,
                        parentLogEvents: parentLogEvents)
                },
                // QA-6 P1-2：journal 权威拒绝后 drain 孤儿活子（closeAgent
                // 停回合+摘激活/恢复登记+回收治理计数+置边 Closed）。
                drainChild: { [weak self] childId, callerSessionId in
                    guard let self else { return false }
                    return try await self.subagentRuntime.closeAgent(
                        childId: childId, callerSessionId: callerSessionId)
                })
            // 启动恢复（index.ts scheduleRecovery/recoverFor 承载）：provisioning
            // reconcile + pending 邮箱重试。后台一次性；失败 warn 不致命。
            let teamService = self.teamService
            Task {
                await teamService.recoverAll()
            }
        }
    }

    // MARK: - M7 件 G（F043）：memory 前台镜像 + 整合 runner

    /// 前台快照（scenePhase 转入门的镜像源——WanWoApp onChange .active 落
    /// memoryTrigger.onDidEnterForeground 的同时翻转本旗标；装配行号随报告）。
    @Published var isAppForegroundActive = true

    /// Phase2 整合子会话 runner（agent::get_config 锁死清单的万我承载——
    /// 完整对照与偏差登记见 MemoryPhase2 头注）：
    ///   · ephemeral：临时子会话（UUID），收口后删除（get_config :322）；
    ///   · cwd=memory guest 根：文件/shell/技能 project 根全部限定 memory 树；
    ///   · 收口判定：尾回合（turn/end 且本回合无 tool/call——agent 自然终止
    ///     语义；onTurnEnd 信号 + 事件流复核）；
    ///   · generate/use_memories=false → 子会话 cwd 不在候选枚举面（触发器
    ///     防回流判定）+ 非根会话；notify=None → onTurnEnd 仅收口信号；
    ///   · mcp_servers=空/approval=Never/Collab/MemoryTool/Apps/Plugins 禁/
    ///     WorkspaceWrite 仅 memory root 无网 → QA-5 P1-1 三闸已装（最小
    ///     修法）：MemoryTools/web 双族 toolFilter 注册闸禁 + 沙箱锁定
    ///     （subagentSandboxOverride=.workspaceWrite × cwd=memoryGuestPath，
    ///     approval Never 随缝折叠）+ effort medium（会话级选择缝）；完整
    ///     per-stack 策略参数化（mcp_servers 空/Collab/Apps 面等）仍留 P2。
    func runMemoryConsolidationSession(prompt: String) async throws {
        let childId = UUID().uuidString
        _ = try await sessionStore.createSession(
            withID: childId, cwd: MemoryConstants.memoryGuestPath)
        do {
            let opened = try await sessionStore.openWriter(id: childId)
            let writer = opened.writer
            // 尾回合判定：turn/end 且自对应 turn/start 起无 tool/call。
            let gate = MemoryTurnCompletionGate(writer: writer)
            // QA-5 P1-1③：整合会话推理档锁定 medium（codex get_config :338-348
            // reasoning_effort=Medium）——经会话级选择缝承载（活动端点 + effort
            // 覆盖；无活动端点时选值空，由下方 stack.loop 装配失败兜底）。
            let modelSelection: SessionModelSelection
            if let active = endpointStore.activeEndpoint() {
                modelSelection = SessionModelSelection(initial: .init(
                    endpointID: active.id,
                    reasoningEffort: MemoryConstants.stageTwoReasoningEffort))
            } else {
                modelSelection = SessionModelSelection()
            }
            let stack = await makeAgentStack(
                sessionId: childId,
                writer: writer,
                callbacks: AgentLoop.Callbacks(onTurnEnd: { [gate] _ in
                    gate.evaluateAndSignalIfFinal()
                }),
                interactionPresenter: nil,
                modelSelection: modelSelection,
                subagentDepth: nil,
                // QA-5 P1-1③：沙箱锁定（workspaceWrite × cwd=memoryGuestPath
                // = 仅 memory 树可写）+ approval Never（override 缝随
                // PermissionCoordinator.newSessionDefaults 折叠为 (.workspaceWrite,
                // .never)——codex get_config :322-348 对应）。
                subagentSandboxOverride: .workspaceWrite,
                // QA-5 P1-1①②：整合会话禁 MemoryTools 族（codex :333 MemoryTool
                // disable——防递归抽取）+ 禁 web 族（codex :352 network_access=
                // false）——toolFilter 注册闸按工具名裁决。
                toolFilter: { tool in
                    switch tool.name {
                    case "list_memories", "read_memory", "search_memories",
                         "add_ad_hoc_note", "web_search", "web_fetch":
                        return false
                    default:
                        return true
                    }
                })
            guard let loop = stack.loop else {
                throw MemoryError(message:
                    "consolidation stack assembly failed: "
                        + (stack.failureReason ?? "unknown"))
            }
            await loop.submit(prompt)
            // QA-5 P2-②：超时兜底（codex status_poll 等价——AgentLoop 异常
            // 路径不发 onTurnEnd 时 gate 永挂 → 触发器整进程单飞死锁；超时
            // 抛错 = failed_agent 语义，进重试窗）。
            guard await gate.wait(
                timeout: MemoryConstants.consolidationWaitTimeoutSeconds) else {
                throw MemoryError(message:
                    "consolidation agent did not finalize within "
                        + "\(Int(MemoryConstants.consolidationWaitTimeoutSeconds))s")
            }
            await sessionStore.closeWriter(id: childId)
            try? await sessionStore.deleteSession(id: childId)
        } catch {
            // ephemeral 收口：任何失败路径都删除临时会话。
            await sessionStore.closeWriter(id: childId)
            try? await sessionStore.deleteSession(id: childId)
            throw error
        }
    }

    // MARK: - 会话

    func loadSessions() async -> [SessionSummary] {
        await sessionStore.listSessions()
    }

    func createSession() async -> SessionSummary? {
        // 【工作区模型修正】缺省 cwd 退役——无工作区时绝不创建会话（与
        // WorkspaceNavigator.startSession 的 clear 语义收口一致：无任何工作区
        // → 清空当前选择落空态项目选择页，绝不产生游离会话）。
        guard let wid = selectedWorkspaceID, let ws = workspaceRegistry.get(wid) else {
            return nil
        }
        return await createSession(cwd: ws.path, workspaceID: wid)
    }

    /// UI 对齐批 1（A）：connectWorkspace 落点——指定工作区建会话（cwd =
    /// workspace.path 注入 + attachSession 校验；B3 既有链路收口，dsh
    /// sessions.create({workspaceId}) 的 cwd 由服务端定为 workspace.path 同语义）。
    func createSession(inWorkspace workspaceID: String) async -> SessionSummary? {
        guard let ws = workspaceRegistry.get(workspaceID) else { return nil }
        selectedWorkspaceID = workspaceID
        guard let summary = await createSession(cwd: ws.path, workspaceID: workspaceID)
        else { return nil }
        // 新会话挂组 toast（digest-H「已挂到工作区「X」」；仅新建发射——
        // 复用既有 blank 不打扰）。
        attachToast = "已挂到工作区「\(ws.title)」"
        return summary
    }

    /// 创建核心（cwd + 工作区 attach——无游离会话语义收口）。
    private func createSession(cwd: String, workspaceID: String) async -> SessionSummary? {
        guard let summary = try? await sessionStore.createSession(cwd: cwd) else {
            return nil
        }
        do {
            try workspaceRegistry.attachSession(sessionId: summary.id,
                                                to: workspaceID)
        } catch {
            // attach 校验失败（如 header cwd 与工作区 path 漂移）→ 未分组桶已
            // 删除，孤儿会话在侧栏不可见——绝不留游离会话：回滚刚建的会话并
            // 以 nil 报告创建失败（错误进日志；调用方按失败收口）。
            Self.logger.error("workspace attach failed for \(summary.id): \(String(describing: error)); rolling back orphan session")
            await sessionStore.closeWriter(id: summary.id)
            try? await sessionStore.deleteSession(id: summary.id)
            return nil
        }
        sessionsRevision += 1
        return summary
    }

    // MARK: - UI 对齐批 1（A）：导航探针缝

    /// 会话事件流文件 URL（id 形态与 SessionStore.fileURL 同校验——fail closed）。
    nonisolated fileprivate static func sessionFileURL(_ sessionID: String) -> URL? {
        guard !sessionID.isEmpty,
              sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return GroupStore.groupSessionsRoot(
            base: WanWoPaths.persistentBase, groupID: GroupStore.defaultGroupID)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    /// 复用扫描/blank 判定的轻量探针（简报 A.4：只读 header + 首事件窗口，
    /// 禁止全量读流；probeLightweight 同思路）。
    fileprivate func sessionNavProbe(_ sessionID: String) -> SessionNavProbeResult? {
        guard let url = Self.sessionFileURL(sessionID) else { return nil }
        return SessionNavProbe.probe(fileURL: url)
    }

    func deleteSession(id: String) async {
        // 先关闭可能开放的写柄（排他写所有权归还），再删除。
        await sessionStore.closeWriter(id: id)
        // a①（吞错面修复）：try? 吞错改 do/catch——删除失败必须用户可见，
        // 且不得清选中态/推进 revision 假装成功（旧行为失败后照常 +1 触发
        // 重载把行拉回=视觉「消失又回来」且无任何解释）。失败时会话仍保留。
        do {
            try await sessionStore.deleteSession(id: id)
        } catch {
            Self.logger.error(
                "session delete failed for \(id): \(String(describing: error))")
            sessionActionError =
                "删除会话失败：\(String(describing: error))。会话仍保留在列表中，可重试；若持续失败，请重启 App 后再试。"
            return
        }
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
    /// 会话 guest 工作区前缀（header cwd 单一真值源；读失败/无 cwd 回落桶根）
    /// ——文件页签根、审查页签 git 目录、复制路径钮的统一来源（批12+工作区
    /// 贯穿 2026-09-27 用户裁决：F073 分工作区后这些站点不再写死桶根）。
    func guestWorkspacePath(for sessionID: String) -> String {
        guard let url = Self.sessionFileURL(sessionID),
              let probe = try? SessionLogScanner.probeLightweight(fileURL: url),
              let cwd = probe.header.cwd, !cwd.isEmpty else {
            return WanWoPaths.workspaceLinuxDir
        }
        return cwd
    }

    /// - Parameters:
    ///   - interactionPresenter: 交互呈现缝（ChatViewModel；nil = 无 answerer，
    ///     审批 fail closed unavailable、提问 fail closed NO_PROVIDER）。
    ///   - subagentDepth: 子 agent 委派深度（M7 件 C：nil=顶层会话；非 nil=
    ///     子会话——goal isTopLevel=false + 委派纪律段注入）。
    ///   - subagentSandboxOverride: 父委派的沙箱承载（QA-3 P1-5：非 nil 时
    ///     子会话双旋钮初始值 = (override, .never)——dsh child-agent.ts:221-268
    ///     子纪律；万我 knob 直传登记见报告）。QA-5 P1-1③：整合会话亦经本缝
    ///     锁定（.workspaceWrite × cwd=memory 根 + approval Never）。
    ///   - toolFilter: 工具注册闸（QA-5 P1-1①②：整合会话传过滤闭包——
    ///     禁 MemoryTools 族防递归抽取（codex :333 MemoryTool disable）+
    ///     禁 web 族（codex :352 network_access=false）；nil = 不过滤）。
    ///   - teamScope: Agent Teams 作用域（M7 件 L：teammate 栈由子物化器按
    ///     label 前缀判定传入；nil 时顶层会话（subagentDepth==nil）缺省
    ///     .lead——dsh 隐式 Team 语义（types.ts :7）；teamScope 显式 nil 且
    ///     subagentDepth 非 nil = 普通子会话不注册）。
    /// - Returns: loop = nil 表示装配失败（无端点/凭据不可读），failureReason 带具体
    ///   原因（ERR-016：原 try? 吞错导致降级横幅只有泛化提示，无法定位）。
    /// QA-5 P1-1：注册闸——toolFilter 非 nil 时以探针工具裁决整族注册
    /// （整族语义：codex disable MemoryTool / network_access=false 均为配置
    /// 面整族开关；探针构造成本 = 一次轻量 struct init，仅闸路径发生）。
    private static func toolFamilyAllowed(_ filter: ((AgentTool) -> Bool)?,
                                          _ probe: @autoclosure () -> AgentTool) -> Bool {
        guard let filter else { return true }
        return filter(probe())
    }

    func makeAgentStack(sessionId: String,
                        writer: SessionWriter,
                        callbacks: AgentLoop.Callbacks,
                        interactionPresenter: SessionInteractionPresenter? = nil,
                        modelSelection: SessionModelSelection? = nil,
                        subagentDepth: Int? = nil,
                        subagentSandboxOverride: SandboxMode? = nil,
                        toolFilter: ((AgentTool) -> Bool)? = nil,
                        teamScope: TeamTools.ScopeContext? = nil)
        async -> (loop: AgentLoop?, failureReason: String?,
                  approvalCoordinator: ApprovalCoordinator?,
                  questionService: UserQuestionService?,
                  permission: PermissionCoordinator?,
                  plan: PlanModeController?,
                  attachmentStore: AttachmentStore?) {
        writerRegistryLock.lock()
        sessionWriters[sessionId] = writer
        writerRegistryLock.unlock()
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

        // M5-B P4：注册表呈现模式定档（.both 缺省——native schema 与
        // run_code SDK 两形态并存；dsh Config 缺省 native，WanWo 拍板差异，
        // 见 ToolRegistry 头注）。
        // M5-B N1：网络策略装配常量（F028 第一版：不受限——allowedDomains nil，
        // SSRF 防护恒开；受限形态=域名白名单，接入配置面时替换此常量。R3
        // 禁触——不读 config/；独立 NetworkPolicy 配置，非 SandboxMode 维度）。
        let networkPolicy = NetworkPolicy.unrestricted
        let registry = ToolRegistry(presentationMode: .both)
        // M7 件 A/B/C：extensionEvent 注册面（幂等；重名 fatal 由注册表门保
        // 第一注册权威——装配期一次性，多会话复用注册结果）。
        TodoEvents.register()
        GoalEvents.register()
        SubagentEvents.register()
        // M7 件 L（F046）：team 四事件 schema 注册（幂等——TodoEvents 同款）。
        TeamEvents.register()
        // 【工作区模型修正】会话 header cwd（创建时定格）——shell 前台/后台
        // 通道、hooks、技能 project 根与文件工具直读根的单一事实源。
        let sessionCwd = writer.header.cwd
        registry.register(ShellTool(sessionId: sessionId, sessionCwd: sessionCwd,
                                    jobs: jobRegistry))
        // M5-A J3：job_output / job_list / job_kill 三工具（dsh tool-jobs
        // apply 的 ctx.tools.register ×3 对应；controller 已在 init 挂接）。
        JobTools.registerAll(into: registry, sessionId: sessionId, jobs: jobRegistry)
        FsTools.registerAll(into: registry, sessionId: sessionId)
        // QA-5 P1-1②：整合会话禁网（codex :352 network_access=false——web
        // 双件整族跳过；toolFilter 注册闸，探针裁决整族）。
        if Self.toolFamilyAllowed(toolFilter, { WebFetchTool() }) {
            WebTools.registerAll(into: registry, policy: networkPolicy)
        }
        // M7 件 A（F049）：todo_write 工具（dsh tool-todo apply 1:1——整表
        // 替换 + allowParallelInProgress=false 万我拍板）。
        registry.register(TodoTool(writer: writer))
        // M6.3 B2：browser_use 工具（F033——schema/执行分发语义源=OpenMinis
        // AIChatViewModel+ToolDefinitions:102-132 + ConcurrentTools:547-638，
        // 见 BrowserUseTool.swift 头注）。高风险面审批=提权呈现缝（OriginPolicy.
        // askHandler ← ctx.escalationApprover 逐调用接线，裁定②）；池经
        // BrowserUseSessionStore 与 wanwo-browser-use offload CLI 共享。
        registry.register(BrowserUseTool())

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
                let defaults = permissionDefaults.newSessionKnobs()
                // QA-3 P1-5（dsh child-agent.ts:221-268 子纪律）：子会话 approval
                // 钉死 never + sandbox 承载父委派 override；顶层会话走 App 级
                // 默认源不动。万我 PermissionCoordinator 无显式 override 与
                // 部署缺省的区分缝——knob 直传（子恒收父当前值），登记。
                // QA-5 P1-1③：整合会话复用本缝锁定——subagentSandboxOverride
                // 显式供值即锁定（.workspaceWrite × cwd=memory 根 + approval
                // Never；codex get_config :322-348 对应）。
                guard subagentDepth != nil || subagentSandboxOverride != nil
                else { return defaults }
                return (subagentSandboxOverride ?? defaults.sandbox, .never)
            })
        // 批12+归挡（2026-09-27）：预设切换 → offload 27 命令免问覆盖
        // （完全权限挡=全免问；低挡位按各命令自身档位。App 级最后写语义——
        // 单用户单活跃会话场景下与直觉一致）。
        permission.onPresetChanged = { name in
            OffloadPermissionManager.shared.fullAccessOverride =
                (name == "danger-full-access")
        }

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
                                    lastActivation: mcpLastActivation,
                                    // fs_context 补课（10-design:647）：MCP spawn
                                    // 与本会话 shell 同一文件视图——令牌按 sid
                                    // 幂等，与 ShellTool/FsTools 同源。
                                    fsContext: FsContextRouter.shared.context(for: sessionId))
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

        // M4-C2：tool_search 组装步宿主——M4-C3 起 MCP 工具默认 deferred，
        // 存在 deferred 工具 ⇒ 注册元工具、零 deferred ⇒ 不注册（每步组装前
        // AgentLoop.refresh 收敛；codex spec_plan.rs:371-406 同构）。资源三元
        // /mcp_server_config 等内置元工具走协议默认 .direct，不受影响。
        let toolSearchAssembly = ToolSearchAssembly(registry: registry)

        // M4-D D2：技能三根（project=工作区项目技能根——【工作区模型修正】cwd
        // 落 projects 根时 = 项目目录内 .agents/skills（fakefs 持久层真实目录，
        // shell 写入与宿主直读同源同真）；legacy cwd（存量会话）= 分组级技能根
        // groups/<gid>/workspace/.agents/skills 既有语义不动。user=容器 skills/
        // / bundled=安装位 skills/.bundled——安装已前移至 AppEnvironment init
        // （App 启动一次；D7 验收实证会话栈时机过晚）。
        let skillsUserRoot = WanWoPaths.skillsPersistentDir
        let skillsBundledRoot = skillsUserRoot
            .appendingPathComponent(".bundled", isDirectory: true)
        let projectSkillsRoot: URL
        if let cwd = sessionCwd,
           let projectHost = WanWoPaths.projectsHostRoot(forGuestPath: cwd) {
            projectSkillsRoot = projectHost.appendingPathComponent(
                ".agents/skills", isDirectory: true)
        } else {
            projectSkillsRoot = WanWoPaths.groupSkillsProjectRoot(
                base: WanWoPaths.persistentBase,
                groupID: WanWoPaths.defaultGroupID)
        }
        let skillRegistry = SkillRegistry(roots: [
            .init(source: .project, baseURL: projectSkillsRoot),
            .init(source: .user, baseURL: skillsUserRoot),
            .init(source: .bundled, baseURL: skillsBundledRoot),
        ], settings: skillSettingsStore)
        // M4-D D5：skill 工具（渐进二级入口；direct——内置元工具恒 direct，
        // mcp_server_config 死锁防线同源；registry 注入同 ToolSearchTool 模式）。
        registry.register(SkillTool(registry: skillRegistry))

        let spill = SpillStore(
            root: WanWoPaths.persistentBase
                .appendingPathComponent("spill", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true))
        let repeatAdviser = RepeatCallAdviser()

        // M4-E E5：hooks 装配（E4 loader——Documents/hooks/ 双桥；fail open
        // 语义在 loader 内）。runtime.warnings 装配期逐条 warn（dsh apply 期
        // skipped/load-failure warn 同语义）；双桥全缺 → runner 不装配（nil，
        // 五挂点全部旁路——零开销路径）。
        let hookRuntimes = HookConfigLoader(
            directory: HookConfigLoader.defaultDirectory).load()
        for runtime in hookRuntimes {
            for warning in runtime.warnings {
                Self.logger.warning("hooks assembly: \(warning)")
            }
        }
        let hookPoints: HookPointRunner? = hookRuntimes.isEmpty ? nil : HookPointRunner(
            sessionId: sessionId,
            writer: writer,
            runtimes: hookRuntimes,
            executor: IshHookCommandExecutor(sessionId: sessionId),
            // 【工作区模型修正】hooks cwd 跟随会话工作区（dsh session.header.cwd
            // 语义）；cwd 缺失回落既有缺省 /var/wanwo/workspace。
            cwd: sessionCwd ?? WanWoPaths.workspaceLinuxDir)
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
            repeatAdviser: repeatAdviser,
            hookPoints: hookPoints)
        // M5-B P3：run_code 工具（dsh ptc.ts createRunCodeTool 对应）。注册在
        // pipeline 创建之后：子派发车道闭包捕获同一 registry/pipeline/writer
        //（裁定①——子派发复用 ToolPipeline，hooks 跑、对话事件不落）；
        // JSCodeRuntime 预算 = 配置四缺省（sucrase.js 资源缺失为 run 期
        // 结构化失败，非装配期错误）。
        do {
            let codeRuntime = try JSCodeRuntime(config: JSCodeRuntimeConfig(onTrace: { msg in
                // 真机批 B1：引擎面包屑→事件流导出面（logOnly，不进模型上下文）。
                Task { [writer] in
                    _ = try? await writer.append(.extensionEvent(
                        kind: JscoreTraceEvents.traceKind,
                        payload: .object(["note": .string(msg)])))
                }
            }))
            // P4 保留名语义（真机闪退实证 2026-09-14）：run_code 经专用
            // transport 注册面入场（register 的保留名检查 fatalError——
            // 普通注册面对此工具永不合法，dsh requireCodeTransport :914-925
            // "never enters the global layer" 同构）。
            registry.registerReservedTransport(RunCodeTool(
                pipeline: pipeline, writer: writer, runtime: codeRuntime))
        } catch {
            Self.logger.error("run_code tool registration failed: " +
                              "\(String(describing: error))")
        }
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
        // M7 件 G（F043）：memory read-path 段（codex build_memory_tool_
        // developer_instructions 万我承载——summary 缺失/空 = 不注册段落，
        // prompts.rs :41-43 None 语义；槽位 920 登记见 SECTION_ORDERS）。
        if let summaryData = try? Data(contentsOf: WanWoPaths.memoryPersistentDir
            .appendingPathComponent("memory_summary.md")),
           let summaryText = String(data: summaryData, encoding: .utf8),
           let memorySection = MemoryPromptSection.summarySection(summaryText: summaryText) {
            assembler.section(memorySection)
        }
        // M7 件 G（F043）：memory 四工具（codex memories 扩展四工具——原名 +
        // schema 逐字；后端宿主直读 memoryPersistentDir，件头注裁定）。
        // QA-5 P1-1①：整合会话禁注册（codex :333 MemoryTool disable——防
        // 递归抽取；toolFilter 注册闸，探针裁决整族）。
        let memoryBackend = MemoryBackend(rootURL: WanWoPaths.memoryPersistentDir)
        if Self.toolFamilyAllowed(toolFilter,
                                  { MemoryListTool(backend: memoryBackend) }) {
            MemoryTools.registerAll(into: registry, backend: memoryBackend)
        }
        // M5-B P4：PTC 模式两段（tools:ptc-only@800 / tools:sdk@5000——dsh
        // index.ts:826-829 仅 mode ≠ native 注册；.both 档下 ptc-only 渲染空）。
        PtcPromptSections.registerSections(into: assembler, registry: registry)
        // M5-A J3：tool:jobs 段（dsh tool-jobs index.ts:262-266 逐字；
        // order = SECTION_ORDERS.toolJobs = 1600，dsh TOOL_JOBS 位 1:1）。
        assembler.section(JobTools.promptSection())
        // M7 件 B（F006）：goal 装配（dsh goal + tool-goal + /goal 斜杠命令
        // ——命令面在 SlashCommandRegistry.makeDefault，经 loop.deps.goalService
        // 解析）。子 agent 会话 isTopLevel=false（dsh roots() 检查等价——
        // requireDirectHumanAuthority 据此拒绝子发起）。
        let goalService = GoalService(writer: writer,
                                      isTopLevel: subagentDepth == nil)
        let goalAgentLink = GoalAgentLink()
        registry.register(GetGoalTool(service: goalService))
        registry.register(CreateGoalTool(service: goalService))
        registry.register(UpdateGoalTool(service: goalService, agentLink: goalAgentLink))
        assembler.section(GoalTools.promptSection())
        // M7 件 L（F046）：Agent Teams 工具族（九作用域——wait_agent 复用批1
        // WaitAgentTool 不在此注册）。作用域安装经注册序承载：team 栈（顶层
        // 会话缺省 .lead / teammate 由子物化器 label 前缀判定）先注册八件占名
        //（QA-6 P1-4 主理人裁决批准：Lead 栈同样装 team 版 send_message/
        // interrupt_agent/list_agents——Lead 的团队通信走邮箱持久语义，批1
        // 四件同名对 Lead 被遮蔽是正确的），其后 setupSubagentRuntime 的
        // SubagentTools.registerAll tryRegister 冲突跳过——team 栈只见 team
        // 版（dsh scoped install 语义）；普通（非 team）子代理栈 scope=nil
        // 不注册任何件 → 批1 四件照常生效；受限整合会话（toolFilter 闸在场）
        // 同样不装（dsh 隐式 Team 语义不适用于整合 runner）。
        let effectiveTeamScope = teamScope ?? ((subagentDepth == nil && toolFilter == nil)
            ? TeamTools.ScopeContext(role: .lead, name: "lead", teamId: sessionId)
            : nil)
        TeamTools.registerAll(into: registry, assembler: assembler,
                              service: teamService, scope: effectiveTeamScope)
        // M7 件 C：子会话委派纪律段（child-agent.ts:171-175 子可见声明）。
        if subagentDepth != nil {
            assembler.section(SubagentDelegation.promptSection())
        }
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
        injector.sandboxPolicyProvider = { [permission, sessionCwd] in
            permission.sandboxPolicyContextLine(workspacePath: sessionCwd)
        }
        injector.approvalPolicyProvider = { [permission] in
            permission.approvalPolicyContextLine
        }

        // 真机批 B4：回合完成 → 用户验收提醒（turn/end 且 App 不在前台时
        // 触发——JobNotifier.notifyTurnCompleted；前台完成=用户在场不打扰，
        // 仅自然完成算验收点）。包装既有 onTurnEnd（ChatViewModel UI 刷新）
        // 不替换——两消费者并存。必须在 deps 构造前包装。
        var callbacks = callbacks
        let existingOnTurnEnd = callbacks.onTurnEnd
        let turnNotifySessionId = sessionId
        let turnNotifier = jobNotifier
        callbacks.onTurnEnd = { reason in
            existingOnTurnEnd(reason)
            guard case .completed = reason else { return }   // 仅自然完成=验收点
            Task {
                await turnNotifier.notifyTurnCompleted(sessionId: turnNotifySessionId,
                                                       taskLabel: "万我")
            }
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
            escalationApprover: escalationApprover,
            // M4-C2：tool_search 组装步（存在 deferred 才注册，每步刷新）。
            toolSearchAssembly: toolSearchAssembly,
            // M4-D D2：技能注册表（组装期 refresh + write-edit 失效消费方）。
            skillRegistry: skillRegistry,
            // M4-E E5：hooks 五挂点编排器（UPS/Stop 直挂 loop；Pre/Post
            // 已随 pipeline 注入——同一实例）。
            hookPoints: hookPoints,
            // 真机批 B 全方位诊断：写进会话事件流（diag/trace logOnly）。
            diagTrace: { [weak self] note in
                self?.diagTrace(sessionId: sessionId, note)
            },
            // 【工作区模型修正】会话 header cwd——文件工具直读根 + workspacePath
            // 注入的单一事实源（nil = legacy 缺省语义）。
            sessionCwd: sessionCwd,
            // M7 件 B：goal 服务（goal-round-driver 驱动面 + 工具权威面）。
            goalService: goalService)
        let agentLoop = AgentLoop(deps: deps)
        // M7 件 L：loop 目录登记（TeamSeams.leadStatus/leadSteer 供值——
        // TeamLoopDirectory NSLock 自保护）。
        teamLoops.register(sessionId, agentLoop)

        // M7 件 B：goal 接线（wrapup 注入缝回填 + 'goal/changed' 通知 →
        // AgentLoop.onGoalChanged——dsh agentEvents emit 对应；weak 防环）。
        goalAgentLink.set(agentLoop)
        goalService.onChange = { [weak agentLoop] change in
            Task { await agentLoop?.onGoalChanged(change) }
        }

        // M7 件 C：subagent 装配（providers/物化器一次性 + 本会话父 loop 登记
        // + 工具面五件 + continuable 提示段）。sandboxOverride 供值缝 =
        // 父 knobs.sandbox 实时读（QA-3 P1-5）；modelSelection 随链透传
        // （QA-3 P1-6——子栈与父同路由）。
        // M7.3 件 H：工具面增 wait_agent（主理人判定①唯一新增）；装配段增
        // Supervisor 治理+持久化+恢复层（edge store/元数据读取/重挂物化三缝
        // + 根会话 Open 边恢复登记，见 setupSubagentRuntime）。
        await setupSubagentRuntime(parentSessionId: sessionId, parentLoop: agentLoop,
                                   writer: writer)
        SubagentTools.registerAll(into: registry, assembler: assembler,
                                  runtime: subagentRuntime, jobs: jobRegistry,
                                  writer: writer,
                                  parentLoop: agentLoop,
                                  modelSelection: modelSelection,
                                  sandboxOverride: { [permission] in
                                      permission.knobs.sandbox
                                  })

        // M7.4 件 K（F047/F048）：Workflow 引擎 + tool:workflow + tool:ralph
        // 装配。per-stack 引擎（dsh cordis 单例服务的万我 per-stack 承载——
        // 生命周期 listener 随会话栈闭合，addWorkflowListener 归档面 defer：
        // extensionEvent 冻结期不新增 kind，API 在场待启用，登记）。
        // 引擎缺省 config（provider 'spawn'/auto 并发/总帽 1000/片内 5s
        // Watchdog/宽限 5s——worker index.ts:31-49 缺省 1:1）。
        // QA-7 P2⑥（主理人裁决）：两工具收进 toolFilter gate（与 Team 工具
        // 族同处置——受限整合会话不装编排工具，防递归一致性：编排出的子栈
        // 再编排会绕过 toolFilter 收缩面）。gate 关闭 = 工具面登记跳过。
        if Self.toolFamilyAllowed(toolFilter,
                                  { WorkflowTool(engine: WorkflowEngine(
                                      runtime: subagentRuntime),
                                      parentWriter: writer) }) {
            let workflowEngine = WorkflowEngine(runtime: subagentRuntime)
            WorkflowTools.registerAll(into: registry, assembler: assembler,
                                      engine: workflowEngine, parentWriter: writer)
            RalphTools.registerAll(into: registry, assembler: assembler,
                                   engine: workflowEngine,
                                   runtime: subagentRuntime,
                                   parentWriter: writer)
        } else {
            Self.logger.info("workflow/ralph tools skipped: restricted session (toolFilter gate)")
        }

        // M5-A J3：完成纸条接线（dsh tool-jobs index.ts:278-299 的 owner 归一
        // 形态）。每会话一枚 listener：reported / owner nil → 跳过（dsh :279
        // 同语义）；本会话命中 → fitCompletionNotice 文本注入下一步收件箱
        // （AgentLoop.inject——dsh owner.inject 同 API，SessionStart 通道同款
        // await agentLoop?.inject）。busy/idle 分流与 wakeup 预算（dsh :293-297
        // followup + spentWakes）登记不实现：WanWo 单宿主恒注入形态
        // （派单裁定；TODO(wakeup-budget) 上游同注）。
        // 【真机批 B4 用户裁决】作业完成只走 inject（给 AI 的中间事件），
        // 不再弹系统通知（J4 作业级通知面删除）；系统通知改由"回合完成 +
        // App 不在前台"触发（callbacks.onTurnEnd 包装，见下）——验收模型：
        // 发任务 → 切走 → AI 做完 → 通知 → 切回。
        // 纸条文本带【系统通知】前缀（JobCompletionNotice）——投影层
        // markerPrefixes 按前缀隐藏（用户无感；AI 侧语义清晰）。
        jobNoticeDisposers.removeValue(forKey: sessionId)?()
        let noticeSessionId = sessionId
        jobNoticeDisposers[sessionId] = jobRegistry.onJobDone { [weak agentLoop] snapshot, owner in
            if snapshot.reported || owner == nil { return }
            let text = JobCompletionNotice.text(for: snapshot)
            if owner == noticeSessionId {
                Task { [weak agentLoop] in
                    await agentLoop?.inject(text)
                }
            }
        }

        // 真机批 B4：回合完成 → 用户验收提醒挂点（见 deps 构造前的
        // callbacks.onTurnEnd 包装——deps 须在构造前拿到包装版 callbacks）。


        // M4-E E5：SessionStart 挂点（CC index.ts:206-215 detached 火忘——
        // R5：不阻塞 stack 构建；慢 hook 可能错过首请求，dsh TODO(session-
        // start-gating) 同注）。source 取值（裁定③）：writer 已有事件=resume
        // 会话 → "resume"，零事件=新建 → "startup"（dsh session-start source
        // 语义的 WanWo 等价判定，零签名改动）。additionalContext → agent.
        // inject 通道（AgentLoop.inject:252——dsh agent.inject 同 API）。
        if let hookPoints {
            let source = writer.eventCount > 0 ? "resume" : "startup"
            Task { [weak agentLoop] in
                let merged = await hookPoints.sessionStart(source: source)
                for text in merged.additionalContext {
                    // AgentLoop 是 actor——inject 跨 actor 调用须 await。
                    await agentLoop?.inject(text)
                }
            }
        }

        return (agentLoop, nil, coordinator, questionService, permission,
                planMode, attachments)
    }

    // MARK: - Subagent 装配（M7 件 C · F045）

    /// providers/物化器一次性装配 + 本会话父 loop 登记（dsh ctx.subagents
    /// provider-added 与 activation 回传通道的进程内承载）。
    /// QA-3 P1-7：同会话栈重建前先 drain 旧驻留子（cancel + close 幂等）——
    /// 防父会话栈重建/关闭后驻留子孤儿化。
    /// M7.3 件 H：Supervisor 三缝注册（边表宿主 / 恢复元数据读取 / 重挂物化）
    /// + 根会话 Open 边恢复登记（惰性，不重挂不投递）。
    private func setupSubagentRuntime(parentSessionId: String,
                                      parentLoop: AgentLoop,
                                      writer: SessionWriter) async {
        await subagentRuntime.drainChildren(of: parentSessionId)
        if !subagentRuntimeWired {
            subagentRuntimeWired = true
            // P2-8：与 childMaterializer 同款 [weak self]——providers 闭包
            // 长期驻留 runtime，强捕获 self 形成 AppEnvironment↔SubagentRuntime
            // 持环（App 单例实际无害，QA 建议统一）。
            weak var weakEnvironment = self
            await subagentRuntime.registerProvider(SpawnInProcessProvider(
                name: "spawn",
                childFactory: { resolved, seed in
                    guard let environment = weakEnvironment else {
                        throw LLMError(message: "environment released", code: "UNKNOWN")
                    }
                    return try await environment.makeSubagentChildRun(resolved: resolved, seed: seed)
                }))
            await subagentRuntime.registerProvider(ForkInProcessProvider(
                name: "fork",
                childFactory: { resolved, seed in
                    guard let environment = weakEnvironment else {
                        throw LLMError(message: "environment released", code: "UNKNOWN")
                    }
                    return try await environment.makeSubagentChildRun(resolved: resolved, seed: seed)
                }))
            await subagentRuntime.registerChildMaterializer { [weak self] resolved, seed, onTurnEnd in
                guard let self else {
                    throw LLMError(message: "environment released", code: "UNKNOWN")
                }
                return try await self.makeSubagentChildStack(
                    resolved: resolved, seed: seed, onTurnEnd: onTurnEnd)
            }
            // M7.3 件 H：Supervisor 三缝（[weak self] 同纪律）。
            await subagentRuntime.registerEdgeStore(database)
            await subagentRuntime.registerChildMetadataReader { [weak self] childId in
                guard let self else {
                    throw LLMError(message: "environment released", code: "UNKNOWN")
                }
                return try await self.readSubagentChildMetadata(childId: childId)
            }
            await subagentRuntime.registerRecoveryMaterializer { [weak self] childId, onTurnEnd in
                guard let self else {
                    throw LLMError(message: "environment released", code: "UNKNOWN")
                }
                return try await self.remountSubagentChildStack(
                    childId: childId, onTurnEnd: onTurnEnd)
            }
        }
        await subagentRuntime.registerParentLoop(sessionId: parentSessionId, loop: parentLoop)
        // M7.3：崩溃恢复触发——仅根会话（子会话的恢复由其根在打开时统一承载；
        // codex restore_v2_agent_metadata 以 root_thread_id 调用同语义）。
        // Open 边 → 树元数据惰性登记（path/深度/label），不重挂不投递。
        if SubagentLineage.read(events: writer.events) == nil {
            await subagentRuntime.recoverOpenChildren(rootSessionId: parentSessionId)
        }
    }

    /// in-process provider 共用工厂（spawn/fork 同栈，种子差异在 provider 层
    /// ——SubagentInProcessDriver.startInProcessRun 1:1 入口）。
    private func makeSubagentChildRun(resolved: SubagentResolvedRequest,
                                      seed: [SessionEvent]?) async throws -> SubagentRun {
        try await SubagentInProcessDriver.startInProcessRun(request: resolved, seed: seed) {
            [weak self] resolved, seed in
            guard let self else {
                throw LLMError(message: "environment released", code: "UNKNOWN")
            }
            return try await self.makeSubagentChildStack(resolved: resolved, seed: seed,
                                                         onTurnEnd: { _ in })
        }
    }

    /// 子 agent 子栈物化（dsh agents.create 创建事务的 WanWo 承载）：建子会话
    /// （childId 即 SessionId 1:1）→ lineage + descriptor 事件 → 种子批量写
    /// （seq 从 0 连续；append 不发射实时 callbacks——派单缝要求天然满足）→
    /// makeAgentStack 全栈复用（dsh child = full agent）。
    private func makeSubagentChildStack(resolved: SubagentResolvedRequest,
                                        seed: [SessionEvent]?,
                                        onTurnEnd: @escaping @Sendable (TurnEndReason) -> Void)
        async throws -> (loop: AgentLoop, writer: SessionWriter) {
        let childId = resolved.childId
        do {
            _ = try await sessionStore.createSession(withID: childId,
                                                     cwd: resolved.request.parentCwd)
        } catch {
            throw SubagentError(message: "child session creation failed: "
                + "\(String(describing: error))", code: "SESSION_CREATE_FAILED")
        }
        let opened = try await sessionStore.openWriter(id: childId)
        let childWriter = opened.writer
        // lineage 事件（dsh childSessionMeta meta 的 extensionEvent 改案承载
        // ——SubagentTypes 头注登记；delegationDepth 持久权威由此 fold）。
        // M7.3 件 H：agentPath 随行持久化（resolved.agentPath 由 runtime
        // 分配——恢复树重建的 path 权威，codex stored_thread.agent_path 等价）。
        _ = try await childWriter.append(.extensionEvent(
            kind: SubagentLineage.eventKind,
            payload: SubagentLineage.payload(for: .init(
                parentSession: resolved.request.parentSessionId,
                delegationDepth: resolved.childDepth,
                seeded: seed?.isEmpty == false,
                agentPath: resolved.agentPath))))
        // descriptor 事件（创建窗口直写——dsh attachDescriptorAppend 为首个
        // pre-step 落盘，万我创建窗口先于首个 turn，登记）。
        _ = try await childWriter.append(.extensionEvent(
            kind: SubagentDescriptor.eventKind,
            payload: SubagentDescriptor.payload(for: resolved.descriptor)))
        // 种子批量写（fork 前缀逐 payload 追加；shape 复用既有事件；ignorable
        // 随行保真——assistantChunk 等非 model-visible 行不污染派生历史）。
        for event in seed ?? [] {
            _ = try await childWriter.append(event.payload, ignorable: event.ignorable)
        }
        // 全栈复用：子 = 完整 agent（dsh child-agent 同构）；模型选择随链
        // 透传（QA-3 P1-6——fork 前缀 KV-cache 同端点复用）+ 沙箱/审批承载
        // （QA-3 P1-5——子旋钮初始 (override, .never)）+ goal isTopLevel=false
        // + 纪律段注入（subagentDepth）。
        // M7 件 L：team 作用域判定（label 前缀承载——TeamConstants.
        // memberLabelPrefix；dsh durable roster 判定的万我创建窗口承载，登记：
        // descriptor/roster 此时尚未落子日志，前缀是创建窗口唯一可判定面）。
        let teamScope: TeamTools.ScopeContext?
        if let label = resolved.request.label,
           label.hasPrefix(TeamConstants.memberLabelPrefix) {
            teamScope = TeamTools.ScopeContext(
                role: .teammate,
                name: String(label.dropFirst(TeamConstants.memberLabelPrefix.count)),
                teamId: resolved.request.parentSessionId)
        } else {
            teamScope = nil
        }
        let stack = await makeAgentStack(
            sessionId: childId,
            writer: childWriter,
            callbacks: AgentLoop.Callbacks(onTurnEnd: onTurnEnd),
            interactionPresenter: nil,
            modelSelection: resolved.request.modelSelection,
            subagentDepth: resolved.childDepth,
            subagentSandboxOverride: resolved.request.sandboxModeOverride,
            teamScope: teamScope)
        guard let loop = stack.loop else {
            throw SubagentError(message: "child agent stack assembly failed: "
                + (stack.failureReason ?? "unknown"), code: "CHILD_STACK_FAILED")
        }
        return (loop, childWriter)
    }

    /// M7.3 件 H：恢复元数据读取（openWriter + 子日志 fold——lineage 持久权威
    /// + descriptor label；openWriter 幂等复用，重挂时同一 writer）。
    private func readSubagentChildMetadata(childId: String) async throws
        -> (lineage: SubagentLineage.Record, descriptor: SubagentDescriptor.Record?) {
        let opened = try await sessionStore.openWriter(id: childId)
        let events = opened.writer.events
        guard let lineage = SubagentLineage.read(events: events) else {
            throw SubagentError(
                message: "child session \(childId) has no subagent lineage record",
                code: "RECOVERY_METADATA_INVALID")
        }
        return (lineage, SubagentDescriptor.fold(events: events))
    }

    /// M7.3 件 H：恢复重挂物化（openWriter + makeAgentStack——子会话已存在，
    /// **不**重写 lineage/descriptor/种子；settle 回调同 startContinuable）。
    /// 登记适配：modelSelection 重挂传 nil——由子栈自身请求头 resume 解析
    /// （新建路径的父路由随链面仅存在于创建时）；subagentSandboxOverride 传
    /// nil 走子会话缺省解析 (defaults.sandbox, .never)——与新建一致。
    private func remountSubagentChildStack(
        childId: String,
        onTurnEnd: @escaping @Sendable (TurnEndReason) -> Void)
        async throws -> (loop: AgentLoop, writer: SessionWriter) {
        let opened = try await sessionStore.openWriter(id: childId)
        let childWriter = opened.writer
        // M7 件 L：恢复重挂的 team 作用域判定（descriptor label 前缀——与新建
        // 路径同语义；cold-resume teammate 栈续持 team 版工具面）。
        let remountDescriptor = SubagentDescriptor.fold(events: childWriter.events)
        let teamScope: TeamTools.ScopeContext? = remountDescriptor?.label.flatMap { label in
            guard label.hasPrefix(TeamConstants.memberLabelPrefix) else { return nil }
            return TeamTools.ScopeContext(
                role: .teammate,
                name: String(label.dropFirst(TeamConstants.memberLabelPrefix.count)),
                teamId: SubagentLineage.read(events: childWriter.events)?.parentSession
                    ?? childId)
        }
        let stack = await makeAgentStack(
            sessionId: childId,
            writer: childWriter,
            callbacks: AgentLoop.Callbacks(onTurnEnd: onTurnEnd),
            interactionPresenter: nil,
            modelSelection: nil,
            subagentDepth: SubagentLineage.read(events: childWriter.events)?.delegationDepth,
            subagentSandboxOverride: nil,
            teamScope: teamScope)
        guard let loop = stack.loop else {
            throw SubagentError(message: "child agent stack assembly failed: "
                + (stack.failureReason ?? "unknown"), code: "CHILD_STACK_FAILED")
        }
        return (loop, childWriter)
    }
}
