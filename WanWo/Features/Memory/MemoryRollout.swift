//
//  MemoryRollout.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6）：
//    - memories/write/src/phase1.rs :406-490 —— serialize_filtered_rollout_response_items
//      + sanitize_response_item_for_memories + is_memory_excluded_contextual_user_fragment
//      + matches_marked_fragment 逐语义（developer 角色剔除；"# AGENTS.md instructions
//      …</INSTRUCTIONS>" 与 "<skill>…</skill>" marker 块剔除；序列化整体 redact_secrets）。
//    - memories/write/src/prompts.rs :102-127 —— build_stage_one_input_message
//      （rollout token 限额 = 有效上下文窗 ×70% 的 70%？否——chain：limit×70%×70%？
//      逐行对拍：limit×effective_context_window_percent/100 再 ×CONTEXT_WINDOW_PERCENT/100，
//      无窗元数据回落 DEFAULT_ROLLOUT_TOKEN_LIMIT；模板 render 三占位符）。
//    - memories/write/src/phase1.rs :136-148 —— output_schema() 逐字。
//  万我适配（登记）：
//    - 输入源：codex rollout 文件 ResponseItem 流 → 万我会话事件流映射：
//        · userMessage(text)      → {"type":"message","role":"user","content":[{type:"input_text",text}]}
//        · assistantMessage       → {"type":"message","role":"assistant","content":[…]}（ContentBlock → output_text/reasoning 文本）
//        · toolCall               → {"type":"function_call","call_id","name","arguments"}
//        · toolResult             → {"type":"function_call_output","call_id","output":content}
//      assistantChunk（token 级重放行）与 log-only 事件不入序列——codex
//      should_persist_response_item_for_memories「model-visible 才入」同语义。
//    - developer 角色：万我事件词汇无 developer 角色；system 注入面（上下文快照/
//      教学段）以 user 消息形态出现的 marker 块由 isMemoryExcludedFragment 剔除
//      （codex 侧 developer 剔除的拓扑等价承载，登记）。
//    - token 截断：codex truncate_text Tokens(p) 用 tiktoken 计数；万我以
//      utf8 字节/4 估算 token（中英混合 rollout 误差 <±20%，截断语义=保头尾不变，
//      登记）。
//

import Foundation

/// rollout 过滤序列化 + stage-1 输入消息构造（phase1.rs job 段 + prompts.rs 移植）。
enum MemoryRollout {

    // MARK: - 过滤序列化（serialize_filtered_rollout_response_items）

    /// 会话事件流 → 过滤后的 ResponseItem JSON 数组字符串（整体 redact）。
    /// 空序列返回空数组字符串（非 nil——codex 侧空 rollout 同样产出 "[]"）。
    static func serializeFilteredEvents(_ events: [SessionEvent]) -> String {
        var items: [JSONValue] = []
        for event in events {
            switch event.payload {
            case .userMessage(let text):
                // user 内容项过滤（is_memory_excluded_contextual_user_fragment）。
                if isMemoryExcludedFragment(text) { continue }
                items.append(userMessageItem(text: text))
            case .assistantMessage(_, _, let message, _, _):
                // assistant 聚合消息（中断标记不改变模型可见内容——codex 无此维度）。
                let blocks = message.content.compactMap { block -> JSONValue? in
                    switch block {
                    case .text(let text):
                        return .object(["type": .string("output_text"), "text": .string(text)])
                    case .reasoning(let text):
                        return .object(["type": .string("reasoning"), "text": .string(text)])
                    default:
                        return nil
                    }
                }
                guard !blocks.isEmpty else { continue }
                items.append(.object([
                    "type": .string("message"),
                    "role": .string("assistant"),
                    "content": .array(blocks),
                ]))
            case .toolCall(_, _, let callId, let name, let arguments):
                items.append(.object([
                    "type": .string("function_call"),
                    "call_id": .string(callId),
                    "name": .string(name),
                    "arguments": .string(arguments),
                ]))
            case .toolResult(_, _, let callId, let content, _, _, _, _):
                items.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(callId),
                    "output": .string(content),
                ]))
            default:
                // SessionMeta/compaction/command/approval/log-only 等不入
                // （codex RolloutItem 非 ResponseItem 臂 + 非 model-visible 同裁）。
                continue
            }
        }
        return MemoryRedactor.redact(Self.serializeJSON(.array(items)))
    }

    /// JSONValue → JSON 文本（JSONValue.encode 确定性键序；compact）。
    static func serializeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// user 消息项（codex ResponseItem::Message user 形态 1:1）。
    private static func userMessageItem(text: String) -> JSONValue {
        .object([
            "type": .string("message"),
            "role": .string("user"),
            "content": .array([.object([
                "type": .string("input_text"),
                "text": .string(text),
            ])]),
        ])
    }

    /// is_memory_excluded_contextual_user_fragment 1:1（两个 marker 块）。
    static func isMemoryExcludedFragment(_ text: String) -> Bool {
        matchesMarkedFragment(text, start: "# AGENTS.md instructions", end: "</INSTRUCTIONS>")
            || matchesMarkedFragment(text, start: "<skill>", end: "</skill>")
    }

    /// matches_marked_fragment 1:1：trim-start 后以前缀开头（ASCII 不区分大小写）
    /// 且 trim-end 后以后缀结尾。
    static func matchesMarkedFragment(_ text: String, start: String, end: String) -> Bool {
        let trimmedStart = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard trimmedStart.utf8.count >= start.utf8.count,
              trimmedStart.prefix(start.count).lowercased() == start.lowercased() else {
            return false
        }
        let trimmedEnd = trimmedStart.reversed().drop(while: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }).reversed()
        guard trimmedEnd.utf8.count >= end.utf8.count,
              trimmedEnd.suffix(end.count).lowercased() == end.lowercased() else {
            return false
        }
        return true
    }

    // MARK: - stage-1 输入消息（build_stage_one_input_message）

    /// Phase1 输出 JSON schema（phase1.rs output_schema 逐字；strict=true 面由
    /// MemoryStage1Output 严格解码承接）。
    static let outputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "rollout_summary": .object(["type": .string("string")]),
            "rollout_slug": .object(["type": .array([.string("string"), .string("null")])]),
            "raw_memory": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("rollout_summary"), .string("rollout_slug"),
                            .string("raw_memory")]),
        "additionalProperties": .bool(false),
    ])

    /// build_stage_one_input_message 1:1：rollout token 限额 =
    /// contextWindow × CONTEXT_WINDOW_PERCENT /100（无窗元数据回落
    /// DEFAULT_ROLLOUT_TOKEN_LIMIT）；截断保头尾；模板 render 三占位符。
    /// - Parameters:
    ///   - contextWindowTokens: 模型有效上下文窗（nil/0 = 无元数据 → 回落缺省）。
    ///   - rolloutPath/rolloutCwd: 会话事实源路径（万我 = sessions/<id>.jsonl 与 header.cwd）。
    static func buildStageOneInputMessage(rolloutContents: String,
                                          rolloutPath: String,
                                          rolloutCwd: String,
                                          contextWindowTokens: Int?) -> String {
        let resolvedWindow = contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
        let tokenLimit = resolvedWindow
            .map { $0 * MemoryConstants.contextWindowPercent / 100 }
            .map { max($0, 1) }
            ?? MemoryConstants.defaultRolloutTokenLimit
        let truncated = truncateToTokenEstimate(rolloutContents, tokenLimit)
        return MemoryTemplates.render(MemoryTemplates.stageOneInput, [
            ("rollout_path", rolloutPath),
            ("rollout_cwd", rolloutCwd),
            ("rollout_contents", truncated),
        ])
    }

    /// token 估算截断（codex TruncationPolicy::Tokens 保头尾语义；万我估算 =
    /// utf8 字节/4，登记）。头部保留 ceil(2/3)、尾部保留余量——codex truncate_text
    /// 保头 2/3 尾 1/3 口径。
    static func truncateToTokenEstimate(_ text: String, _ tokenLimit: Int) -> String {
        let bytes = Array(text.utf8)
        let estimated = bytes.count / 4
        guard estimated > tokenLimit else { return text }
        // 目标字节数 = tokenLimit × 4；head 2/3 + tail 1/3。
        let budget = max(tokenLimit * 4 - 64, 64)
        let headBytes = budget * 2 / 3
        let tailBytes = budget - headBytes
        func headPrefix(_ count: Int) -> String {
            var slice = bytes.prefix(count)
            // 对齐 UTF-8 边界（退到边界字节）。
            while let last = slice.last, last & 0b1100_0000 == 0b1000_0000 { slice.removeLast() }
            return String(decoding: slice, as: UTF8.self)
        }
        func tailSuffix(_ count: Int) -> String {
            var slice = Array(bytes.suffix(count))
            while let first = slice.first, first & 0b1100_0000 == 0b1000_0000 { slice.removeFirst() }
            return String(decoding: slice, as: UTF8.self)
        }
        return headPrefix(headBytes) + "\n…[truncated]…\n" + tailSuffix(tailBytes)
    }
}
