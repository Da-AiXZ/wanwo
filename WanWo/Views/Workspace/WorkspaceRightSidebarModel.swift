//
//  WorkspaceRightSidebarModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.0（codex 桌面截图讲解版布局总则）】
//  右侧边栏页签容器（A 骨架）：
//    · 多页签混开（文件/终端/浏览器/侧聊/审查任意组合），每页签 × 可关；
//    · 「+」= 弹出菜单五项新开（codex :202+ 词汇）；
//    · 收起/展开 + 全屏（全屏 = 右侧栏占满整窗，左栏可另行收起——RootView 折算
//      为 NavigationSplitViewVisibility.detail）。
//  页签数据结构直接做成可扩展枚举（派单口径：M6 骨架期不过度建模）：
//    · 文件/终端/侧聊/审查 = 单例页签（重复点选 = 激活既有页签，codex 同形态）；
//    · 浏览器 = 可多开（每次「+」新开一枚，id 唯一）。
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

    /// 页签缺省标题（dsh Web UI / codex 词汇）。
    var title: String {
        switch self {
        case .files: return "文件"
        case .terminal: return "终端"
        case .browser: return "浏览器"
        case .sideChat: return "侧边聊天"
        case .review: return "审查"
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
        }
    }
}

/// 一枚右侧栏页签。
struct WorkspaceTab: Identifiable, Equatable {
    /// 单例页签 id = kind rawValue；浏览器页签 id 唯一（browser-<uuid>）。
    let id: String
    let kind: WorkspaceTabKind
    /// 浏览器页签初始导航目标（wanwo:// 资源深链接线；其余 nil）。
    var initialURL: URL?

    /// 单例页签（文件/终端/侧聊/审查）。
    static func singleton(_ kind: WorkspaceTabKind) -> WorkspaceTab {
        WorkspaceTab(id: kind.rawValue, kind: kind, initialURL: nil)
    }

    /// 浏览器页签（可多开；initialURL = 打开即导航）。
    static func browser(initialURL: URL? = nil) -> WorkspaceTab {
        WorkspaceTab(id: "browser-" + UUID().uuidString,
                     kind: .browser, initialURL: initialURL)
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
    /// 侧栏展开/收起（收起 = 整栏不渲染，主对话区全宽）。
    @Published var isExpanded = true
    /// 全屏（右侧栏占满整窗；左栏由 RootView 折叠）。
    @Published var isFullscreen = false
    /// 「审查」入口可见性（仅 git 仓库项目——工作区宿主根存在 .git 目录时）。
    @Published var reviewAvailable = false

    // MARK: - 状态机纯函数（单测直呼）

    /// open 落点：单例页签已存在 → 激活不新建；浏览器页签恒新建；容量满 → 拒绝。
    /// 返回 (新页签数组, 应激活 id, 是否实际新建)。
    nonisolated static func opening(_ tab: WorkspaceTab,
                                    in tabs: [WorkspaceTab],
                                    maxTabs: Int = WorkspaceRightSidebarModel.maxTabs)
        -> (tabs: [WorkspaceTab], activatedID: String, created: Bool) {
        if tab.kind != .browser,
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

    /// close 落点：关闭后激活邻近页签——优先前一邻居，无前邻居取后一邻居；
    /// 关非活动页签 → 活动不变；关空 → nil。
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
        if let previous = index > 0 ? tabs[index - 1] : nil {
            return (remaining, previous.id)
        }
        let next = index < tabs.count ? tabs[index] : nil
        return (remaining, next?.id)
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
        let result = Self.closing(id: id, tabs: tabs, activeID: activeTabID)
        tabs = result.tabs
        activeTabID = result.newActive
    }

    /// 「+」菜单五项（派单口径：审查/git 项目第一位；浏览器每次新开）。
    func openFromMenu(_ kind: WorkspaceTabKind) {
        switch kind {
        case .browser:
            open(.browser())
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

    /// 当前活动页签。
    var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID }
    }

    /// 「+」菜单的候选（审查仅 git 项目可见；其余恒可见——浏览器恒可新开）。
    func menuKinds() -> [WorkspaceTabKind] {
        var kinds: [WorkspaceTabKind] = []
        if reviewAvailable { kinds.append(.review) }
        kinds.append(contentsOf: [.files, .sideChat, .browser, .terminal])
        return kinds
    }

    /// 会话切换时刷新「审查」入口可见性（工作区宿主根存在 .git 即可见——
    /// git 二进制可用性在页签打开时再探，探败给空态解释）。
    func updateReviewAvailability(sessionID: String?) {
        guard let sessionID else {
            reviewAvailable = false
            return
        }
        let workspaceHost = WanWoPaths.sessionPersistentDir(for: sessionID,
                                                            bucket: "workspace")
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
