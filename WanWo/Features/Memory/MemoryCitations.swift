//
//  MemoryCitations.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6）：
//    - memories/read/src/citations.rs 全文 1:1 —— parse_memory_citation（多段
//      citation 聚合；<citation_entries> 逐行 rsplit_once("|note=[") + path:
//      start-end 切片；<rollout_ids> / <thread_ids> 逐行 trim 去重保序；全空 = nil）。
//    - utils/stream-parser/src/citation.rs —— <oai-mem-citation> / </oai-mem-citation>
//      标记词汇（strip_citations：整段可见文本剥离 + 载荷收集）。
//    - core/src/memory_usage.rs（经账本 recordMemoryUsage 承接——rollout_ids 命中
//      → usage_count+1 / last_usage=now 反馈环）。
//  装配缝（公开、本批不接线——派单落点⑨「解析器纯函数+公开缝」）：
//    ConversationProjector/ChatViewModel 在回合收口时以
//    MemoryCitations.extractCitations(from:) 取载荷、stripCitations(from:) 清
//    可见文本、MemoryCitations.threadIds(in:) + MemoryDatabase.recordMemoryUsage
//    回写反馈环。接线行号随交付报告呈报主理人合并（禁碰 AgentLoop 纪律）。
//

import Foundation

/// 解析产物（codex MemoryCitation / MemoryCitationEntry 1:1）。
struct MemoryCitationPayload: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var path: String
        var lineStart: Int
        var lineEnd: Int
        var note: String
    }

    var entries: [Entry]
    var rolloutIds: [String]
}

/// citation 解析纯函数集（citations.rs 1:1；无 I/O 无状态）。
enum MemoryCitations {

    /// parse_memory_citation 1:1。
    static func parse(_ citations: [String]) -> MemoryCitationPayload? {
        var entries: [Entry] = []
        var rolloutIds: [String] = []
        var seen = Set<String>()
        for citation in citations {
            if let entriesBlock = extractBlock(citation, open: "<citation_entries>",
                                               close: "</citation_entries>") {
                for line in entriesBlock.split(separator: "\n", omittingEmptySubsequences: false) {
                    if let entry = parseEntry(String(line)) { entries.append(entry) }
                }
            }
            if let idsBlock = extractIdsBlock(citation) {
                for line in idsBlock.split(separator: "\n") {
                    let id = line.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty, seen.insert(id).inserted else { continue }
                    rolloutIds.append(id)
                }
            }
        }
        if entries.isEmpty && rolloutIds.isEmpty { return nil }
        return MemoryCitationPayload(entries: entries, rolloutIds: rolloutIds)
    }

    /// rollout_ids 中可解析为 UUID 的子集（thread_ids_from_memory_citation 1:1；
    /// 万我会话 id 恒 UUID——非 UUID 形态防御性过滤）。
    static func threadIds(in payload: MemoryCitationPayload) -> [String] {
        payload.rolloutIds.filter { UUID(uuidString: $0) != nil }
    }

    /// 助手回复文本 → (可见文本, citation 载荷串列表)（strip_citations 语义：
    /// <oai-mem-citation>…</oai-mem-citation> 整段剥离；未闭合尾段按未闭合
    /// 处理=保留原文本——codex stream 解析器 auto-close 面仅流式侧，终态文本
    /// 无未闭合段）。
    static func splitCitations(from text: String) -> (visible: String,
                                                      payloads: [String]) {
        var visible = ""
        var payloads: [String] = []
        var rest = Substring(text)
        while let openRange = rest.range(of: "<oai-mem-citation>") {
            visible += rest[..<openRange.lowerBound]
            var afterOpen = rest[openRange.upperBound...]
            // 嵌套开标记不递归（citation.rs 非嵌套语义；载荷内嵌同词头按首个
            // 闭标记切片——extract_block 同口径）。
            if let closeRange = afterOpen.range(of: "</oai-mem-citation>") {
                payloads.append(String(afterOpen[..<closeRange.lowerBound]))
                rest = afterOpen[closeRange.upperBound...]
            } else {
                // 未闭合：载荷丢弃、可见文本恢复原样（终态防御）。
                visible += rest[openRange.lowerBound...]
                rest = ""
            }
        }
        visible += rest
        return (visible, payloads)
    }

    /// 提取全部 citation 载荷并解析（便捷缝）。
    static func extractCitations(from text: String) -> MemoryCitationPayload? {
        parse(splitCitations(from: text).payloads)
    }

    // MARK: - 私有（citations.rs 辅助函数 1:1）

    private static func parseEntry(_ raw: String) -> Entry? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }
        guard let noteSplit = line.range(of: "|note=[", options: .backwards) else {
            return nil
        }
        let location = String(line[..<noteSplit.lowerBound])
        var note = String(line[noteSplit.upperBound...])
        guard note.hasSuffix("]") else { return nil }
        note = String(note.dropLast()).trimmingCharacters(in: .whitespaces)
        guard let colonSplit = location.range(of: ":", options: .backwards) else {
            return nil
        }
        let path = String(location[..<colonSplit.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let lineRange = String(location[colonSplit.upperBound...])
        guard let dashSplit = lineRange.range(of: "-") else { return nil }
        guard let lineStart = Int(lineRange[..<dashSplit.lowerBound]
            .trimmingCharacters(in: .whitespaces)),
              let lineEnd = Int(lineRange[dashSplit.upperBound...]
            .trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return Entry(path: path, lineStart: lineStart, lineEnd: lineEnd, note: note)
    }

    private static func extractBlock(_ text: String, open: String, close: String) -> String? {
        guard let openRange = text.range(of: open) else { return nil }
        let rest = text[openRange.upperBound...]
        guard let closeRange = rest.range(of: close) else { return nil }
        return String(rest[..<closeRange.lowerBound])
    }

    private static func extractIdsBlock(_ text: String) -> String? {
        extractBlock(text, open: "<rollout_ids>", close: "</rollout_ids>")
            ?? extractBlock(text, open: "<thread_ids>", close: "</thread_ids>")
    }
}
