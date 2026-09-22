//
//  WorkspaceNavigator.swift
//  WanWo
//
//  【UI 对齐批 1 · A 会话创建流 workspace 驱动 · 新写】
//  语义源：dsh packages/client/ui-workspace/src/client/navigation.ts（1:1）：
//    · connectWorkspace :90-112——复用扫描四条件（①blank ②header cwd ===
//      workspace.path ③会话 id 在工作区账本内 ④未归档）+ 并发合并（connecting
//      map :96-97,109-110——同 workspaceId 的在飞连接共享同一 Task）；
//    · startSession :114-133——target = 显式 wsId ?? 当前会话所在工作区
//      （:117-120）?? recentWorkspace；无任何工作区 → 清空当前会话选择、
//      不创建（:125-128）——主区落到空态项目选择页（ConversationEmptyStateView）；
//    · watchNavigation :157-200——就绪后当前无选中会话 → 自动
//      connectWorkspace(recent) 并打开；clearArchivedCurrent :202-209；
//    · recentWorkspace :214-233——组内成员最新 updatedAt 最大者；空工作区用
//      createdAt；并列取 Host 工作区序先者。
//  blank 判定（简报 A.4）：事件流中无 turn/start（万我事件词汇）——轻量探测
//  （只读 header + 首事件窗口，禁止全量读流；probeLightweight 同思路），
//  结果按会话缓存（attach 侧随 sessionsRevision 失效）。
//  缝（Seams）全闭包注入——纯逻辑测试不触 AppEnvironment/GRDB/文件系统；
//  AppEnvironment 装配（attach(environment:)）只做订阅接线。
//

import Foundation
import Combine

/// 会话导航探针结果（dsh SessionSummary.blank + cwd 的 WanWo 轻量折算）。
struct SessionNavProbeResult: Equatable, Sendable {
    /// 事件流中无 turn/start（简报 A.4 blank 词汇；dsh summary.blank 同语义）。
    var isBlank: Bool
    /// header cwd（复用扫描条件②；创建时定格不可变）。
    var cwd: String?
}

/// blank/cwd 轻量探针（复用 SessionLogScanner 头行解析纪律；只读首窗口）。
enum SessionNavProbe {

    /// 首事件窗口字节数。窗口内出现 turn/start → 必非 blank；窗口读尽全文件
    /// 且无 turn/start → blank；文件超窗且窗口内无 turn/start → 保守判非
    /// blank（轻会话体量远小于窗口，误判面可忽略——不可抗力降级，报告登记）。
    static let windowBytes = 256 * 1024

    /// 探测一个会话文件：header cwd + 是否已出现 turn/start。
    /// 内存上界 O(256KB)（分块读 + 逐行解码，torn tail 忽略——scan 同语义）。
    static func probe(fileURL: URL) -> SessionNavProbeResult? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: windowBytes), !chunk.isEmpty else {
            return nil
        }
        guard let headerEnd = chunk.firstIndex(of: 0x0A) else { return nil }
        // 批10 修复：parseHeader(data:) 语义=「整段数据，内部自切头行」（无换行
        // 即抛 emptyOrHeaderless）——原实现传入已切好的头行（无换行）必然抛，
        // try? 吞掉后 probe 恒 nil → 复用扫描全部 continue → 每次点新会话都
        // 真实新建（真机实证：同项目连点两次=两条、重启再点=第三条）。改传
        // 完整 chunk 由 parseHeader 自切。
        guard let header = try? SessionLogScanner.parseHeader(data: chunk) else {
            return nil
        }
        var hasTurnStart = false
        var cursor = chunk.index(after: headerEnd)
        while let nl = chunk[cursor...].firstIndex(of: 0x0A) {
            let line = chunk.subdata(in: cursor..<nl)
            cursor = chunk.index(after: nl)
            if let event = try? JSONDecoder().decode(SessionEvent.self, from: line) {
                if case .turnStart = event.payload {
                    hasTurnStart = true
                    break
                }
            }
        }
        // read 返回量小于请求量 = 全文件已在窗口内（EOF）。
        let wholeFileRead = chunk.count < windowBytes
        let isBlank = !hasTurnStart && wholeFileRead
        return SessionNavProbeResult(isBlank: isBlank, cwd: header.cwd)
    }
}

/// 会话创建流导航器（dsh UiWorkspaceService 的 WanWo 本地对应；@MainActor，
/// 经 AppEnvironment 装配）。UI 消费面：侧栏「新会话」钮 / 空态页项目行 /
/// 组行 +，全部收口到 startSession(_:)。
@MainActor
final class WorkspaceNavigator: ObservableObject {

    /// 依赖缝（全闭包——测试注入桩，AppEnvironment 注入真身）。
    struct Seams {
        /// 工作区快照（Host 工作区序；dsh workspaces.list.getSnapshot().items）。
        var workspaces: () -> [WorkspaceRecord]
        /// 会话列表快照（dsh sessions.list.getSnapshot()）。
        var sessions: () -> [SessionSummary]
        /// 当前选中会话 id（dsh sessions.current；无选中 = nil）。
        var currentSessionID: () -> String?
        /// sessions.clear()——清空当前会话选择（不创建）。
        var clearSelection: () -> Void
        /// sessions.open(id)——选中该会话。
        var openSession: (String) -> Void
        /// 指定工作区建会话（createSession(cwd: ws.path) + attachSession——
        /// B3 既有注入链收口；dsh sessions.create({workspaceId}) 同语义）。
        var createSessionInWorkspace: (String) async -> SessionSummary?
        /// 归档集合（dsh archivedSessionIds）。
        var archivedSessionIDs: () -> Set<String>
        /// blank/cwd 轻量探针（按会话缓存由本类持有）。
        var probeSession: (String) -> SessionNavProbeResult?
        /// 列表就绪（dsh phase === 'ready'——WanWo 折算为首轮对账完成）。
        var isReady: () -> Bool

        /// 占位缝（两阶段初始化用）：AppEnvironment 先以 noops 创建本类
        /// 实例，init 尾再 bind 真缝——真缝闭包捕获 self 须待全部存储属性
        /// 完成阶段一（CI 35125985389 实证：Seams 闭包在 workspaceNavigator
        /// 自身初始化参数位捕获 self 被否；noops 挂 Seams 级供 `seams: .noops`
        /// 推断解析）。
        static let noops = Seams(
            workspaces: { [] },
            sessions: { [] },
            currentSessionID: { nil },
            clearSelection: {},
            openSession: { _ in },
            createSessionInWorkspace: { _ in nil },
            archivedSessionIDs: { [] },
            probeSession: { _ in nil },
            isReady: { false })
    }

    enum NavigatorError: Error, Equatable {
        case unknownWorkspace(String)
        case createFailed(String)
    }

    /// 可重绑（AppEnvironment init 尾以真缝替换 noops 占位——真缝闭包
    /// 捕获 self 须待全部存储属性就绪）。
    private var seams: Seams
    private let logger = AppLogger(category: "workspace-navigator")
    /// navigation.ts:96-97 connecting map——同 workspaceId 在飞连接共享。
    private var connecting: [String: Task<String, Error>] = [:]
    /// blank/cwd 探测缓存（简报 A.4「结果按会话缓存」；随 sessionsRevision 失效）。
    private var probeCache: [String: SessionNavProbeResult] = [:]
    /// watchNavigation initial 状态机（navigation.ts:158）。
    private enum NavigationPhase { case waiting, connecting, done }
    private var initialPhase: NavigationPhase = .waiting
    private var cancellables: Set<AnyCancellable> = []
    private var watchInstalled = false
    private var followCancel: (() -> Void)?

    init(seams: Seams) {
        self.seams = seams
    }

    /// 真缝替换（AppEnvironment init 尾调用——一次性；此后不再重绑）。
    func bind(seams: Seams) {
        self.seams = seams
    }

    // MARK: - connectWorkspace（navigation.ts:90-112）

    /// 解析一个工作区的可复用 blank 会话或新建会话，返回可寻址的会话 id。
    /// 复用扫描四条件全命中才复用；并发调用按 workspaceId 合并在飞 Task。
    func connectWorkspace(_ workspaceID: String) async throws -> String {
        guard let workspace = seams.workspaces().first(where: { $0.id == workspaceID }) else {
            throw NavigatorError.unknownWorkspace(workspaceID)
        }
        // 并发合并（:96-97）：在飞连接直接复用同一 Task。
        if let inflight = connecting[workspaceID] {
            return try await inflight.value
        }
        // 复用扫描（:99-106）：blank + header cwd === workspace.path + 在账本内
        // + 未归档，四条件全命中 → 原样返回该会话 id。
        let archived = seams.archivedSessionIDs()
        for summary in seams.sessions() {
            guard !archived.contains(summary.id),
                  workspace.sessionIds.contains(summary.id) else { continue }
            guard let probe = probeResult(for: summary.id) else { continue }
            guard probe.isBlank, probe.cwd == workspace.path else { continue }
            return summary.id
        }
        // 未命中 → createSession(cwd: ws.path) → attachSession（B3 既有链路，
        // 缝内收口；dsh sessions.create({workspaceId}) 同语义）。
        let attempt = Task<String, Error> { [seams] in
            guard let created = await seams.createSessionInWorkspace(workspaceID) else {
                throw NavigatorError.createFailed(workspaceID)
            }
            return created.id
        }
        connecting[workspaceID] = attempt
        defer { connecting.removeValue(forKey: workspaceID) }
        return try await attempt.value
    }

    // MARK: - startSession（navigation.ts:114-133）

    /// 发起新会话流并导航到其会话。target = 显式 wsId ?? 当前会话所在工作区 ??
    /// 最近活动工作区；无任何工作区 → 清空当前会话选择、不创建。
    func startSession(_ workspaceID: String? = nil) {
        let workspaces = seams.workspaces()
        let sessions = seams.sessions()
        // 当前会话所在工作区（:117-120）。
        let currentWorkspaceID = seams.currentSessionID().flatMap { currentID in
            workspaces.first(where: { $0.sessionIds.contains(currentID) })?.id
        }
        let recent = Self.recentWorkspace(workspaces, sessions: sessions)
        let target = workspaceID ?? currentWorkspaceID ?? recent
        guard let target else {
            // 无任何工作区 → sessions.clear()（:125-128）——主区停留空态
            // 项目选择页，绝不产生游离会话。
            seams.clearSelection()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let sessionID = try await self.connectWorkspace(target)
                self.seams.openSession(sessionID)
            } catch {
                self.logger.warning("new session failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - recentWorkspace（navigation.ts:214-233）

    /// 最近活动工作区：组内成员最新 updatedAt 最大者；空工作区（或成员不在
    /// 列表快照内）用 createdAt 回退；并列取 Host 工作区序先者（稳定排序）。
    nonisolated static func recentWorkspace(_ workspaces: [WorkspaceRecord],
                                            sessions: [SessionSummary]) -> String? {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var selected: String?
        var selectedTime = Date.distantPast
        for workspace in workspaces {
            var latest: Date?
            for sessionID in workspace.sessionIds {
                if let session = byID[sessionID] {
                    latest = max(latest ?? .distantPast, session.updatedAt)
                }
            }
            let time = latest ?? workspace.createdAt
            if selected == nil || time > selectedTime {
                selected = workspace.id
                selectedTime = time
            }
        }
        return selected
    }

    // MARK: - watchNavigation（navigation.ts:157-200）

    /// 启动语义的一步对账（订阅回调驱动）：先跑 clearArchivedCurrent；就绪后
    /// 当前无选中会话 → 自动 connectWorkspace(recent) 并打开。
    func reconcileNavigation() {
        // clearArchivedCurrent（:202-209）：当前选中被归档 → 清空选择。
        if let current = seams.currentSessionID(),
           seams.archivedSessionIDs().contains(current) {
            seams.clearSelection()
        }
        guard initialPhase == .waiting else { return }
        guard seams.isReady() else { return }
        guard let target = Self.recentWorkspace(seams.workspaces(),
                                                sessions: seams.sessions()) else {
            // 无任何工作区：主区停留空态项目选择页（dsh :172-174 initial='done'
            // ——之后由添加工作区流显式 startSession，不再自动连接）。
            initialPhase = .done
            return
        }
        initialPhase = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                let sessionID = try await self.connectWorkspace(target)
                if self.seams.currentSessionID() == nil {
                    self.seams.openSession(sessionID)
                }
                self.initialPhase = .done
            } catch {
                // 失败回 waiting（:185-189）——下次对账重试。
                self.initialPhase = .waiting
                self.logger.warning("initial workspace selection failed: \(String(describing: error))")
            }
        }
    }

    /// AppEnvironment 装配：订阅会话列表版本 + 工作区 follow 快照流，驱动
    /// reconcileNavigation（dsh 双 subscribe(reconcile) 的 WanWo 折算）。
    func attach(environment: AppEnvironment) {
        guard !watchInstalled else { return }
        watchInstalled = true
        environment.$sessionsRevision
            .sink { [weak self] _ in
                // 会话内容可能变化——blank/cwd 探测缓存整体失效（保守正确）。
                self?.probeCache.removeAll()
                self?.reconcileNavigation()
            }
            .store(in: &cancellables)
        let (stream, cancel) = environment.workspaceController.follow()
        followCancel = cancel
        Task { @MainActor [weak self] in
            for await _ in stream {
                self?.reconcileNavigation()
            }
        }
        reconcileNavigation()
    }

    // MARK: - 内部

    /// 探测结果按会话缓存（简报 A.4）。
    private func probeResult(for sessionID: String) -> SessionNavProbeResult? {
        if let cached = probeCache[sessionID] { return cached }
        guard let fresh = seams.probeSession(sessionID) else { return nil }
        probeCache[sessionID] = fresh
        return fresh
    }
}

// MARK: - 添加工作区共享流（【工作区模型修正】——空态页与侧栏共用）

/// 「输入名字就是添加工作区的全部」：在 iSH fakefs 持久层建真实项目目录
/// /var/wanwo/projects/<名字>（建目录 + meta.db 注册，幂等）→ 注册工作区
/// （registry.create 幂等）→ 返回新工作区。完全脱离 MountedFoldersManager
/// ——项目目录直接落在 iSH fakefs 内，shell/文件工具原生可见，无需翻译。
enum WorkspaceAdoption {

    enum AddError: Error, LocalizedError, Equatable {
        /// 名字清洗后为空 / 为 "." / ".."（目录名安全闭集）。
        case invalidName
        /// rootfs 尚未安装（fakefs 持久层不存在）——首启安装完成前拒绝
        /// 建项目（防 installIfNeeded 的整树重建把项目目录连带清除）。
        case rootfsNotReady

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "项目名无效：请输入非空名字（中文、字母、数字、-、_、. 之外"
                    + "的字符会自动替换为 -）。"
            case .rootfsNotReady:
                return "系统初始化中，请稍候片刻再创建项目。"
            }
        }
    }

    /// 目录名字符闭集：中文/字母/数字/-/_/.（挂载名 isValidMountName 的
    /// 中文扩展版——其余字符一律替换为 -）。
    private static func isNameCharacter(_ ch: Character) -> Bool {
        return ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "."
    }

    /// 名字清洗：去首尾空白 → 逐字符过滤（闭集外替换 -）。清洗后为空 /
    /// "." / ".." / 无任何实质字符（字母/数字/中文——即纯 "- . " 占位组合，
    /// 如 "///"→"---"）→ nil（调用方抛 AddError.invalidName，让用户重输
    /// 而非默默建无意义目录；WorkspaceAdoptionTests 矩阵语义）。
    nonisolated static func sanitizeName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(trimmed.map { isNameCharacter($0) ? $0 : "-" })
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..",
              cleaned.contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        return cleaned
    }

    /// 清洗后名字 → guest 项目目录路径。
    nonisolated static func guestPath(for cleanedName: String) -> String {
        return WanWoPaths.projectsLinuxDir + "/" + cleanedName
    }

    /// 在 iSH fakefs 持久层建真实项目目录（幂等）：
    ///   1. 宿主侧 dataPath/var/wanwo/projects/<名字> 建目录（fakefs 数据真身；
    ///      已存在 → 幂等复用）；
    ///   2. meta.db 注册 /var/wanwo、/var/wanwo/projects、/var/wanwo/projects/
    ///      <名字> 三级目录 inode（fakefs 元数据；已注册 → 幂等跳过；kernel
    ///      未 boot 时静默跳过——boot 后 performMount 按项目快照兜底补齐）。
    /// 此后 shell（fakefs 原生路径）与 Swift 文件工具（dataPath 宿主直读）
    /// 看到同一份真实目录。
    nonisolated static func ensureProjectDirectory(cleanedName: String) throws {
        // rootfs 未安装（data 根 + .arch 标签缺失）→ 拒绝：installIfNeeded 的
        // 整树重建会连带清掉此刻建的项目目录（fail closed，报告登记）。
        guard RootfsInstaller.shared.isInstalled else {
            throw AddError.rootfsNotReady
        }
        let guestPath = Self.guestPath(for: cleanedName)
        guard let hostRoot = WanWoPaths.projectsHostRoot(forGuestPath: guestPath) else {
            throw AddError.invalidName
        }
        try FileManager.default.createDirectory(
            at: hostRoot, withIntermediateDirectories: true)
        // fakefs 元数据逐级注册（先父链后本目录；幂等）。
        IshExecutorBridge.ensureParentDirsInMetaDB(for: guestPath)
        IshExecutorBridge.ensureFakefsMetadata(for: guestPath, isDirectory: true)
    }

    /// 注册一个项目目录为工作区（不导航——调用方随后 startSession(ws.id)，
    /// 简报 B.4 终点语义）。目录已存在 → 幂等复用（registry.create 幂等）。
    @MainActor
    static func adopt(name: String, environment: AppEnvironment) throws -> WorkspaceRecord {
        // title = 用户输入原名（trim 后；清洗名只落目录，展示名保真）。
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned = sanitizeName(name) else {
            throw AddError.invalidName
        }
        try ensureProjectDirectory(cleanedName: cleaned)
        // dsh「选择目录就是添加工作区的全部」：create（幂等，既有路径原样返回）。
        let (workspace, _) = try environment.workspaceController.create(
            path: guestPath(for: cleaned), title: title)
        // 项目目录快照推送（boot 后 performMount 兜底补注册 meta.db 用）。
        pushProjectDirectories(environment: environment)
        environment.selectedWorkspaceID = workspace.id
        return workspace
    }

    /// 以 registry 快照（projects 前缀过滤）推送项目目录全量快照。
    @MainActor
    static func pushProjectDirectories(environment: AppEnvironment) {
        let dirs = environment.workspaceRegistry.list()
            .map(\.path)
            .filter { WanWoPaths.isProjectsGuestPath($0) && $0 != WanWoPaths.projectsLinuxDir }
        IshExecutorBridge.setProjectDirectories(dirs)
    }
}
