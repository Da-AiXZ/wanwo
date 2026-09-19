//
//  WOWorkspaceModel.swift
//  WanWo
//
//  环 4 批 1 —— 工作区树数据模型 + 视图 store + 派生器
//  （细读文档第 4 章 tree.ts 427 行 + stores.ts 87 行 + 719-722 行语义）。
//  数据源：现有 WorkspaceRegistry + SessionStore（功能层不动）。
//

import SwiftUI

// MARK: - 会话节点（tree.ts SessionNode；万我现状无运行状态源——状态字段批 1 恒空闲，环 5 接线）

struct WOSessionNode: Identifiable, Equatable {
    let id: String
    /// nil = blank 占位（渲染层显示「新会话」）
    var title: String?
    let blank: Bool
    let createdAt: Date
    let updatedAt: Date
    /// 运行状态（批 1 数据源缺：恒 false；环 5 接 AgentLoop/事件流后填真值）
    var running: Bool = false
    var completed: Bool = false
    /// 等待类（approval/plan-review/question）——同上，批 1 恒 nil
    var pendingKind: WOPendingKind? = nil

    init(id: String, title: String?, blank: Bool, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.blank = blank
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum WOPendingKind: Equatable {
    case approval, planReview, question
}

// MARK: - 分组节点（tree.ts GroupNode）

struct WOGroupNode: Identifiable, Equatable {
    /// '' = 未分组桶（tree.ts UNGROUPED_KEY）
    let key: String
    let workspaceId: String?
    let label: String
    let createdAt: Date?
    let sessions: [WOSessionNode]
    var containsCurrent: Bool = false

    var id: String { key }
}

// MARK: - 视图选项（stores.ts：groupBy/orderBy/组展开账本）

enum WOGroupBy: String, CaseIterable {
    case workspace, flat
}

enum WOOrderBy: String, CaseIterable {
    case manual, updated
}

/// 视图偏好持久化（dsh persist 'dsh.workspace.view.v5' → 万我键名独立 v1）
@MainActor
final class WOWorkspaceViewStore: ObservableObject {
    @AppStorage("wo.workspace.groupBy.v1") private(set) var groupByRaw: String = WOGroupBy.workspace.rawValue
    @AppStorage("wo.workspace.orderBy.v1") private(set) var orderByRaw: String = WOOrderBy.updated.rawValue
    /// 组展开账本（瞬态；5+ 折叠的展开态）
    @Published private(set) var groupExpansion: Set<String> = []

    var groupBy: WOGroupBy { WOGroupBy(rawValue: groupByRaw) ?? .workspace }
    var orderBy: WOOrderBy { WOOrderBy(rawValue: orderByRaw) ?? .updated }

    init() {}

    func setGroupBy(_ v: WOGroupBy) { groupByRaw = v.rawValue }
    func setOrderBy(_ v: WOOrderBy) { orderByRaw = v.rawValue }

    /// dsh actions.setGroupExpanded——显式写展开态（旧侧栏 :972 同语义）
    func setGroupExpanded(_ key: String, _ expanded: Bool) {
        if expanded { groupExpansion.insert(key) } else { groupExpansion.remove(key) }
    }
    /// 展开态查询：账本无记录 = 展开（dsh 默认展开；折叠是显式动作）
    func isExpanded(_ key: String) -> Bool { !groupExpansion.contains(key) }
}

// MARK: - 派生器（tree.ts deriveGroups / deriveFlat，行 719-721）

enum WOWorkspaceTreeDeriver {

    static let ungroupedKey = ""

    /// 会话可见性（手册 718 行）：非 subagent 且未归档且（非 blank 或是当前会话）
    static func isVisible(_ s: SessionSummary, archived: Set<String>, currentSessionId: String?) -> Bool {
        if archived.contains(s.id) { return false }
        if isBlank(s) && s.id != currentSessionId { return false }
        return true
    }

    /// blank 判定：旧数据语义 = title 为 nil（占位会话）
    static func isBlank(_ s: SessionSummary) -> Bool { s.title == nil }

    /// 分组树：workspace 序分组（成员按 sessionIds 账本序），游离会话进「未分组」
    /// （有 stored 顺序按序 + 新散落者按 recency 追加，否则全 recency）
    static func deriveGroups(
        sessions: [SessionSummary],
        workspaces: [WorkspaceRecord],
        archived: Set<String>,
        currentSessionId: String?,
        view: WOWorkspaceViewStore
    ) -> [WOGroupNode] {
        let visible = sessions.filter { isVisible($0, archived: archived, currentSessionId: currentSessionId) }
        var byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })

        var groups: [WOGroupNode] = []

        // workspace 序分组：成员 = registry 账本序（过滤掉不存在的会话）
        for ws in workspaces {
            let members = ws.sessionIds.compactMap { byID.removeValue(forKey: $0) }
            groups.append(makeGroup(key: ws.id, workspaceId: ws.id, label: ws.title,
                                    createdAt: ws.createdAt, members: members,
                                    currentSessionId: currentSessionId, view: view))
        }

        // 游离会话 → 未分组桶：registry 账本序优先，散落者按 recency 追加
        let orphans = Array(byID.values).sorted { $0.updatedAt > $1.updatedAt }
        if !orphans.isEmpty {
            groups.append(makeGroup(key: Self.ungroupedKey, workspaceId: nil, label: "未分组",
                                    createdAt: nil, members: orphans,
                                    currentSessionId: currentSessionId, view: view))
        }
        return groups
    }

    private static func makeGroup(key: String, workspaceId: String?, label: String,
                                  createdAt: Date?, members: [SessionSummary],
                                  currentSessionId: String?, view: WOWorkspaceViewStore) -> WOGroupNode {
        let nodes = members.map { s in
            WOSessionNode(id: s.id, title: s.title, blank: isBlank(s),
                          createdAt: s.createdAt, updatedAt: s.updatedAt)
        }
        let containsCurrent = currentSessionId.map { current in
            nodes.contains(where: { node in node.id == current })
        } ?? false
        return .init(key: key, workspaceId: workspaceId, label: label, createdAt: createdAt,
                     sessions: nodes, containsCurrent: containsCurrent)
    }

    /// 扁平列表：全部可见会话顶层行，严格最新优先（手册 720 行）
    static func deriveFlat(
        sessions: [SessionSummary], archived: Set<String>, currentSessionId: String?
    ) -> [WOSessionNode] {
        sessions
            .filter { isVisible($0, archived: archived, currentSessionId: currentSessionId) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { WOSessionNode(id: $0.id, title: $0.title, blank: isBlank($0),
                                 createdAt: $0.createdAt, updatedAt: $0.updatedAt) }
    }
}

// MARK: - 状态优先级（Rows.tsx sessionStatuses，手册 745 行）
//
// pending（approval/plan-review/question→warning）> running（ongoing）> 子代理计数（万我无）>
// completed（done）> 默认（done=空闲）。批 1 数据源缺：恒走默认空闲。

enum WOSessionStatus: Equatable {
    case pending(WOPendingKind)
    case running
    case completed
    case idle

    /// StateDot 四态映射（warning/ongoing/done）
    var dotState: WOStateDotState {
        switch self {
        case .pending: return .warning
        case .running: return .ongoing
        case .completed, .idle: return .done
        }
    }

    /// 展示文案（locales.ts status.*）
    var label: String {
        switch self {
        case .pending(.approval): return "等待审批"
        case .pending(.planReview): return "计划待审"
        case .pending(.question): return "等待回答"
        case .running: return "进行中"
        case .completed: return "已完成"
        case .idle: return "空闲"
        }
    }

    /// 状态点是否显示（showStatus = state!=='done' || completed——空闲不显示点）
    var showsDot: Bool {
        if case .idle = self { return false }
        return true
    }

    static func resolve(for node: WOSessionNode) -> WOSessionStatus {
        if let pending = node.pendingKind { return .pending(pending) }
        if node.running { return .running }
        if node.completed { return .completed }
        return .idle
    }
}

// MARK: - 相对时间标签（Rows.tsx timeLabel/hoverTimeLabel + 7.1.6 分桶）

enum WOTimeLabel {
    static func short(_ t: WORelativeTime) -> String {
        switch t.unit {
        case .now: return "刚刚"
        case .minutes: return "\(t.n)分钟"
        case .hours: return "\(t.n)小时"
        case .days: return "\(t.n)天"
        case .months: return "\(t.n)个月"
        case .years: return "\(t.n)年"
        }
    }

    /// 行内时间（now → 「刚刚」，其余「{n}分钟」形式）
    static func rowLabel(updatedAt: Date, now: Date = Date()) -> String {
        short(WORelativeTimeBucket.relativeTime(at: updatedAt, now: now))
    }

    /// hover 卡时间（now 裸「刚刚」，其余「{t}前」）
    static func hoverLabel(updatedAt: Date, now: Date = Date()) -> String {
        let r = WORelativeTimeBucket.relativeTime(at: updatedAt, now: now)
        if r.unit == .now { return "刚刚" }
        return short(r) + "前"
    }
}
