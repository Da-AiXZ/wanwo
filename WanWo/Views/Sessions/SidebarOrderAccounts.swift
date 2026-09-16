//
//  SidebarOrderAccounts.swift
//  WanWo
//
//  【UI 对齐批 1 · C4 排序账户 · 新写】
//  语义源：dsh ui-workspace/src/client/rows/WorkspaceBrowser.tsx：
//    · reconciledSessionOrder :97-113——存储序与会话账户对账（stored 命中保持
//      序、新成员补尾）；
//    · nextSessionOrderAccount :124-161——updated 模式的活动提升（新活动会话
//      一次性置顶 :137-149）+ 切到 updated 时全量重排（sortByRecency）；
//    · promotedBlank :847-864——当前 blank 在其账户 + flat 账户双置顶；
//    · retainAccountKeys :865-872——删除的工作区账户回收。
//  账户键：每工作区 + UNGROUPED + FLAT 各一（dsh :296-336 同构）。
//  纯逻辑结构体——SessionsSidebarView 持有状态，测试直接驱动。
//

import Foundation

/// 侧栏本地排序账户（视图序；工作区账本序是持久真源，本账户只承载
/// 「按更新」模式的活动提升与拖拽视图序，dsh sessionOrderByAccount 同位）。
struct SidebarOrderAccounts: Equatable {

    /// 账户视图序（key = 工作区 id / ungrouped 键 / flat 键）。
    private(set) var orders: [String: [String]] = [:]
    /// 上次观测的 updatedAt（活动提升的判定基线——dsh sessionUpdatedAtByAccount）。
    private(set) var observedUpdatedAt: [String: [String: Date]] = [:]

    // MARK: - 状态操作

    /// 直接写一户视图序（dsh actions.setSessionOrder——拖拽落点）。
    mutating func setOrder(_ order: [String], for key: String) {
        orders[key] = order
    }

    /// retainAccountKeys（dsh :865-872）——删除的工作区账户回收（键不在
    /// kept 集内的序与观测时间戳一并清除）。
    mutating func retain(keys: Set<String>) {
        orders = orders.filter { keys.contains($0.key) }
        observedUpdatedAt = observedUpdatedAt.filter { keys.contains($0.key) }
    }

    /// promotedBlank（dsh :847-864）——当前 blank 会话在其账户 + flat 账户
    /// 双置顶（一次性；幂等由调用方的 ref 判定承担）。
    mutating func promoteSessionToTop(_ sessionID: String, accountKeys: [String]) {
        for key in accountKeys {
            var order = orders[key] ?? []
            order.removeAll { $0 == sessionID }
            order.insert(sessionID, at: 0)
            orders[key] = order
        }
    }

    /// 一户对账（dsh useEffect :303-329 的循环体折算）：与 nextOrder 结果
    /// 变化时才写回（changed 门——避免无谓状态抖动）。
    mutating func reconcile(accountKey: String,
                            sessionIds: [String],
                            sessions: [SessionSummary],
                            activityPromotion: Bool,
                            fullResort: Bool) {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let next = Self.nextOrder(sessionIds: sessionIds,
                                  previousOrder: orders[accountKey],
                                  previousUpdatedAt: observedUpdatedAt[accountKey] ?? [:],
                                  sessionsByID: byID,
                                  activityPromotion: activityPromotion,
                                  fullResort: fullResort)
        if next.changed {
            orders[accountKey] = next.order
            observedUpdatedAt[accountKey] = next.updatedAt
        }
    }

    // MARK: - 读取

    /// 展示取序：stored 与当前成员集对账（stored 命中保持序、新成员补尾——
    /// reconciledSessionOrder 语义；无 stored = 原样回退序）。
    func order(for key: String, fallback: [String]) -> [String] {
        Self.reconciledOrder(stored: orders[key] ?? [], within: fallback)
    }

    /// 展示用快照（deriveGroups 的 accountOrders 入参）。
    var ordersSnapshot: [String: [String]] { orders }

    // MARK: - 纯函数（测试面）

    /// reconciledSessionOrder（dsh :97-113）：stored 内仍存在的 id 保持序且
    /// 去重；账户新成员按 fallback 序补尾。
    static func reconciledOrder(stored: [String], within sessionIds: [String]) -> [String] {
        let memberSet = Set(sessionIds)
        var seen = Set<String>()
        var result = stored.filter { memberSet.contains($0) && seen.insert($0).inserted }
        let included = Set(result)
        for id in sessionIds where !included.contains(id) {
            result.append(id)
        }
        return result
    }

    /// nextSessionOrderAccount（dsh :124-161）纯函数步：
    ///   · fullResort（切到 updated）→ 全量按 updatedAt 降序 + id 升序重排；
    ///   · activityPromotion（updated 常态）→ updatedAt 高于上次观测（或新
    ///     成员）的会话一次性置顶（提升者内部按 recency 排）；
    ///   · 二者皆否 → 视图序保持（manual 语义）。
    /// 返回 (新序, 新观测时间戳, 是否变化)。
    static func nextOrder(sessionIds: [String],
                          previousOrder: [String]?,
                          previousUpdatedAt: [String: Date],
                          sessionsByID: [String: SessionSummary],
                          activityPromotion: Bool,
                          fullResort: Bool)
        -> (order: [String], updatedAt: [String: Date], changed: Bool) {
        var order = previousOrder == nil
            ? sessionIds
            : reconciledOrder(stored: previousOrder ?? [], within: sessionIds)

        // compareSessionRecency（dsh :116-121）：updatedAt 降序 + id 升序。
        func recency(_ lhs: String, _ rhs: String) -> Bool {
            let lu = sessionsByID[lhs]?.updatedAt ?? .distantPast
            let ru = sessionsByID[rhs]?.updatedAt ?? .distantPast
            if lu != ru { return lu > ru }
            return lhs < rhs
        }

        if fullResort {
            order.sort(by: recency)
        } else if activityPromotion {
            // 活动提升（dsh :137-149）：上次观测缺失（新成员）或 updatedAt
            // 前进的会话；一次 promote 之后写回新基线——下一次不再重排。
            let promoted = sessionIds
                .filter { id in
                    guard let session = sessionsByID[id] else { return false }
                    guard let previous = previousUpdatedAt[id] else { return true }
                    return session.updatedAt > previous
                }
                .sorted(by: recency)
            if !promoted.isEmpty {
                let promotedSet = Set(promoted)
                order = promoted + order.filter { !promotedSet.contains($0) }
            }
        }

        var updatedAt: [String: Date] = [:]
        for id in sessionIds {
            if let session = sessionsByID[id] {
                updatedAt[id] = session.updatedAt
            }
        }
        let orderChanged = previousOrder == nil || order != previousOrder
        let timestampsChanged = updatedAt != previousUpdatedAt
        return (order, updatedAt, orderChanged || timestampsChanged)
    }
}
