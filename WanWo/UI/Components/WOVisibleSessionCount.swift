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
//  【批3 A4.2】可见性规则补齐 dsh tree.ts:131-135 sessionVisible 三项的
//  第三项：子代理 origin 会话恒隐藏（`session.origin !== 'subagent'`）——
//  判定经 WOSubagentLineageVisibility.isSubagentOrigin（唯一事实源，与
//  SessionsSidebarView.filteredSummaries 同源；B3 红线）。锁盒读廉价、
//  线程安全；未分类会话按可见计兜底（只剔除能证明不可见的项，绝不反向
//  多报——原口径不变）。
//

import Foundation

/// 删除确认计数（反馈24）——纯函数；两处调用同源：
///   · UI/Frame/WORootFrame.swift onDeleteWorkspace（工作区删除确认弹窗）
///   · Views/Sessions/SessionsSidebarView.swift wsDeleteTarget（侧栏 ⋯ 菜单）
enum WOVisibleSessionCount {

    /// 账本会话里「侧栏可见」的个数。
    /// 判定与侧栏可见性规则同源（dsh tree.ts:131-135 sessionVisible 1:1）：
    ///   ① 子代理 origin 会话恒隐藏（WOSubagentLineageVisibility 唯一
    ///      事实源——与 SessionsSidebarView.filteredSummaries 同源；
    ///      批3 A4.2。判定只依赖 id，不依赖摘要快照在否）；
    ///   ② 非 blank 恒计；blank 占位（title 空且 eventCount==0，
    ///      SidebarGroupingModel.isBlank）仅当它是当前选中会话才计
    ///      （dsh「blank 仅当它是当前选中会话才可见」规则翻转）。
    /// 账本内摘要缺失（listSessions 快照竞态）与未分类会话按可见计兜底
    /// ——只剔除能证明不可见的项，绝不反向多报。
    nonisolated static func count(inLedger ledger: [String],
                                  sessions: [SessionSummary],
                                  currentSessionID: String?) -> Int {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var seen = Set<String>()
        var total = 0
        for id in ledger where seen.insert(id).inserted {
            // ① 子代理 origin 会话：侧栏恒隐藏（dsh tree.ts:132），计数
            // 剔除。锁盒读廉价线程安全；未分类（侧栏未 reconcile 过）按
            // 可见计——兜底口径不变。
            if WOSubagentLineageVisibility.isSubagentOrigin(id) { continue }
            if let summary = byID[id],
               SidebarGroupingModel.isBlank(summary),
               id != currentSessionID {
                continue // ② 隐藏 blank 草稿：侧栏不显示，计数剔除（反馈24）
            }
            total += 1
        }
        return total
    }
}
