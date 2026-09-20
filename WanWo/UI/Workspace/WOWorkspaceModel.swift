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

    /// dsh actions.setGroupExpanded——显式写展开态。账本语义：集合内 = 显式收起
    /// （isExpanded = !contains，默认展开）。expanded=true → 移出集合，false → 写入。
    /// （旧实现两语义互反 → 收起点击恒 no-op——2026-09-20 真机反馈"收不起来"根因。）
    func setGroupExpanded(_ key: String, _ expanded: Bool) {
        if expanded { groupExpansion.remove(key) } else { groupExpansion.insert(key) }
    }
    /// 展开态查询：账本无记录 = 展开（dsh 默认展开；折叠是显式动作）
    func isExpanded(_ key: String) -> Bool { !groupExpansion.contains(key) }
}

// MARK: - 派生器（tree.ts deriveGroups / deriveFlat，行 719-721）

enum WOWorkspaceTreeDeriver {

    static let ungroupedKey = ""

    /// 会话可见性（dsh tree.ts sessionVisible 1:1）：未归档且（非 blank 或当前）。
    /// blank（新会话未发消息）只在它是当前会话时可见——切走即从列表消失（用户
    /// 指令 2026-09-21：按 dsh 源码语义；骨架期"恒显"偏离随打开信号成真而退役）。
    static func isVisible(_ s: SessionSummary, archived: Set<String>,
                          currentSessionId: String?) -> Bool {
        if archived.contains(s.id) { return false }
        if isBlank(s), s.id != currentSessionId { return false }
        return true
    }

    /// blank 判定：旧数据语义 = title 为 nil（占位会话）
    static func isBlank(_ s: SessionSummary) -> Bool { s.title == nil }

    /// 分组树：workspace 序分组（成员按 sessionIds 账本序）。
    /// 「未分组」桶移除（2026-09-21 用户令）：dsh 语义里游离会话不应存在——
    /// 创建全部收口 workspaceNavigator.startSession（必挂工作区）；历史上由
    /// 旧缺陷产生的孤儿会话不再列出（数据保留在库，登记于 11-ui-design §十六）。
    /// R1：运行/待决真值入节点（D3 清偿；pending 粒度=有/无，种类文案挂 R3 拆镜像）。
    static func deriveGroups(
        sessions: [SessionSummary],
        workspaces: [WorkspaceRecord],
        archived: Set<String>,
        currentSessionId: String?,
        activeRunSessionIDs: Set<String>,
        pendingSessionIDs: Set<String>,
        orderBy: WOOrderBy
    ) -> [WOGroupNode] {
        let visible = sessions.filter { isVisible($0, archived: archived, currentSessionId: currentSessionId) }
        var byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })

        var groups: [WOGroupNode] = []

        // workspace 序分组：成员 = registry 账本序（过滤掉不存在的会话）。
        // 排序方式：manual = 账本序（手动排序真源）；updated = 组内按 updatedAt
        // 倒序重排（原型「排序『最近更新』按 parseTime 组内重排」；blank 占位居顶
        // 不参与重排）。
        for ws in workspaces {
            var members = ws.sessionIds.compactMap { byID.removeValue(forKey: $0) }
            if orderBy == .updated {
                let blanks = members.filter { isBlank($0) }
                let normal = members.filter { !isBlank($0) }
                    .sorted { $0.updatedAt > $1.updatedAt }
                members = blanks + normal
            }
            groups.append(makeGroup(key: ws.id, workspaceId: ws.id, label: ws.title,
                                    createdAt: ws.createdAt, members: members,
                                    currentSessionId: currentSessionId,
                                    activeRunSessionIDs: activeRunSessionIDs,
                                    pendingSessionIDs: pendingSessionIDs))
        }

        // 游离会话（不在任何工作区账本内）不进列表——未分组桶已移除（见上）。
        return groups
    }

    private static func makeGroup(key: String, workspaceId: String?, label: String,
                                  createdAt: Date?, members: [SessionSummary],
                                  currentSessionId: String?,
                                  activeRunSessionIDs: Set<String>,
                                  pendingSessionIDs: Set<String>) -> WOGroupNode {
        let nodes = members.map { s in
            var node = WOSessionNode(id: s.id, title: s.title, blank: isBlank(s),
                                     createdAt: s.createdAt, updatedAt: s.updatedAt)
            // R1 真值：运行中（镜像 onPhaseChange/onTurnEnd）+ 待决（琥珀点，
            // 镜像 presentApproval/Question；种类区分挂 R3 拆镜像）。
            node.running = activeRunSessionIDs.contains(s.id)
            node.pendingKind = pendingSessionIDs.contains(s.id) ? .approval : nil
            return node
        }
        let containsCurrent = currentSessionId.map { current in
            nodes.contains(where: { node in node.id == current })
        } ?? false
        return .init(key: key, workspaceId: workspaceId, label: label, createdAt: createdAt,
                     sessions: nodes, containsCurrent: containsCurrent)
    }

    /// 扁平列表：工作区账本内可见会话顶层行，严格最新优先（手册 720 行）。
    /// 未分组桶移除 → 只列工作区账本内成员（孤儿过滤同 deriveGroups）。
    static func deriveFlat(
        sessions: [SessionSummary], workspaces: [WorkspaceRecord],
        archived: Set<String>, currentSessionId: String?,
        activeRunSessionIDs: Set<String>, pendingSessionIDs: Set<String>
    ) -> [WOSessionNode] {
        let ledgerIDs = Set(workspaces.flatMap { $0.sessionIds })
        return sessions
            .filter { ledgerIDs.contains($0.id) }
            .filter { isVisible($0, archived: archived, currentSessionId: currentSessionId) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { s in
                var node = WOSessionNode(id: s.id, title: s.title, blank: isBlank(s),
                                         createdAt: s.createdAt, updatedAt: s.updatedAt)
                node.running = activeRunSessionIDs.contains(s.id)
                node.pendingKind = pendingSessionIDs.contains(s.id) ? .approval : nil
                return node
            }
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
