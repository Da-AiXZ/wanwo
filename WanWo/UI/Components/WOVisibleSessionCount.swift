//
//  WOVisibleSessionCount.swift
//  WanWo
//
//  【M7-Fix2 批2 B3 · 反馈24】删除确认计数口径与侧栏可见性对齐。
//  病灶：确认弹窗「将同时删除 N 个对话」取工作区账本实数
//  （WorkspaceRecord.sessionIds.count），隐藏的 blank 草稿会话（新会话
//  复用机制不显示在侧栏者）被计入 → N 比用户数的多 1。
//  修=只改计数口径：与侧栏会话列表的可见性规则同源过滤
//  （SidebarGroupingModel.isBlank + dsh tree.ts:131「blank 仅当它是当前
//  选中会话才可见」规则翻转）。
//  红线：删除范围一字不动（清单25 已真机验收"真删（含子代理会话）"）——
//  本函数只影响确认文案的数字，绝不参与删除集计算。
//

import Foundation

/// 删除确认计数（反馈24）——纯函数；两处调用同源：
///   · UI/Frame/WORootFrame.swift onDeleteWorkspace（工作区删除确认弹窗）
///   · Views/Sessions/SessionsSidebarView.swift wsDeleteTarget（侧栏 ⋯ 菜单）
enum WOVisibleSessionCount {

    /// 账本会话里「侧栏可见」的个数。
    /// 判定与侧栏可见性规则同源：非 blank 恒计；blank 占位（title 空且
    /// eventCount==0，SidebarGroupingModel.isBlank）仅当它是当前选中会话
    /// 才计（dsh tree.ts:131 规则翻转——当前 blank 在侧栏可见）。
    /// 账本内摘要缺失（listSessions 快照竞态）按可见计兜底——只剔除能
    /// 证明不可见的项，绝不反向多报。
    nonisolated static func count(inLedger ledger: [String],
                                  sessions: [SessionSummary],
                                  currentSessionID: String?) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var seen = Set<String>()
        var total = 0
        for id in ledger where seen.insert(id).inserted {
            if let summary = byID[id],
               SidebarGroupingModel.isBlank(summary),
               id != currentSessionID {
                continue // 隐藏 blank 草稿：侧栏不显示，计数剔除（反馈24）
            }
            total += 1
        }
        return total
    }
}
