//
//  SidebarGroupingModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 dsh WorkspaceBrowser.tsx（§9 左侧栏欠账对账）】
//  左侧栏分组纯逻辑（§9 清单 1/2/3/7）：
//    1. 工作区分组树：工作区行 + 组内会话（deriveGroups；【工作区模型修正】
//       UNGROUPED_KEY 桶已删——会话创建收口到工作区，无游离会话）；
//    2. 每组折叠：COLLAPSED_SESSION_LIMIT = 5（:41-56）+ "展开其余 N 个
//       会话"；blank 占位会话（title nil/空）不计入限额（:43-56）；
//    3. 存储视图序与工作区账本对账（reconciledSessionOrder :97+）——组内
//       序 = workspaceSessionOrder 账本（WorkspaceRecord.sessionIds），
//       账本成员按账本序排定（reconciledSessionOrder 的账本外补尾只服务
//       于"账本未记成员"的直接调用场景，不作为 deriveGroups 的组成员
//       资格来源——组成员资格 = 账本 ∩ 会话集合，见 deriveGroups）；
//    7. blank 占位会话语义 = 新建会话的临时行（title nil → 「新会话」）。
//  【UI 对齐批 1（C3/C4/C5）增量】
//    · blank 规则翻转（dsh tree.ts:131）：blank 占位会话仅当它是当前选中
//      会话才可见（原先恒可见做反了）——deriveGroups 增 currentSessionID；
//    · 账户视图序（dsh :296-336 折算）：deriveGroups 增 accountOrders——
//      「按更新」模式下组内/平铺按排序账户（SidebarOrderAccounts）
//      对账展示，账本序仍是持久真源；
//    · 搜索升级（dsh :352-427 本地半边）：本地过滤 = 标题 + 所属工作区名
//      子串，blank 排除（dsh :384——blank 规范标题恒空，可搜即绑语言）；
//      查询消毒（去 NUL + 500 UTF-16 code units 上限，:59-67）。
//
//  平铺模式保留 M3 以来单层列表（既有交互零变化）。
//

import Foundation

/// 侧栏排序（ViewOptionsMenu 的排序维；dsh SessionOrderBy 子集）。
enum SidebarSort: String, CaseIterable, Equatable {
    case updatedDesc   // 更新时间降序（dsh orderBy.updated 缺省）
    case titleAsc      // 标题升序
}

/// 一个侧栏分组（工作区 / 平铺）。
struct SidebarGroup: Identifiable, Equatable {
    let id: String
    let title: String
    /// 工作区 id（平铺 = nil——insertSessionBefore 语义仅工作区可用）。
    let workspaceID: String?
    /// 对账后的组内会话 id 序（账本序优先，账本外 updatedAt 降序补尾）。
    let sessionIds: [String]
}

enum SidebarGroupingModel {

    /// dsh WorkspaceBrowser.tsx:41 COLLAPSED_SESSION_LIMIT。
    static let collapsedSessionLimit = 5
    /// 平铺模式分组键（M3 既有单层列表的保留形态）。
    static let flatKey = "flat"

    /// blank 占位判定（title nil 或空白 → 「新会话」临时行）。
    nonisolated static func isBlank(_ summary: SessionSummary) -> Bool {
        guard let title = summary.title else { return true }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 查询上限（dsh WorkspaceBrowser.tsx:39——500 UTF-16 code units）。
    static let queryMaxCodeUnits = 500

    /// 查询消毒（dsh sanitizeSearchQuery :59-67）：去 NUL + 代理对安全截断
    /// 到 500 UTF-16 code units。
    nonisolated static func sanitizeQuery(_ raw: String) -> String {
        let withoutNUL = raw.replacingOccurrences(of: "\0", with: "")
        var units = Array(withoutNUL.utf16)
        guard units.count > queryMaxCodeUnits else { return withoutNUL }
        var end = queryMaxCodeUnits
        // 代理对安全：被截点恰好拆散代理对时回退一位。
        if units[end - 1] >= 0xD800, units[end - 1] <= 0xDBFF,
           end < units.count, units[end] >= 0xDC00, units[end] <= 0xDFFF {
            end -= 1
        }
        units.removeSubrange(end...)
        return String(decoding: units, as: UTF16.self)
    }

    /// 本地过滤（dsh deriveSearchResults 本地半边 :379-392）：标题 + 所属
    /// 工作区名子串（工作区标题优先，未归属会话无工作区标签）；blank 排除
    /// （dsh :384——blank 行规范标题恒空，可搜即绑单一语言）。
    /// 服务端内容搜索 = M9.3 FTS 后置（挂账不变）。
    nonisolated static func filterSessions(_ sessions: [SessionSummary],
                                           query: String,
                                           workspaces: [WorkspaceRecord] = []) -> [SessionSummary] {
        let needle = sanitizeQuery(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sessions }
        // 会话 → 工作区标题映射（dsh workspaceBySession :366-371）。
        var titleBySession: [String: String] = [:]
        for workspace in workspaces {
            for sessionID in workspace.sessionIds where titleBySession[sessionID] == nil {
                titleBySession[sessionID] = workspace.title
            }
        }
        return sessions.filter { summary in
            if isBlank(summary) { return false }
            if let title = summary.title,
               title.localizedCaseInsensitiveContains(needle) { return true }
            if let workspaceTitle = titleBySession[summary.id],
               workspaceTitle.localizedCaseInsensitiveContains(needle) { return true }
            return false
        }
    }

    /// 排序（平铺模式用；组内序由账本承担——dsh 视图序对账语义）。
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
    /// 会话集合的 id 保持账本序；账本未记的成员（新会话先建后 attach 竞态的
    /// 直接调用场景）按 updatedAt 降序补尾。
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
    /// 空工作区也出组行）；分组关 → 平铺单组。
    /// 【工作区模型修正】Ungrouped 桶删除：会话创建已收口到工作区
    /// （createSession 仅在选定工作区内创建 + attach 校验，失败即回滚），
    /// 不存在未归工作区的会话——不在任何工作区账本的会话（防御面）直接
    /// 不渲染，绝不再出现「未分组」桶。
    /// 输入会话应为「已过滤+已归档排除」后的渲染集合（本模型不做归档过滤）。
    /// 【UI 对齐批 1 增量】
    ///   · currentSessionID：blank 规则翻转（dsh tree.ts:131）——blank 占位
    ///     会话仅当它是当前选中会话才可见；
    ///   · accountOrders：排序账户展示序（dsh :296-336 折算）——nil = 既有
    ///     行为（组内账本序 / 其余按 sort），非 nil = 各组按账户序对账展示。
    nonisolated static func deriveGroups(sessions: [SessionSummary],
                                         workspaces: [WorkspaceRecord],
                                         grouped: Bool,
                                         sort: SidebarSort,
                                         currentSessionID: String? = nil,
                                         accountOrders: [String: [String]]? = nil) -> [SidebarGroup] {
        // blank 规则翻转（dsh sessionVisible :131-135）：blank 仅当它是当前
        // 会话才可见——分组/平铺全域同规则（dsh deriveFlat :332 同源）。
        let visible = sessions.filter { !isBlank($0) || $0.id == currentSessionID }
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        guard grouped else {
            let ordered: [String]
            if let accountOrders {
                ordered = reconciledOrder(stored: accountOrders[flatKey] ?? [],
                                          within: visible.map(\.id))
            } else {
                ordered = sorted(visible, by: sort).map(\.id)
            }
            return [SidebarGroup(id: flatKey, title: "会话",
                                 workspaceID: nil,
                                 sessionIds: ordered)]
        }
        var groups: [SidebarGroup] = []
        for workspace in workspaces {
            // 组成员资格 = 账本（workspace.sessionIds）∩ 会话集合。
            // 账本序对账（reconciledSessionOrder）只作用于账本成员的排序。
            // 【工作区模型修正】不在任何工作区账本的会话（防御面）不渲染
            // ——Ungrouped 桶已删，会话创建已收口到工作区（attach 失败即回滚）。
            let ledgerMembers = workspace.sessionIds.filter { byID[$0] != nil }
            let ordered: [String]
            if let accountOrders {
                ordered = reconciledOrder(stored: accountOrders[workspace.id] ?? [],
                                          within: ledgerMembers)
            } else {
                ordered = ledgerMembers
            }
            groups.append(SidebarGroup(id: workspace.id, title: workspace.title,
                                       workspaceID: workspace.id,
                                       sessionIds: ordered))
        }
        return groups
    }

    /// stored 视图序与成员集对账（dsh reconciledSessionOrder :97-113 折算）：
    /// stored 命中保持序且去重，新成员按传入序补尾。
    nonisolated static func reconciledOrder(stored: [String], within sessionIds: [String]) -> [String] {
        let memberSet = Set(sessionIds)
        var seen = Set<String>()
        var result = stored.filter { memberSet.contains($0) && seen.insert($0).inserted }
        let included = Set(result)
        for id in sessionIds where !included.contains(id) {
            result.append(id)
        }
        return result
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
