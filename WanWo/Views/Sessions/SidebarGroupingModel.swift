//
//  SidebarGroupingModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 dsh WorkspaceBrowser.tsx（§9 左侧栏欠账对账）】
//  左侧栏分组纯逻辑（§9 清单 1/2/3/7）：
//    1. 工作区分组树：工作区行 + 组内会话 + Ungrouped 桶（deriveGroups/
//       UNGROUPED_KEY :25 语义）；
//    2. 每组折叠：COLLAPSED_SESSION_LIMIT = 5（:41-56）+ "展开其余 N 个
//       会话"；blank 占位会话（title nil/空）不计入限额（:43-56）；
//    3. 存储视图序与工作区账本对账（reconciledSessionOrder :97+）——组内
//       序 = workspaceSessionOrder 账本（WorkspaceRecord.sessionIds），
//       账本外成员按 updatedAt 降序补尾；
//    7. blank 占位会话语义 = 新建会话的临时行（title nil → 「新会话」）。
//  平铺模式保留 M3 以来单层列表（既有行为零变化）。
//

import Foundation

/// 侧栏排序（ViewOptionsMenu 的排序维；dsh SessionOrderBy 子集）。
enum SidebarSort: String, CaseIterable, Equatable {
    case updatedDesc   // 更新时间降序（dsh orderBy.updated 缺省）
    case titleAsc      // 标题升序
}

/// 一个侧栏分组（工作区 / Ungrouped 桶 / 平铺）。
struct SidebarGroup: Identifiable, Equatable {
    let id: String
    let title: String
    /// 工作区 id（Ungrouped/平铺 = nil——insertSessionBefore 语义仅工作区可用）。
    let workspaceID: String?
    /// 对账后的组内会话 id 序（账本序优先，账本外 updatedAt 降序补尾）。
    let sessionIds: [String]
}

enum SidebarGroupingModel {

    /// dsh WorkspaceBrowser.tsx:41 COLLAPSED_SESSION_LIMIT。
    static let collapsedSessionLimit = 5
    /// dsh UNGROUPED_KEY :25。
    static let ungroupedKey = "ungrouped"
    /// 平铺模式分组键（M3 既有单层列表的保留形态）。
    static let flatKey = "flat"

    /// blank 占位判定（title nil 或空白 → 「新会话」临时行）。
    nonisolated static func isBlank(_ summary: SessionSummary) -> Bool {
        guard let title = summary.title else { return true }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 本地标题过滤（dsh :877 trim 语义；服务端内容搜索 = M9.3 FTS 后置）。
    nonisolated static func filterSessions(_ sessions: [SessionSummary],
                                           query: String) -> [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            ($0.title ?? "新会话").localizedCaseInsensitiveContains(needle)
        }
    }

    /// 排序（平铺/未分组桶用；组内序由账本承担——dsh 视图序对账语义）。
    nonisolated static func sorted(_ sessions: [SessionSummary],
                                   by sort: SidebarSort) -> [SessionSummary] {
        switch sort {
        case .updatedDesc:
            // dsh WorkspaceBrowser.tsx:116-121 compareSessionRecency：
            // updatedAt 降序 + Session id 升序 tie-break。
            return sessions.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
        case .titleAsc:
            return sessions.sorted {
                ($0.title ?? "新会话").localizedStandardCompare($1.title ?? "新会话")
                    == .orderedAscending
            }
        }
    }

    /// 存储视图序与工作区账本对账（dsh reconciledSessionOrder :97+ 折算）：
    /// workspaceRecord.sessionIds（账本，已在 hydrate 层过滤成员资格）中仍在
    /// 会话集合的 id 保持账本序；账本未记的成员（新会话先建后 attach 竞态、
    /// Ungrouped 会话）按 updatedAt 降序补尾。
    nonisolated static func reconciledSessionOrder(
        ledger: [String], sessions: [SessionSummary]) -> [String] {
        let known = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var result = ledger.filter { known[$0] != nil }
        let inLedger = Set(result)
        let leftovers = sessions
            .filter { !inLedger.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
        result.append(contentsOf: leftovers.map(\.id))
        return result
    }

    /// 分组树（§9 清单 1）：分组开 → 每工作区一组（dsh deriveGroups :25——
    /// 空工作区也出组行）+ Ungrouped 桶（未归工作区会话）；分组关 → 平铺单组。
    /// 输入会话应为「已过滤+已归档排除」后的渲染集合（本模型不做过滤）。
    nonisolated static func deriveGroups(sessions: [SessionSummary],
                                         workspaces: [WorkspaceRecord],
                                         grouped: Bool,
                                         sort: SidebarSort) -> [SidebarGroup] {
        guard grouped else {
            let ordered = sorted(sessions, by: sort)
            return [SidebarGroup(id: flatKey, title: "会话",
                                 workspaceID: nil,
                                 sessionIds: ordered.map(\.id))]
        }
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var groups: [SidebarGroup] = []
        var assigned = Set<String>()
        for workspace in workspaces {
            let ordered = reconciledSessionOrder(ledger: workspace.sessionIds,
                                                 sessions: sessions)
                .compactMap { byID[$0] }
            ordered.forEach { assigned.insert($0.id) }
            groups.append(SidebarGroup(id: workspace.id, title: workspace.title,
                                       workspaceID: workspace.id,
                                       sessionIds: ordered.map(\.id)))
        }
        // Ungrouped 桶（dsh UNGROUPED_KEY）：未归任何工作区的会话，排序照 sort。
        let ungrouped = sessions.filter { !assigned.contains($0.id) }
        groups.append(SidebarGroup(id: ungroupedKey, title: "未分组",
                                   workspaceID: nil,
                                   sessionIds: sorted(ungrouped, by: sort).map(\.id)))
        return groups
    }

    /// 折叠视图（§9 清单 2）：收起态可见 = 前 5 条非 blank + 全部 blank 占位
    /// （blank 不计入限额——dsh :43-56）；展开态全量。返回 (可见序, 隐藏数)。
    nonisolated static func collapseView(ids: [String],
                                         sessions: [SessionSummary],
                                         expanded: Bool)
        -> (visible: [String], hiddenCount: Int) {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        if expanded {
            return (ids, 0)
        }
        var visible: [String] = []
        var nonBlankCount = 0
        var hidden = 0
        for id in ids {
            let summary = byID[id]
            let blank = summary.map(isBlank) ?? false
            if blank {
                // blank 占位恒可见、不占限额。
                visible.append(id)
            } else if nonBlankCount < collapsedSessionLimit {
                visible.append(id)
                nonBlankCount += 1
            } else {
                hidden += 1
            }
        }
        return (visible, hidden)
    }
}
