//
//  WorkspaceRightSidebarModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.0（codex 桌面截图讲解版布局总则）】
//  右侧边栏页签容器（A 骨架）：
//    · 多页签混开（文件/终端/浏览器/侧聊/审查任意组合），每页签 × 可关；
//    · 「+」= 弹出菜单新开（codex :202+ 词汇）；
//    · 收起/展开 + 全屏（全屏 = 右侧栏占满整窗——【批3 C⑤】左栏联动由
//      RootView 条件根布局承载，isFullscreen 驱动换根）。
//  页签数据结构直接做成可扩展枚举（派单口径：M6 骨架期不过度建模）：
//    · 终端/侧聊/审查 = 单例页签（重复点选 = 激活既有页签，codex 同形态）；
//    · 浏览器 = 可多开（每次「+」新开一枚，id 唯一）；
//    · 【批3 C⑥】文件页随 codex「+ 菜单·新开文件页」语义改可多开
//      （WorkspaceTab.filesPage()，id 唯一；原 M6 骨架单例形态放开）。
//  状态机核心（open/close 的选择落点）提为纯函数（单测直呼；页签容器状态机
//  为本批验收单测面）。
//


import Foundation
import SwiftUI

/// 页签种类（可扩展枚举——M9 新页签种类在此加 case 即可）。
enum WorkspaceTabKind: String, Equatable, CaseIterable {
    case files
    case terminal
    case browser
    case sideChat
    case review
    /// 【批2 2C】轨迹页签（dsh ui-trajectory 台账版——事件台账 + 记录
    /// 检查器；时间线四模式明确降级不做，见 TrajectoryTabView 头注）。
    case trajectory

    /// 页签缺省标题（dsh Web UI / codex 词汇）。
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

    /// 页签图标（SF Symbol——iOS 形态自定，不抄桌面视觉）。
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

/// 一枚右侧栏页签。
struct WorkspaceTab: Identifiable, Equatable {
    /// 单例页签 id = kind rawValue；浏览器/文件页签 id 唯一（<kind>-<uuid>）。
    let id: String
    let kind: WorkspaceTabKind
    /// 浏览器页签初始导航目标（wanwo:// 资源深链接线；其余 nil）。
    var initialURL: URL?

    /// 单例页签（终端/侧聊/审查）。
    static func singleton(_ kind: WorkspaceTabKind) -> WorkspaceTab {
        WorkspaceTab(id: kind.rawValue, kind: kind, initialURL: nil)
    }

    /// 浏览器页签（可多开；initialURL = 打开即导航）。
    static func browser(initialURL: URL? = nil) -> WorkspaceTab {
        WorkspaceTab(id: "browser-" + UUID().uuidString,
                     kind: .browser, initialURL: initialURL)
    }

    /// 【批3 C⑥】文件页签（可多开——codex「+ 菜单·新开文件页」语义；
    /// 每「+」新开一枚，id 唯一）。
    static func filesPage() -> WorkspaceTab {
        WorkspaceTab(id: "files-" + UUID().uuidString,
                     kind: .files, initialURL: nil)
    }
}

/// 右侧边栏容器状态机（App 内单实例，挂 RootView @StateObject）。
@MainActor
final class WorkspaceRightSidebarModel: ObservableObject {

    /// 页签容量（骨架期上限；防滥用无限开）。
    static let maxTabs = 8
    /// 展开态宽度预算（iPad 横屏自查：380pt ≈ 1/3 屏，主对话区保有对话可读宽）。
    static let expandedWidth: CGFloat = 380

    @Published private(set) var tabs: [WorkspaceTab] = []
    @Published var activeTabID: String?
    /// 侧栏展开/收起（收起 = 布局列宽 0 让位主区，右栏本体保持挂载——批9B）。
    /// 批10：初值 true→false（2026-09-22 用户令：右栏只听手动开关与 AI 资源
    /// 打开（wanwo:// 深链），启动不再自动开）。
    @Published var isExpanded = false
    /// 全屏（右侧栏占满整窗；【批3 C⑤】左栏由 RootView 条件根布局隐藏）。
    @Published var isFullscreen = false
    /// 「审查」入口可见性（仅 git 仓库项目——工作区宿主根存在 .git 目录时）。
    @Published var reviewAvailable = false
    /// AI 专用浏览器页签 id（批12+联动B 2026-09-27 用户裁决：单活动页签跟随
    /// ——AI 换页=同页签跳转不新建；✕ 关闭置 nil，下次明确要求时重建）。
    var agentBrowserTabID: String?

    // MARK: - 状态机纯函数（单测直呼）

    /// open 落点：单例页签已存在 → 激活不新建；浏览器/文件页签恒新建；容量满 → 拒绝。
    /// 返回 (新页签数组, 应激活 id, 是否实际新建)。
    nonisolated static func opening(_ tab: WorkspaceTab,
                                    in tabs: [WorkspaceTab],
                                    maxTabs: Int = WorkspaceRightSidebarModel.maxTabs)
        -> (tabs: [WorkspaceTab], activatedID: String, created: Bool) {
        if tab.kind != .browser && tab.kind != .files,
           let existing = tabs.first(where: { $0.id == tab.id }) {
            return (tabs, existing.id, false)
        }
        guard tabs.count < maxTabs else {
            // 容量满：已存在则激活，否则激活尾页签（不崩、可解释）。
            if let existing = tabs.first(where: { $0.id == tab.id }) {
                return (tabs, existing.id, false)
            }
            return (tabs, tabs.last?.id ?? tab.id, false)
        }
        return (tabs + [tab], tab.id, true)
    }

    /// close 落点：关闭后激活邻近页签——优先右侧邻居（下一位，codex/VS Code
    /// 系生态惯例：关页签激活右邻），无右邻取前邻；关非活动页签 → 活动不变；
    /// 关空 → nil。
    nonisolated static func closing(id: String,
                                    tabs: [WorkspaceTab],
                                    activeID: String?)
        -> (tabs: [WorkspaceTab], newActive: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            return (tabs, activeID)
        }
        var remaining = tabs
        remaining.remove(at: index)
        guard id == activeID else { return (remaining, activeID) }
        // 【终验修】右邻回退必须在 `remaining`（关后数组）上取——原实现用
        // `tabs[index]`（原数组）取到的是被关页签自身，导致关末签激活自己、
        // 关最后一签兜底回被关页签而非 nil（codex 语义：关最后页签=内容区空态）。
        if let next = index < remaining.count ? remaining[index] : nil {
            return (remaining, next.id)
        }
        let previous = index > 0 ? tabs[index - 1] : nil
        return (remaining, previous?.id)
    }

    /// 【批3 C③】「+」菜单/页签列表页候选（纯函数——空态页签列表页与
    /// 「+」菜单同源；审查仅 git 项目；【批2 2C】轨迹页签入列）。
    nonisolated static func candidateKinds(reviewAvailable: Bool) -> [WorkspaceTabKind] {
        var kinds: [WorkspaceTabKind] = []
        if reviewAvailable { kinds.append(.review) }
        kinds.append(contentsOf: [.files, .sideChat, .browser, .terminal, .trajectory])
        return kinds
    }

    // MARK: - 状态机操作

    /// 打开（或激活）一枚页签。
    func open(_ tab: WorkspaceTab) {
        let result = Self.opening(tab, in: tabs)
        tabs = result.tabs
        activeTabID = result.activatedID
        if !isExpanded { isExpanded = true }
    }

    /// 关闭一枚页签（状态机纯函数落点）。
    func close(id: String) {
        // 批12+联动B：AI 专用页签被手动 ✕ → 旗标清零（下次 AI 导航按
        // autoOpen 语义重建；防悬挂 id 指向已删页签）。
        if id == agentBrowserTabID { agentBrowserTabID = nil }
        let result = Self.closing(id: id, tabs: tabs, activeID: activeTabID)
        tabs = result.tabs
        activeTabID = result.newActive
    }

    /// 「+」菜单落点（审查/git 项目第一位；浏览器每次新开；
    /// 【批3 C⑥】文件页随 codex「新开文件页」改可多开）。
    func openFromMenu(_ kind: WorkspaceTabKind) {
        switch kind {
        case .browser:
            open(.browser())
        case .files:
            open(.filesPage())
        default:
            open(.singleton(kind))
        }
    }

    /// wanwo:// 资源深链入口（B2 标注「B4 接线点」的消费端）：新开浏览器页签
    /// 并以资源 URL 为初始导航（资源 URL 由 WKWebView 内 WanwoURLSchemeHandler
    /// 直接服务——B2 保留代码路径）。
    func openResourceURL(_ url: URL) {
        open(.browser(initialURL: url))
    }

    /// 【批12+联动A/B（2026-09-26/27）】AI 浏览器导航的 UI 落点。
    /// 批12+联动B（用户裁决"AI 每换一页就再开一个"修法）：**单活动页签跟随**
    /// ——AI 页签已存在=同页签换 URL（视图 onChange(initialURL) 消费）不新建；
    /// autoOpen（用户明确要求/截图）=激活+右栏展开；autoOpen=false 且无 AI
    /// 页签=不建签（轻提示由 WOChatView 呈现，不打扰）。✕ 删除=close 清旗。
    /// 触发链：BrowserUseManager navigate/screenshot 成功 → NotificationCenter
    /// .wanwoAgentBrowserNavigation（userInfo openSidebar）→ WORootFrame → 本方法。
    func openAgentBrowser(url: URL, autoOpen: Bool = true) {
        if let id = agentBrowserTabID,
           let idx = tabs.firstIndex(where: { $0.id == id }),
           tabs[idx].kind == .browser {
            tabs[idx].initialURL = url
            if autoOpen {
                activeTabID = id
                if !isExpanded { isExpanded = true }
            }
            return
        }
        guard autoOpen else { return }
        let tab = WorkspaceTab.browser(initialURL: url)
        agentBrowserTabID = tab.id
        open(tab)
    }

    /// 当前活动页签。
    var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// 「+」菜单的候选（与页签列表页空态同源——批3 C③）。
    func menuKinds() -> [WorkspaceTabKind] {
        Self.candidateKinds(reviewAvailable: reviewAvailable)
    }

    /// 【批3 C②】无会话强制收起（codex 截图 #3：右栏只在会话场景可用——
    /// selection 非 .session 时开关钮隐藏 + 右栏收起 + 退出全屏；RootView
    /// onAppear/onChange 落点）。
    func reconcileForSelection(sessionID: String?) {
        guard sessionID == nil else { return }
        if isExpanded || isFullscreen {
            isExpanded = false
            isFullscreen = false
        }
    }

    /// 会话切换时刷新「审查」入口可见性（工作区宿主根存在 .git 即可见——
    /// git 二进制可用性在页签打开时再探，探败给空态解释）。
    /// 批12+工作区贯穿：宿主根跟随会话绑定工作区路径（项目模式=真实项目
    /// 目录），legacy 回落桶根。
    func updateReviewAvailability(sessionID: String?, workspacePath: String? = nil) {
        guard let sessionID else {
            reviewAvailable = false
            return
        }
        let workspaceHost: URL
        if let workspacePath,
           let projectHost = WanWoPaths.projectsHostRoot(forGuestPath: workspacePath) {
            workspaceHost = projectHost
        } else {
            workspaceHost = WanWoPaths.sessionPersistentDir(for: sessionID,
                                                            bucket: "workspace")
        }
        var isDir: ObjCBool = false
        let gitDir = workspaceHost.appendingPathComponent(".git", isDirectory: true)
        reviewAvailable = FileManager.default.fileExists(atPath: gitDir.path,
                                                         isDirectory: &isDir)
            && isDir.boolValue
        if !reviewAvailable, activeTab?.kind == .review {
            // 入口条件消失：关闭审查页签（激活落点走状态机）。
            close(id: WorkspaceTabKind.review.rawValue)
        }
    }
}
