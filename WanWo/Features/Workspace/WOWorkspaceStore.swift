//
//  WOWorkspaceStore.swift
//  WanWo
//
//  【批12+右栏重构批1（2026-09-27 用户拍板）· 语义源 cc-haha desktop/src/
//   stores/workspaceStore.ts + lib/workspace/types.ts + lib/workspace/
//   openTarget.ts（逐锚点对照，勘察呈报 2026-09-27 06:0x 版）】
//  右栏工作台状态机（cc-haha 三层分离语义的万我 Swift 形态）：
//    ① 布局/导航层 = 本 store（UI 页签 id）
//    ② 内容数据层  = 各页签内容组件自管（本次不动）
//    ③ 活资源层    = 页签内容组件持有（BrowserTabPool/终端 shell，随视图卸载
//                    释放；本 store 经 tabReleaseHandler 钩子补通知）
//  纪律：UI 页签 id 与资源 id 永不混用（cc-haha types.ts:1-17 头注原文：
//  "把两者混用正是上一版实现切面板就杀页面的原因"）。
//  按会话作用域（bySession）：页签/布局各会话独立，切会话不清理、关任务级
//  清理（cc-haha clearSession 同款；万我当前单前台会话形态下即"串区根治"）。
//  降级登记（cc-haha 有、批1 不移植，均为桌面/多任务概念）：
//    · WorkspaceFocusRequest（键盘焦点 nonce）、WorkspaceOrigin（对话滚回）、
//      bottom dock（底部终端坞）、preview 槽位（触屏无双击语义，枚举位已留）、
//      findBrowserTabOwner（无全局 host 事件桥）、pruneTurnReviewTabs（批2
//      引入 turn review 时补）。
//  用户裁决覆盖登记：AI 浏览器=单活动页签跟随（agentBrowserTabID，cc-haha
//  browser 恒不复用之上万我特例）；✕ 关闭 Toast 撤销（undo 入口方式 B）；
//  切会话右栏收起（离开会话 layout 归 hidden，页签资源保活）。
//

import Foundation
import SwiftUI

// MARK: - 布局三态（cc-haha WorkspaceLayout types.ts:28）

/// 右栏呈现：hidden=整列收起（页签与活资源全部保活，只是不渲染）；
/// split=对话+右栏分栏；full=右栏占满（对话列让位，左栏折叠——万我批12+
/// 回归的 100% 全屏语义）。
enum WOWorkspaceLayout: String, Equatable {
    case hidden
    case split
    case full
}

// MARK: - 页签模型（cc-haha WorkspaceTabBase + 万我 kind 词汇）

/// 页签种类。单例 kind（terminal/review/sideChat/trajectory/files）重复打开 =
/// 激活既有；browser 多实例（cc-haha browser 不复用语义）。
enum WorkspaceTabKind: String, Equatable, CaseIterable {
    case files
    case terminal
    case browser
    case sideChat
    case review
    /// 【批2 2C】轨迹页签（dsh ui-trajectory 台账版）。
    case trajectory

    var title: String {
        switch self {
        case .files: return "文件"
        case .terminal: return "终端"
        case .browser: return "浏览器"
        case .sideChat: return "侧边聊天"
        case .review: return "审查"
        case .trajectory: return "轨迹"
        }
    }

    var iconName: String {
        switch self {
        case .files: return "doc.text"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .sideChat: return "bubble.left.and.bubble.right"
        case .review: return "plus.slash.minus"
        case .trajectory: return "list.bullet.rectangle"
        }
    }
}

/// 一枚工作台页签（cc-haha WorkspaceTabBase 万我形态：UI 身份 + kind +
/// 资源载荷；UI id 与资源 id 分列——browserTabId 即资源身份）。
struct WorkspaceTab: Identifiable, Equatable {
    /// UI 身份（会话内唯一；资源 id 见 browserTabId——永不互相代替）。
    let id: String
    let kind: WorkspaceTabKind
    /// cc-haha preview 槽位语义占位（iOS 触屏暂不启用；结构位保留）。
    var preview: Bool
    var createdAt: Date
    /// browser：最近导航 URL（nil = 空白新签；打开即导航同字段消费）。
    var url: URL?
    /// browser：页标题（视图回写，页签条显示真实标题）。
    var title: String?
    var loadError: String?

    /// 单例页签（id = kind rawValue——重复打开即激活既有）。
    static func singleton(_ kind: WorkspaceTabKind) -> WorkspaceTab {
        WorkspaceTab(id: kind.rawValue, kind: kind, preview: false,
                     createdAt: Date(), url: nil, title: nil, loadError: nil)
    }

    /// 浏览器页签（多实例；url = 打开即导航目标/最近落点）。
    static func browser(initialURL: URL? = nil) -> WorkspaceTab {
        WorkspaceTab(id: "browser-" + UUID().uuidString, kind: .browser,
                     preview: false, createdAt: Date(), url: initialURL,
                     title: nil, loadError: nil)
    }
}

// MARK: - 打开请求（cc-haha WorkspaceTarget/WorkspaceOpenOptions 万我形态）

/// 打开目标（openRouter 的入参词汇）。
enum WOWorkspaceOpenTarget: Equatable {
    /// 单例页签（terminal/review/sideChat/trajectory/files）。
    case singleton(WorkspaceTabKind)
    /// 浏览器（多实例；url = 打开即导航）。
    case browser(url: URL?)
}

struct WOWorkspaceOpenOptions {
    /// cc-haha types.ts:179：后台打开——落对应会话的右栏但**永不抢前台焦点**
    /// （agent 驱动的打开默认 true；用户明确点击=false）。
    var background: Bool = false
    /// cc-haha types.ts:188：请求来源（语义标注；批1 万我单前台形态下与
    /// background 联动）。
    var requestedBy: WOWorkspaceOpenRequester = .user
    /// 打开即激活（cc-haha activate；background=false 时恒 true）。
    var activate: Bool = true

    enum WOWorkspaceOpenRequester: String { case user, agent }
}

// MARK: - 会话作用域状态（cc-haha WorkspaceSessionState :67-78）

struct WOWorkspaceSessionState: Equatable {
    var layout: WOWorkspaceLayout = .hidden
    var tabs: [WorkspaceTab] = []
    var activeTabID: String?
    /// undo 关闭栈（cc-haha UNDO_STACK_LIMIT=12；按"动作"整组入栈）。
    var closed: [[WorkspaceTab]] = []
    /// 浏览器页签序号（标题用）。
    var nextBrowserOrdinal = 1
    /// AI 专用浏览器页签（用户裁决"单活动页签跟随"；✕ 清零）。
    var agentBrowserTabID: String?

    static let empty = WOWorkspaceSessionState()
}

/// undo 关闭上限（cc-haha UNDO_STACK_LIMIT 同值）。
private let wowUndoStackLimit = 12
/// 单 dock 页签上限（cc-haha MAX_TABS_PER_DOCK=60 的防循环开签纪律；万我
/// 触屏沿用既有 8——容量护栏非交互语义，数值维持用户已验收现状）。
private let wowMaxTabsPerDock = 8

// MARK: - 状态机（cc-haha workspaceStore 万我形态；模块单例——cc-haha 的
// zustand create() 导出即模块单例，Swift 形态 = static shared）

@MainActor
final class WOWorkspaceStore: ObservableObject {

    static let shared = WOWorkspaceStore()

    /// 侧栏展开宽度（万我裁决：触屏固定 400，拖拽退役——clamp 逻辑保留）。
    static let sideWidth: CGFloat = 380

    @Published private(set) var bySession: [String: WOWorkspaceSessionState] = [:]
    /// 「审查」入口可见性（git 仓库项目；万我会话级单值——随 selection 刷新）。
    @Published private(set) var reviewAvailable = false
    /// AI 最近一次浏览器导航（轻提示数据源；WOLightHint 消费——同域 10s 节流
    /// 由消费侧持有，store 只广播事实）。
    @Published private(set) var agentNavigation: (url: URL, domain: String, at: Date)?
    /// 最近一次页签关闭（undo Toast 数据源；token=防同文重复触发）。
    @Published private(set) var lastClosedUndo: (sessionId: String, title: String, token: UUID)?

    /// 【批2 文件页签自动刷新 2026-09-27】会话文件活动纪元（AI 工具结果/回合
    /// 边界驱动——cc-haha useWorkspaceFileWatch 的万我等价触发源：iOS fakefs
    /// 无 inotify，动作驱动替代 fs 事件；cc-haha 120ms 合并窗口由本节流承担）。
    /// WorkspaceFileTabView onChange 本会话纪元 → 重载树 + 变更高亮。
    @Published private(set) var fileChangeEpoch: [String: Int] = [:]
    /// 节流位（同会话 0.8s 内的连续工具结果合并为一次刷新信号）。
    private var lastFileActivityAt: [String: Date] = [:]

    /// AI 会话文件活动上报（ChatViewModel onToolCallFinished/onTurnEnd 调）。
    func noteFileActivity(sessionID: String) {
        let now = Date()
        if let last = lastFileActivityAt[sessionID],
           now.timeIntervalSince(last) < 0.8 { return }
        lastFileActivityAt[sessionID] = now
        fileChangeEpoch[sessionID, default: 0] += 1
    }

    /// 【批2 高亮】回合变更文件集（per-session；turn/end 变更卡同源写入，
    /// 页签刷新时读取渲染、下次刷新覆盖/清除）。
    @Published private(set) var changeHighlight: [String: Set<String>] = [:]

    /// 写入本回合变更文件集并 bump 纪元（ChatViewModel onTurnEnd 调）。
    func noteFileChanges(sessionID: String, paths: Set<String>) {
        changeHighlight[sessionID] = paths
        lastFileActivityAt[sessionID] = .distantPast  // 变更落卡必刷新（绕过节流）
        fileChangeEpoch[sessionID, default: 0] += 1
    }

    /// 【批3 右栏→AI 引用挂载（cc-haha 链③ file 级）】右栏发起的 composer
    /// 插入请求（文件页签「引用」钮/树行菜单 → composer 追加 `@path` 令牌；
    /// 注入端=F040 expandFileReferences 既有语义，dsh file-reference 同款）。
    /// WOChatView onReceive 消费后置 nil；at=防同 token 重复消费。
    struct ComposerInsert: Equatable {
        let sessionID: String
        let token: String
        let at: Date
    }
    @Published var pendingComposerInsert: ComposerInsert?

    /// 右栏侧发起插入（页签/树行调；token 形如 `@path`）。
    func requestComposerInsert(sessionID: String, token: String) {
        pendingComposerInsert = ComposerInsert(
            sessionID: sessionID, token: token, at: Date())
    }

    /// 撤销条生命周期收口（Toast onDone 调；token 不匹配=已被新关闭顶替，不清）。
    func dismissUndoToast(token: UUID) {
        if lastClosedUndo?.token == token { lastClosedUndo = nil }
    }

    /// 页签资源释放钩子（真删通知——浏览器页面/终端 shell 的宿主侧回收；
    /// 视图卸载自身也会释放，此钩子为显式兜底）。
    var tabReleaseHandler: ((WorkspaceTab) -> Void)?

    private var idCounter = 0
    private func nextId(_ prefix: String) -> String {
        idCounter += 1
        return "\(prefix)-\(String(idCounter, radix: 36))-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
    }

    // MARK: 读取

    func state(for sessionId: String) -> WOWorkspaceSessionState {
        bySession[sessionId] ?? .empty
    }

    func tabs(for sessionId: String) -> [WorkspaceTab] {
        state(for: sessionId).tabs
    }

    func layout(for sessionId: String) -> WOWorkspaceLayout {
        state(for: sessionId).layout
    }

    func activeTab(for sessionId: String) -> WorkspaceTab? {
        let s = state(for: sessionId)
        return s.tabs.first { $0.id == s.activeTabID }
    }

    func canReopenClosed(for sessionId: String) -> Bool {
        !(state(for: sessionId).closed.isEmpty)
    }

    // MARK: 布局三态（cc-haha setLayout/toggleWorkspace/toggleFullscreen :375-409）

    func setLayout(_ layout: WOWorkspaceLayout, sessionId: String) {
        var s = state(for: sessionId)
        guard s.layout != layout else { return }
        s.layout = layout
        bySession[sessionId] = s
    }

    /// 顶栏开关钮：hidden↔split（full 不经由 toggle——"toggle 不许吞掉对话"，
    /// cc-haha :388-392 原注释语义）。
    func toggleWorkspace(sessionId: String) {
        var s = state(for: sessionId)
        s.layout = (s.layout == .hidden) ? .split : .hidden
        bySession[sessionId] = s
    }

    /// 右栏放大/收缩钮：split↔full（呈现变化——不建签、不重载、不重启 shell，
    /// cc-haha :396-409 原注释语义）。
    func toggleFullscreen(sessionId: String) {
        var s = state(for: sessionId)
        s.layout = (s.layout == .full) ? .split : .full
        bySession[sessionId] = s
    }

    // MARK: 打开（cc-haha openTarget :450-638 万我映射）

    /// 统一打开落点。复用规则：单例 kind 激活既有；browser 恒新建（除非命中
    /// AI 专用页签——见 openAgentBrowser）；容量满激活尾签不崩（既有裁决语义）。
    /// 新建 side 签隐式展开（layout hidden → split，insertTab :332 语义）。
    @discardableResult
    func openTarget(sessionId: String,
                    target: WOWorkspaceOpenTarget,
                    options: WOWorkspaceOpenOptions = .init()) -> String? {
        var s = state(for: sessionId)
        let activate = options.activate && !options.background

        // —— 复用：单例 kind（cc-haha file/review/terminal reuse 同段语义）——
        if case .singleton(let kind) = target,
           let existing = s.tabs.first(where: { $0.kind == kind }) {
            if activate {
                s.activeTabID = existing.id
                if s.layout == .hidden { s.layout = .split }
            }
            bySession[sessionId] = s
            return existing.id
        }

        // —— 容量护栏（满则激活尾签，不崩可解释——既有裁决语义保留）——
        guard s.tabs.count < wowMaxTabsPerDock else {
            s.activeTabID = s.tabs.last?.id
            bySession[sessionId] = s
            return s.activeTabID
        }

        // —— 新建 ——
        let tab: WorkspaceTab
        switch target {
        case .singleton(let kind):
            tab = .singleton(kind)
        case .browser(let url):
            tab = .browser(initialURL: url)
        }
        s.tabs.append(tab)
        if activate || s.activeTabID == nil {
            s.activeTabID = tab.id
        }
        if s.layout == .hidden { s.layout = .split }
        bySession[sessionId] = s
        return tab.id
    }

    // MARK: 激活（cc-haha activateTab :640-656）

    func activateTab(sessionId: String, tabId: String) {
        var s = state(for: sessionId)
        guard s.tabs.contains(where: { $0.id == tabId }) else { return }
        guard s.activeTabID != tabId else { return }
        s.activeTabID = tabId
        bySession[sessionId] = s
    }

    // MARK: 关闭（cc-haha closeTabs :684-720 + releaseTabResources :204-222）

    enum CloseScope { case current, others, left, right, all }

    /// 关闭页签：真删 + 邻位激活（右邻优先回退左邻——cc-haha
    /// nextActiveAfterClose :231-252）+ 关空隐式收起（:292-297）+ undo 入栈。
    func closeTabs(sessionId: String, tabId: String, scope: CloseScope = .current) {
        var s = state(for: sessionId)
        guard let index = s.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let dockTabs = s.tabs
        let doomed: [WorkspaceTab]
        switch scope {
        case .current: doomed = [dockTabs[index]]
        case .others:  doomed = dockTabs.filter { $0.id != tabId }
        case .left:    doomed = Array(dockTabs[..<index])
        case .right:   doomed = Array(dockTabs[(index + 1)...])
        case .all:     doomed = dockTabs
        }
        guard !doomed.isEmpty else { return }

        // 资源释放钩子（真删通知；browser 页签宿主侧回收通道）。
        for tab in doomed { tabReleaseHandler?(tab) }

        // undo 入栈（按动作整组；保被删签在原数组中的位次供恢复定位）。
        let group = doomed.map { tab -> (tab: WorkspaceTab, index: Int) in
            (tab, s.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0)
        }
        s.closed.append(group.map { $0.tab })
        if s.closed.count > wowUndoStackLimit { s.closed.removeFirst(s.closed.count - wowUndoStackLimit) }

        let removedIDs = Set(doomed.map(\.id))
        s.tabs.removeAll { removedIDs.contains($0.id) }

        // AI 专用页签被删 → 旗标清零（防悬挂 id，既有裁决语义）。
        if let agentID = s.agentBrowserTabID, removedIDs.contains(agentID) {
            s.agentBrowserTabID = nil
        }

        // 激活落点：被关集合含活动签 → 右邻→左邻（remaining 上取——旧实现
        // 终验修同款教训）；否则不变。
        if let current = s.activeTabID, removedIDs.contains(current) {
            let next = dockTabs[(index + 1)...].first { !removedIDs.contains($0.id) }
            let previous = dockTabs[..<index].reversed().first { !removedIDs.contains($0.id) }
            s.activeTabID = (next ?? previous)?.id
        }

        // 关空 → 该会话右栏收起（cc-haha :296-297：关最后一签=空态合法）。
        if s.tabs.isEmpty { s.layout = .hidden }

        // undo Toast 数据源（方式 B：关闭即飘「已关闭 X · 撤销」）。
        if let first = doomed.first {
            lastClosedUndo = (sessionId, undoTitle(for: first), UUID())
        }
        bySession[sessionId] = s
    }

    private func undoTitle(for tab: WorkspaceTab) -> String {
        if tab.kind == .browser, let host = tab.url?.host, !host.isEmpty {
            return "浏览器（\(host)）"
        }
        return tab.kind.title
    }

    // MARK: undo（cc-haha reopenClosedTab :785-856）

    /// 恢复最近一次关闭的页签组。恢复纪律（cc-haha 原注释语义）：终端恢复 =
    /// 全新 shell（绝不重放旧命令）；browser 恢复 = 新资源 id（url 保留）。
    @discardableResult
    func reopenLastClosed(sessionId: String) -> String? {
        var s = state(for: sessionId)
        guard let group = s.closed.last else { return nil }
        s.closed.removeLast()

        var restoredID: String?
        for closedTab in group {
            // 单例页签若已被重新打开 → 激活既有（cc-haha :801-813 同款）。
            if closedTab.kind != .browser,
               let existing = s.tabs.first(where: { $0.kind == closedTab.kind }) {
                s.activeTabID = existing.id
                restoredID = existing.id
                continue
            }
            var tab = closedTab
            if tab.kind == .browser {
                tab = WorkspaceTab(id: "browser-" + UUID().uuidString, kind: .browser,
                                   preview: false, createdAt: Date(), url: tab.url,
                                   title: tab.title, loadError: nil)
            }
            if s.tabs.count < wowMaxTabsPerDock {
                s.tabs.append(tab)
                s.activeTabID = tab.id
                restoredID = tab.id
            }
        }
        if restoredID != nil, s.layout == .hidden { s.layout = .split }
        bySession[sessionId] = s
        return restoredID
    }

    // MARK: AI 浏览器（用户裁决"单活动页签跟随"；cc-haha agent 语义 = 统一
    // 入口 + background 不抢焦点——openTarget.ts :19-46 注释原文）

    /// AI 导航落点。openSidebar（用户明确要求/截图）= 激活+展开；
    /// false（AI 自主干活）= 已有 AI 页签则静默跟随，无则不打扰（轻提示由
    /// 聊天层消费 agentNavigation 呈现）。
    func openAgentBrowser(sessionId: String, url: URL, openSidebar: Bool) {
        var s = state(for: sessionId)

        // 轻提示事实源（无论是否展开，聊天层自行节流呈现）。
        let domain = url.host ?? url.absoluteString
        agentNavigation = (url, domain, Date())

        if let id = s.agentBrowserTabID,
           let idx = s.tabs.firstIndex(where: { $0.id == id && $0.kind == .browser }) {
            s.tabs[idx].url = url
            if openSidebar {
                s.activeTabID = id
                if s.layout == .hidden { s.layout = .split }
            }
            bySession[sessionId] = s
            return
        }
        guard openSidebar, s.tabs.count < wowMaxTabsPerDock else {
            bySession[sessionId] = s
            return
        }
        let tab = WorkspaceTab.browser(initialURL: url)
        s.tabs.append(tab)
        s.agentBrowserTabID = tab.id
        s.activeTabID = tab.id
        if s.layout == .hidden { s.layout = .split }
        bySession[sessionId] = s
    }

    // MARK: 浏览器回写（cc-haha updateBrowserTab :858-877）

    /// 页签视图回写导航事实（页签条显示真实标题/落点；晚到事件不复活已删签）。
    func updateBrowserTab(sessionId: String, tabId: String,
                          url: URL? = nil, title: String? = nil, loadError: String? = nil) {
        var s = state(for: sessionId)
        guard let idx = s.tabs.firstIndex(where: { $0.id == tabId && $0.kind == .browser }) else { return }
        if let url { s.tabs[idx].url = url }
        if let title { s.tabs[idx].title = title }
        if let loadError { s.tabs[idx].loadError = loadError }
        bySession[sessionId] = s
    }

    // MARK: 审查入口门 + 无会话收口

    /// 会话切换刷新「审查」入口（git 仓库项目；宿主根跟随工作区路径——
    /// 批12+工作区贯穿语义，迁移自旧模型 updateReviewAvailability）。
    func updateReviewAvailability(sessionId: String?, workspacePath: String?) {
        guard let sessionId else {
            if reviewAvailable { reviewAvailable = false }
            return
        }
        let workspaceHost: URL
        if let workspacePath,
           let projectHost = WanWoPaths.projectsHostRoot(forGuestPath: workspacePath) {
            workspaceHost = projectHost
        } else {
            workspaceHost = WanWoPaths.sessionPersistentDir(for: sessionId, bucket: "workspace")
        }
        var isDir: ObjCBool = false
        let gitDir = workspaceHost.appendingPathComponent(".git", isDirectory: true)
        let available = FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir)
            && isDir.boolValue
        if available != reviewAvailable { reviewAvailable = available }
        // 入口条件消失：关审查页签（激活落点走状态机）。
        if !available {
            let s = state(for: sessionId)
            if let activeID = s.activeTabID,
               let activeTab = s.tabs.first(where: { $0.id == activeID }),
               activeTab.kind == .review {
                closeTabs(sessionId: sessionId, tabId: WorkspaceTabKind.review.rawValue)
            }
        }
    }

    /// 无会话强制收起（codex 截图 #3：右栏只在会话场景可用——旧模型
    /// reconcileForSelection 语义迁移）。
    func reconcileForNoSession() {
        for (sessionId, var s) in bySession where s.layout != .hidden {
            s.layout = .hidden
            bySession[sessionId] = s
        }
    }

    /// 会话切换收口（用户裁决"切换即收起"）：离开的会话 layout 归 hidden
    ///（页签资源保活，切回手动展开即见）。
    func collapseForSessionSwitch(from departingSessionId: String?) {
        guard let departingSessionId, state(for: departingSessionId).layout != .hidden else { return }
        setLayout(.hidden, sessionId: departingSessionId)
    }

    /// 任务级清理（cc-haha clearSession :946-955：关任务=唯一全释放点）。
    func clearSession(sessionId: String) {
        guard var s = bySession[sessionId] else { return }
        for tab in s.tabs { tabReleaseHandler?(tab) }
        s = .empty
        bySession[sessionId] = s
    }

    // MARK: 「+」菜单候选（旧模型 candidateKinds 语义迁移）

    func candidateKinds() -> [WorkspaceTabKind] {
        var kinds: [WorkspaceTabKind] = []
        if reviewAvailable { kinds.append(.review) }
        kinds.append(contentsOf: [.files, .sideChat, .browser, .terminal, .trajectory])
        return kinds
    }
}

// MARK: - 统一打开入口（cc-haha openTarget.ts :19-46 万我形态）

/// 全 App 唯一打开通道——深链、AI 联动、页签菜单、轻提示点击全部经此
///（cc-haha 原注释："Buttons, keyboard shortcuts, chat file links,
/// turn-change cards, 'Open with', preview link routing and agent-driven
/// opens all come through here"——激活/预览/任务归属规则一处集中）。
@MainActor
enum WOWorkspaceOpenRouter {

    struct Request {
        let sessionId: String
        let target: WOWorkspaceOpenTarget
        var options: WOWorkspaceOpenOptions = .init()
    }

    @discardableResult
    static func open(_ request: Request) -> String? {
        WOWorkspaceStore.shared.openTarget(sessionId: request.sessionId,
                                           target: request.target,
                                           options: request.options)
    }

    /// 便捷包装（cc-haha workspaceOpen 同位）。
    static func browser(sessionId: String, url: URL?,
                        requestedBy: WOWorkspaceOpenOptions.WOWorkspaceOpenRequester = .user,
                        openSidebar: Bool = false) -> String? {
        var options = WOWorkspaceOpenOptions()
        options.requestedBy = requestedBy
        // agent 驱动默认后台（永不抢焦点）；用户明确要求（openSidebar）才展开。
        options.background = (requestedBy == .agent) && !openSidebar
        return open(Request(sessionId: sessionId,
                            target: .browser(url: url),
                            options: options))
    }
}
