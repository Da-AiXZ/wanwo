//
//  RuntimeContextProjection.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/agent-loop/src/runtime-context.ts
//  （RuntimeContextProjection：retained 状态跟踪 + project 变化检测 + CLEARED
//  清除标记）。10-design §5.9（v2.3 修订，ERR-024 缓存命中机制）。
//  语义四要点（dsh 1:1）：
//    ①runtime context 快照不进 system——作为 user 消息投影进会话流
//      （system 每请求重发，快照含时间戳时进 system 即每请求全量 miss）；
//    ②内容没变就不注入（retained?.text === snapshot 即跳过）；
//    ③注入即追加（旧快照保留在历史，新快照自带 supersedes 声明）——
//      消息流 append-only → 请求前缀稳定 → provider 前缀缓存命中；
//    ④归属管理：归属识别 = `<runtime-context>` 稳定文本标记（dsh
//      source.plugin 的 Swift 等价——事件溯源 user/message 无 source 字段，
//      以消息首标记识别归属；UI 投影层按同前缀过滤不渲染气泡）；归属消息
//      被压缩影子化（compaction/summary shadowedSeqs）时 retained 失效。
//

import Foundation

/// runtime context 快照投影（F038'；ERR-024）。
/// 值类型：由 AgentLoop（actor）独占持有，mutating 状态天然串行。
struct RuntimeContextProjection: Sendable {
    /// 快照归属标记（与 ContextInjector.baselineSnapshot 产出开头一致；
    /// ChatViewModel.markerPrefixes 同前缀过滤）。
    static let ownershipMarker = "<runtime-context>"

    /// 快照清空标记（dsh CLEARED 1:1：所有动态上下文位清空时的收尾声明）。
    static let clearedMessage = "Current runtime context: none. "
        + "Earlier runtime-context snapshots no longer apply."

    /// retained 状态：nil = 当前无保留快照（含「从未投影过」与「已影子化失效」）。
    private(set) var retained: (text: String, seq: Int)?

    /// 从事件流重建 retained（dsh 构造器扫描 + session/event 订阅的等价物；
    /// WanWo 无事件订阅缝，改为每回合注入前主动刷新）：
    /// 从尾向前找最近一条**未影子化**的归属 user/message。
    mutating func refresh(events: [SessionEvent]) {
        var shadowed = Set<Int>()
        for event in events {
            if case .compactionSummary(_, _, _, _, let seqs, _) = event.payload {
                shadowed.formUnion(seqs)
            }
        }
        for event in events.reversed() {
            guard case .userMessage(let text) = event.payload,
                  text.hasPrefix(Self.ownershipMarker) else { continue }
            if shadowed.contains(event.seq) { continue }
            retained = (text: text, seq: event.seq)
            return
        }
        retained = nil
    }

    /// 变化检测（dsh project 1:1）：返回需要注入的快照文本；nil = 无需注入。
    /// - current 为空且无保留快照 → 不注入（dsh retained === undefined 分支）。
    /// - current 为空但历史有快照 → 注入 CLEARED 清除声明。
    /// - current 与 retained 相同 → 不注入（缓存前缀稳定的关键不变量）。
    func project(_ current: String) -> String? {
        if retained == nil && current.isEmpty { return nil }
        let snapshot = current.isEmpty ? Self.clearedMessage : current
        if retained?.text == snapshot { return nil }
        return snapshot
    }

    /// 注入落盘后提交 retained（dsh session/event 订阅 user/message 分支的等价物）。
    mutating func commit(text: String, seq: Int) {
        retained = (text: text, seq: seq)
    }
}
