//
//  BasicFallback.swift
//  WanWo
//
//  【语义移植 · M8 批2 件B2】出处：Cline basic-compaction.ts（无 LLM 截断折叠，
//  cline-deepread.md §2.4/:81-93/:452-711 语义，裁剪适配登记见 b2-report.md §三.5/§八）：
//    - typed user prompt 全保留（:472-498）
//    - 上一轮压缩产物冻结不再折叠（compaction:"preserved" :395-421——previousSummary
//      参数与事件流内 `[previous summary id]` 行均原样保留，不进折叠/改写）
//    - 最近 3 条 assistant 文本回复原样并入 <SYSTEM_NOTICE> 回填块（:81-93，
//      PRESERVED_ASSISTANT_TEXT_COUNT=3 :61）
//    - dropped-work 摘要：读过的文件 / 编辑的文件 / 跑过的命令截 100 字符
//      （summarizeToolActivity compaction-shared.ts:561-635；命令截断 :464, :492-497）
//    - thinking 块丢弃（basic :428-441；B1 序列化不产 thinking 行，天然满足）
//  serializedEvents grammar = B1 CondensationWorkingSet.serializedEvents（b1 对齐消息
//  第 4 条）：`[seq=N] [user|assistant|tool result callId|previous summary id] 正文`，
//  单事件上限 10_000 字符（B1 hard reset ×0.8 递减承载，B2 侧无需处理）。
//  平台适配登记：Cline basic 重建消息数组；万我冻结契约返回单条摘要字符串——
//  preserved users + SYSTEM_NOTICE 回填块按序拼入该字符串（语义等价，登记）。
//

import Foundation

/// 无 LLM 兜底摘要器（冻结协议第二 conformer；LLM 摘要失败时由装配组合 conformer 调用）。
struct BasicFallbackSummarizer: ContextSummarizer {
    /// 最近 assistant 文本回复保留条数（Cline PRESERVED_ASSISTANT_TEXT_COUNT）。
    static let preservedAssistantTextCount = 3
    /// 命令截断长度（Cline :464）。
    static let commandCharLimit = 100

    func summarize(serializedEvents: [String], previousSummary: String?) async -> String? {
        Self.fold(serializedEvents: serializedEvents, previousSummary: previousSummary)
    }

    // MARK: 折叠（纯函数；测试直测）

    /// nil = 无可折叠内容（B1 对 nil 统一计熔断；本函数绝不返回空串——空串按
    /// nil 语义处理，b1 对齐消息第 5 条）。
    static func fold(serializedEvents: [String], previousSummary: String?) -> String? {
        var users: [String] = []
        var assistantTexts: [String] = []
        var frozenSummaries: [String] = [] // 事件流内旧摘要行（上轮产物冻结语义）
        var toolCallLines: [String] = []

        for event in serializedEvents {
            for line in event.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(line)
                switch roleToken(of: line) {
                case "user":
                    users.append(line) // typed user prompt 全保留（:472-498）
                case "assistant":
                    assistantTexts.append(line)
                case .some(let role) where role.hasPrefix("tool result"):
                    continue // 结果正文不回填；痕迹由 assistant 行 tool-calls 段承载
                case .some(let role) where role.hasPrefix("previous summary"):
                    frozenSummaries.append(line) // 上轮产物冻结（:395-421）
                case .some:
                    continue // 未知角色（保守丢弃；登记）
                case .none:
                    // 非 grammar 行：assistant 文本保守保留（登记）。
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        assistantTexts.append(line)
                    }
                }
            }
        }
        // assistant 行可能带 `[tool calls: …]` 段（dropped-work 来源）。
        toolCallLines = assistantTexts.filter { $0.contains("[tool calls: ") }

        let dropped = summarizeToolActivity(toolCallLines: toolCallLines)
        let preservedReplies = Array(assistantTexts.suffix(preservedAssistantTextCount))
        let notice = systemNotice(dropped: dropped, assistantReplies: preservedReplies)

        var sections: [String] = []
        // 上轮压缩产物冻结：previousSummary 参数与事件流旧摘要行原样置顶
        // （:395-421）；空白（全空格/换行）视同无摘要（skipped 语义——
        // 空白置顶只会产出纯空白产物，违背「无内容不压」）。
        if let previousSummary,
           !previousSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(previousSummary)
        }
        sections.append(contentsOf: frozenSummaries)
        if let notice {
            sections.append(notice)
        }
        sections.append(contentsOf: users)
        if sections.isEmpty { return nil } // 无可折叠内容 = 本次不压（Cline :635-637 skipped 语义）
        return sections.joined(separator: "\n\n")
    }

    /// B1 grammar 角色解析：`[seq=N] [ROLE …] 正文` → ROLE 段（非 grammar 行 → nil）。
    static func roleToken(of line: String) -> String? {
        guard line.hasPrefix("[seq="), let seqClose = line.firstIndex(of: "]") else { return nil }
        var rest = line[line.index(after: seqClose)...]
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        guard rest.hasPrefix("["), let roleClose = rest.firstIndex(of: "]") else { return nil }
        return String(rest[rest.index(after: rest.startIndex)..<roleClose])
    }

    // MARK: dropped-work 提取（summarizeToolActivity :561-635 裁剪 × B1 grammar；纯函数）

    struct DroppedWork: Equatable {
        var filesRead: [String]
        var filesEdited: [String]
        var commands: [String]
    }

    static func summarizeToolActivity(toolCallLines: [String]) -> DroppedWork {
        var work = DroppedWork(filesRead: [], filesEdited: [], commands: [])
        for line in toolCallLines {
            for entry in StructuredSummarizer.toolCallEntries(fromLine: line) {
                let name = entry.name.lowercased()
                let arguments = entry.arguments
                if name.contains("bash") || name.contains("command") || name.contains("run")
                    || name.contains("exec") || name.contains("terminal") {
                    // 跑过的命令：截 100 字符（:464, :492-497）。抽值口径（B1 拍板，
                    // b1-report §五【B2 口径·命令表抽值】；键名事实源 = WanWo
                    // ShellTool.swift:65,71——命令参数名 `command` required，非自创）：
                    // arguments 可按 JSON 解析且有 `command` 字符串值 → 取值截 100；
                    // 解析失败/无 `command` 键 → 回落 arguments 原文截 100。
                    if let command = commandText(fromArguments: arguments) {
                        work.commands.append(String(command.prefix(commandCharLimit)))
                        continue
                    }
                    // 回落：原文截 100（bare-callId/空 args guard 保留防污染）。
                    let isBareCallID = !arguments.contains(" ")
                        && !arguments.contains("{") && !arguments.contains("\"")
                    if !arguments.isEmpty && !isBareCallID {
                        let command = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                        work.commands.append(String(command.prefix(commandCharLimit)))
                    }
                    continue
                }
                let paths = StructuredSummarizer.extractPaths(from: arguments)
                guard !paths.isEmpty else { continue }
                if name.contains("read") {
                    work.filesRead.append(contentsOf: paths)
                } else if name.contains("edit") || name.contains("write") || name.contains("apply_patch") {
                    work.filesEdited.append(contentsOf: paths)
                }
            }
        }
        work.filesRead = dedupPreservingOrder(work.filesRead)
        work.filesEdited = dedupPreservingOrder(work.filesEdited)
        work.commands = dedupPreservingOrder(work.commands)
        return work
    }

    /// 命令值抽取（B1 拍板口径；键名事实源 ShellTool.swift:65,71）：
    /// arguments 按 JSON 解析为 object 且 `command` 键为非空字符串 → 返回该值；
    /// 解析失败/无 `command` 键/空值 → nil（调用侧回落原文截 100）。只认
    /// `command` 一个键——万我无 `cmd` 参数名，发明第二键名才是自创。
    static func commandText(fromArguments arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = object["command"] as? String
        else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: <SYSTEM_NOTICE> 回填块（basic-compaction.ts:81-93 语义；纯函数）

    /// 空 dropped-work 且无 assistant 回复 → nil（无事可回填）。
    static func systemNotice(dropped: DroppedWork, assistantReplies: [String]) -> String? {
        let hasWork = !dropped.filesRead.isEmpty || !dropped.filesEdited.isEmpty
            || !dropped.commands.isEmpty
        guard hasWork || !assistantReplies.isEmpty else { return nil }
        var lines = [
            "<SYSTEM_NOTICE>",
            "Earlier context was compacted. Summary of your actions after the request above:",
            "Files read: \(dropped.filesRead.isEmpty ? "none" : dropped.filesRead.joined(separator: ", "))",
            "Files edited: \(dropped.filesEdited.isEmpty ? "none" : dropped.filesEdited.joined(separator: ", "))",
            "Commands ran: \(dropped.commands.isEmpty ? "none" : dropped.commands.joined(separator: ", "))",
        ]
        // 最近 assistant 文本回复原样并入（:81-93 语义；B1 grammar 行带 seq 标注原样保留）。
        for reply in assistantReplies where !reply.isEmpty {
            lines.append(reply)
        }
        lines.append("</SYSTEM_NOTICE>")
        return lines.joined(separator: "\n")
    }

    private static func dedupPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
