//
//  SessionNotesHooks.swift
//  WanWo
//
//  【语义移植 · Cline Memory Bank · M8 批2 件 B3】更新触发缝（Cline 四条件
//  内核化的 b/c 两路——本批只交付协议+实现函数，不接生产，登记）。
//
//  缝需求（呈报主理人合并——citation 缝先例，AppEnvironment 本批不改）：
//
//  b) 压缩联动缝（供 B1 铺设调用方）：B1 压缩落地（CondensationRecord 落
//     tombstone）后调用 `SessionNotesRecorder.sessionNotesDidCompact(summary:)`，
//     summary = B2 StructuredSummary 的渲染文本（或 basic 兜底摘要——同签名
//     承载）。实现 = activeContext.md 全文重写为该摘要（activeContext 语义
//     = "当前工作焦点"，最新态覆盖旧态，与 Cline 模型全文改写同构——登记）。
//
//  c) 回合收尾缝（供 B1 在 AgentLoop 铺设回合收尾观察缝后接线）：观察缝签名
//     需求 = (assistant 文本回复 digest, 本回合触及的 guest 文件路径表)；B1
//     缝若形态不同，由接线方归一成本结构（归一逻辑属接线批）。实现 = 向
//     activeContext.md 尾部追加观察块（头标记保留，追加式小更新——Cline
//     "每会话后必更 activeContext"（memory-bank.mdx :39, :70）的确定性等价）。
//
//  显式命令面（条件 3"update memory bank"全量复审）由调用方对五文件逐件
//  applyNoteUpdate 承载（SessionNotesStore 件头注映射表）——工具/UI 另批。
//

import Foundation

/// 回合收尾观察载荷（缝签名见件头注 c 项）。
struct SessionNotesTurnObservation: Sendable, Equatable {
    /// 最近一条 assistant 文本回复摘要（调用方负责 digest 化——本批不裁剪语义，
    /// 仅在写入时按 turnObservationCharLimit 截断防膨胀）。
    var assistantReplyDigest: String?
    /// 本回合触及的 guest 文件路径（读/写）。
    var filesTouched: [String]
}

/// 压缩联动缝协议（B1 压缩落地后的调用面；实现见 SessionNotesRecorder）。
protocol SessionNotesCompactionHook: Sendable {
    /// 把压缩派生摘要写进 activeContext（全文重写，头标记由 Recorder 补齐）。
    func sessionNotesDidCompact(summary: String) throws
}

/// 回合收尾缝协议（B1 AgentLoop 回合收尾观察缝的消费面）。
protocol SessionNotesTurnHook: Sendable {
    /// 回合收尾小更新：向 activeContext 尾部追加观察块。
    func sessionNotesOnTurnEnd(_ observation: SessionNotesTurnObservation) throws
}

/// 两缝实现（薄壳持 store；不接生产——接线指令见 b3-report.md §缝需求）。
struct SessionNotesRecorder: SessionNotesCompactionHook, SessionNotesTurnHook {
    let store: SessionNotesStore

    /// b) 压缩联动：activeContext 全文重写 = 头标记 + 摘要正文。
    func sessionNotesDidCompact(summary: String) throws {
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.applyNoteUpdate(
            file: .activeContext,
            content: SessionNotesHeader.marker(for: .activeContext) + "\n" + body)
    }

    /// c) 回合收尾：读现正文 → 尾部追加观察块 → 全文重写（头标记保留校验
    /// 照走 applyNoteUpdate 单一写入闸）。读失败（文件缺失/空）时从空正文起步。
    func sessionNotesOnTurnEnd(_ observation: SessionNotesTurnObservation) throws {
        let current = store.readBody(.activeContext) ?? ""
        var lines: [String] = []
        if let digest = observation.assistantReplyDigest?
            .trimmingCharacters(in: .whitespacesAndNewlines), !digest.isEmpty {
            lines.append("回复摘要：" + Self.truncate(digest,
                                                     SessionNotesConstants.turnObservationCharLimit))
        }
        if !observation.filesTouched.isEmpty {
            lines.append("触及文件：" + observation.filesTouched.joined(separator: ", "))
        }
        guard !lines.isEmpty else { return }
        let block = (current.isEmpty ? "" : current + "\n\n")
            + lines.joined(separator: "\n")
        try store.applyNoteUpdate(
            file: .activeContext,
            content: SessionNotesHeader.marker(for: .activeContext) + "\n" + block)
    }

    /// 字符截断（超限追加省略尾注）。
    static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…（已截断）"
    }
}
