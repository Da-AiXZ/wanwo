//
//  StructuredSummarizer.swift
//  WanWo
//
//  【语义移植 · M8 批2 件B2】出处：
//    - OpenHands structured_summary_condenser.py（0.44.0）:253-262 强制手法：
//      tools=[create_state_summary] + tool_choice 硬指定；:264-293 解析——取 tool_calls
//      中名为 create_state_summary 的调用 → json.loads → StateSummary；任何解析失败
//      → warning + 空 StateSummary 兜底不中断（:289-293）
//    - Claude Code 两段式：<analysis> 草稿落库前剥离（formatCompactSummary 语义，
//      claudecode §②a "The user never sees the scratchpad"）
//    - 增量折叠：previousSummary 由 SummaryPrompt 拼入请求，只交新事件
//      （Cline agentic-compaction.ts:139-151 语义）
//    - Files 段兜底：模型没写 files_and_code / ## Files → 从 tool_use 确定性提取
//      （Cline extractFileOps compaction-shared.ts:424-461 + ensureFilesSection :659-667
//      裁剪语义；路径键 path/file_path/target_file/new_file_path/old_file_path/files/file_paths
//      :388-408）
//  LLM 调用面 = 协议注入（SummaryLLMInvoking）；OpenAICompatSummaryClient 只读消费现有
//  OpenAICompatAdapter（单轮 / thinking disabled / 输出上限 20K——claudecode §②b 工程层）。
//  tool_choice 缝已由主理人合并（M8 批2）：LLMRequest.toolChoice（LLMTypes）+
//  WireRequest.tool_choice（Adapter）全链在位，硬指定语义就位（OpenHands SSS:255-262）。
//

import Foundation

// MARK: - LLM 调用面（协议注入；调用参数工程约束在此层收口）

/// 一次摘要调用配置（claudecode §②b 工程层：单轮 / thinking 关 / 输出上限 20K）。
/// 登记见 b2-report.md §六：输出上限 20K 在本配置收口；LLM 层无 per-call 开关的
/// 部分（如 thinking 硬关在 adapter resolveThinking 语义内已达成）不重复造缝。
struct SummaryCallConfig: Sendable {
    var model: String
    var maxOutputTokens: Int = 20_000

    init(model: String, maxOutputTokens: Int = 20_000) {
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }
}

/// 摘要 LLM 回复（文本 + 工具调用并列——模型两种出路都收，解析器定优先级）。
struct SummaryLLMReply: Sendable {
    var text: String
    var toolCalls: [SummaryLLMToolCall]
}

struct SummaryLLMToolCall: Equatable, Sendable {
    var name: String
    var arguments: String
}

/// 摘要 LLM 调用面（协议注入：StructuredSummarizer 只认此协议；
/// OpenAICompatSummaryClient 为现有 adapter 的只读消费实现）。
protocol SummaryLLMInvoking: Sendable {
    /// 单轮调用（实现方保证不进入工具执行循环）。
    /// - toolChoiceName: 结构化强制意图声明（OpenHands tool_choice 硬指定语义）；
    ///   实现方若底层支持须硬指定，不支持则须原样暴露 tools 并登记。
    func complete(system: String,
                  user: String,
                  tools: [ToolSchemaEntry],
                  toolChoiceName: String?,
                  config: SummaryCallConfig) async throws -> SummaryLLMReply
}

/// OpenAICompatAdapter 只读消费实现（单轮聚合 blockEnd；thinking disabled；
/// max_tokens = config.maxOutputTokens）。
struct OpenAICompatSummaryClient: SummaryLLMInvoking, @unchecked Sendable {
    let adapter: OpenAICompatAdapter

    func complete(system: String,
                  user: String,
                  tools: [ToolSchemaEntry],
                  toolChoiceName: String?,
                  config: SummaryCallConfig) async throws -> SummaryLLMReply {
        // tool_choice 缝已由主理人合并（LLMRequest.toolChoice + WireRequest
        // .tool_choice 全链）——硬指定语义就位（OpenHands :255-262）。
        let request = LLMRequest(
            baseURL: adapter.endpoint.baseURL,
            apiKey: adapter.apiKey,
            model: config.model,
            system: system,
            messages: [ChatMessage(role: .user, content: user)],
            maxTokens: config.maxOutputTokens,
            thinking: "disabled",
            purpose: "compaction-summary",
            tools: tools,
            toolChoice: toolChoiceName.map { ToolChoice.function(named: $0) })
        var text = ""
        var toolCalls: [SummaryLLMToolCall] = []
        for try await chunk in adapter.stream(request) {
            switch chunk {
            case .blockEnd(_, let block):
                switch block {
                case .text(let blockText):
                    text += blockText
                case .toolCall(_, let name, let arguments):
                    toolCalls.append(SummaryLLMToolCall(name: name, arguments: arguments))
                case .reasoning:
                    break // reasoning 只弃不收（Cline :70-106 语义：reasoning 不进摘要）
                }
            case .finish(.error(let failure)):
                throw LLMError(message: failure.message, code: failure.code,
                               status: failure.status, causeText: failure.causeText)
            default:
                break
            }
        }
        return SummaryLLMReply(text: text, toolCalls: toolCalls)
    }
}

// MARK: - StructuredSummarizer（冻结协议 conformer）

struct StructuredSummarizer: ContextSummarizer {
    let llm: SummaryLLMInvoking
    let config: SummaryCallConfig
    /// 解析失败 warning 出口（OpenHands :289-293 warning 语义；nil = 丢弃）。
    var onWarning: (@Sendable (String) -> Void)?

    init(llm: SummaryLLMInvoking, config: SummaryCallConfig,
         onWarning: (@Sendable (String) -> Void)? = nil) {
        self.llm = llm
        self.config = config
        self.onWarning = onWarning
    }

    func summarize(serializedEvents: [String], previousSummary: String?) async -> String? {
        let reply: SummaryLLMReply
        do {
            reply = try await llm.complete(
                system: SummaryPrompt.systemPrompt,
                user: SummaryPrompt.userPrompt(previousSummary: previousSummary,
                                               serializedEvents: serializedEvents),
                tools: [StateSummary.makeToolSchema()],
                toolChoiceName: StateSummary.toolName,
                config: config)
        } catch {
            // LLM 调用失败 = 摘要失败（冻结契约 nil 语义；B1 据此走兜底链）。
            return nil
        }
        switch Self.parseReply(reply) {
        case .structured(var summary):
            // Files 段兜底（Cline :659-667 语义）：模型没写 files_and_code
            // → 从 tool_use 行确定性提取补齐。
            if summary.filesAndCode.isEmpty {
                let ops = Self.extractFileOps(serializedEvents)
                summary.filesAndCode = Self.filesSectionText(read: ops.read, edited: ops.edited)
            }
            return summary.renderMarkdown()
        case .textSummary(let text):
            let ops = Self.extractFileOps(serializedEvents)
            return Self.ensureFilesSection(text, read: ops.read, edited: ops.edited)
        case .fallbackEmpty(let reason):
            // 解析失败 = warning + 空 StateSummary 兜底渲染，不中断（OpenHands :289-293）。
            onWarning?("structured summary parse failed (\(reason)); falling back to empty state summary")
            var empty = StateSummary()
            let ops = Self.extractFileOps(serializedEvents)
            empty.filesAndCode = Self.filesSectionText(read: ops.read, edited: ops.edited)
            return empty.renderMarkdown()
        }
    }

    // MARK: 解析（纯函数；测试直测）

    enum ParseOutcome: Equatable {
        case structured(StateSummary)
        case textSummary(String)
        /// reason 供 warning；payload 为兜底空摘要语义标记。
        case fallbackEmpty(reason: String)
    }

    /// 解析优先级（结合方案双路，登记 b2-report.md §三.4）：
    /// ① tool_calls 中名为 create_state_summary 的调用（OpenHands :264-293 主路）；
    /// ② 文本路（Claude Code 两段式：剥 <analysis>、取 <summary>——NO_TOOLS_PREAMBLE
    ///    生效 / tool_choice 缺缝时的实际出路）；③ 都没有 → 兜底空摘要。
    static func parseReply(_ reply: SummaryLLMReply) -> ParseOutcome {
        if let call = reply.toolCalls.first(where: { $0.name == StateSummary.toolName }) {
            do {
                let summary = try JSONDecoder().decode(StateSummary.self,
                                                       from: Data(call.arguments.utf8))
                return .structured(summary)
            } catch {
                return .fallbackEmpty(reason: "bad create_state_summary arguments JSON: \(error.localizedDescription)")
            }
        }
        if let text = summaryText(from: reply.text) {
            return .textSummary(text)
        }
        return .fallbackEmpty(reason: "no create_state_summary tool call and no usable text")
    }

    /// 落库前剥 <analysis> 草稿、取 <summary> 正文（claudecode §②a 语义）。
    /// 未闭合 <analysis>（截断响应）→ 从开标签起全部丢弃；无 <summary> 标签 →
    /// 剥完 analysis 的剩余文本即摘要；结果空白 → nil。
    static func summaryText(from raw: String) -> String? {
        var text = raw
        if let openRange = text.range(of: "<analysis>") {
            if let closeRange = text.range(of: "</analysis>") {
                text.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                text.removeSubrange(openRange.lowerBound..<text.endIndex)
            }
        }
        if let openRange = text.range(of: "<summary>"),
           let closeRange = text.range(of: "</summary>") {
            text = String(text[openRange.upperBound..<closeRange.lowerBound])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Files 兜底提取（Cline extractFileOps :424-461 裁剪 × B1 序列化 grammar；纯函数）

    /// B1 序列化 grammar 终版（b1 二轮拍板，CondensationWorkingSet.serializedEvents）：
    /// `[seq=N] [assistant] 正文 [tool calls: name(callId) {json} | name(callId) {json}]`
    /// —— arguments = 每调用首个 `{` 起的单行 JSON（换行/制表已归一空格，单块截
    /// 2000 字符；截断切尾可能坏 JSON → 解析失败自然落回空路径/裸 id 分类）。
    /// 现行无 `{` 的条目（旧形态纯 callId）arguments = ""。
    /// 段收尾 = 行内最后一个 `]`（JSON 内可含 `]`，首个会切早）；条目按 " | " 分隔
    /// （JSON 内 ", " 常见、竖线罕见——残余撞串由 bare-callId/JSON 判定兜底，B1 登记 #14）。
    static func toolCallEntries(fromLine line: String) -> [(name: String, arguments: String)] {
        guard let start = line.range(of: "[tool calls: "),
              let end = line.range(of: "]", options: .backwards,
                                   range: start.upperBound..<line.endIndex)
        else { return [] }
        let body = String(line[start.upperBound..<end.lowerBound])
        var entries: [(name: String, arguments: String)] = []
        for rawPiece in body.components(separatedBy: " | ") {
            let piece = rawPiece.trimmingCharacters(in: .whitespaces)
            guard let open = piece.firstIndex(of: "("),
                  let close = piece.firstIndex(of: ")"), open < close else { continue }
            let name = String(piece[piece.startIndex..<open])
            // arguments = 首个 `{` 起的 JSON（只出现在 args 区；无则视为纯 callId 旧形态）
            if let brace = piece.firstIndex(of: "{") {
                entries.append((name: name, arguments: String(piece[brace...])))
            } else {
                entries.append((name: name, arguments: ""))
            }
        }
        return entries
    }

    /// 扫描 tool-calls 段：read 类名含 "read" → read；含 edit/write/apply_patch
    /// → edited；路径从 arguments（`{` 起单行 JSON）按 path/file_path/target_file/
    /// new_file_path/old_file_path + files/file_paths 键收集（Cline :388-408 键表），
    /// 去重保序；截断切尾的坏 JSON 解析不出键 → 自然为空（B1 2000 cap 语义）。
    static func extractFileOps(_ serializedEvents: [String]) -> (read: [String], edited: [String]) {
        var read: [String] = []
        var edited: [String] = []
        for event in serializedEvents {
            for line in event.split(separator: "\n", omittingEmptySubsequences: false) {
                for entry in toolCallEntries(fromLine: String(line)) {
                    let name = entry.name.lowercased()
                    let paths = extractPaths(from: entry.arguments)
                    guard !paths.isEmpty else { continue }
                    if name.contains("read") {
                        read.append(contentsOf: paths)
                    } else if name.contains("edit") || name.contains("write")
                                || name.contains("apply_patch") {
                        edited.append(contentsOf: paths)
                    }
                }
            }
        }
        return (dedupPreservingOrder(read), dedupPreservingOrder(edited))
    }

    /// 路径键提取（:388-408 键表语义）。
    static func extractPaths(from arguments: String) -> [String] {
        var paths: [String] = []
        let stringKeys = "path|file_path|target_file|new_file_path|old_file_path"
        if let regex = try? NSRegularExpression(pattern: "\"(\(stringKeys))\"\\s*:\\s*\"([^\"]*)\"") {
            let ns = arguments as NSString
            for match in regex.matches(in: arguments, range: NSRange(location: 0, length: ns.length)) {
                let value = ns.substring(with: match.range(at: 2))
                if !value.isEmpty { paths.append(value) }
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\"(?:files|file_paths)\"\\s*:\\s*\\[([^\\]]*)\\]") {
            let ns = arguments as NSString
            for match in regex.matches(in: arguments, range: NSRange(location: 0, length: ns.length)) {
                let arrayBody = ns.substring(with: match.range(at: 1))
                let itemRegex = try? NSRegularExpression(pattern: "\"([^\"]*)\"")
                let itemNS = arrayBody as NSString
                for item in itemRegex!.matches(in: arrayBody,
                                               range: NSRange(location: 0, length: itemNS.length)) {
                    let value = itemNS.substring(with: item.range(at: 1))
                    if !value.isEmpty { paths.append(value) }
                }
            }
        }
        return dedupPreservingOrder(paths)
    }

    private static func dedupPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Files 段文本 / ensureFilesSection（Cline :647-657, :659-667 裁剪）

    static func filesSectionText(read: [String], edited: [String]) -> String {
        "Read: \(read.isEmpty ? "none" : read.joined(separator: ", "))\n"
        + "Edited: \(edited.isEmpty ? "none" : edited.joined(separator: ", "))"
    }

    /// 文本路摘要没有文件段时追加确定性 Files 清单（ensureFilesSection 语义）。
    static func ensureFilesSection(_ text: String, read: [String], edited: [String]) -> String {
        if text.contains("## Files") { return text }
        return text + "\n\n## Files\n" + filesSectionText(read: read, edited: edited)
    }
}
