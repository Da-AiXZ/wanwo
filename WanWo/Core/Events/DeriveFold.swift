//
//  DeriveFold.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/session（deriveMessages：从事件流派生
//  模型可见历史）+ compaction 折叠语义（影子范围由 compaction/summary 取代）。
//  规则（与 Compactor.estimateSession 同一折叠，保证计量与消费一致）：
//    · compaction/summary 声明的影子 seq 全部跳过；summary 在原位置以
//      `<compaction-summary>` user 消息呈现
//    · tool/result 同 callId 取最后一条（prune 替换节点生效、原节点丢弃）
//    · user/message → user；assistant/message → assistant（含 tool_calls）；
//      tool/result → tool（tool_call_id）
//

import Foundation

/// 派生历史折叠器（纯函数；model-visible = logged 的消费侧）。
struct DeriveFold {
    let messages: [ChatMessage]

    init(_ events: [SessionEvent]) {
        // 1. 影子范围（压缩摘要取代的历史节点）。
        var shadowed = Set<Int>()
        for event in events {
            if case .compactionSummary(_, _, _, _, let seqs, _) = event.payload {
                shadowed.formUnion(seqs)
            }
        }

        // 2. 每个 callId 的最新（未影子）tool/result seq——last-wins。
        var latestResultSeq: [String: Int] = [:]
        for event in events where !shadowed.contains(event.seq) {
            if case .toolResult(_, _, let callId, _, _, _, _, _) = event.payload {
                latestResultSeq[callId] = max(latestResultSeq[callId] ?? -1, event.seq)
            }
        }

        // 3. 线性折叠。
        var messages: [ChatMessage] = []
        for event in events {
            if shadowed.contains(event.seq) { continue }
            switch event.payload {
            case .userMessage(let text):
                messages.append(ChatMessage(role: .user, content: text))
            case .assistantMessage(_, _, let message, _, _):
                let text = message.content.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined()
                let calls = message.content.compactMap { block -> ToolCallSpec? in
                    if case .toolCall(let id, let name, let arguments) = block {
                        return ToolCallSpec(id: id, name: name, arguments: arguments)
                    }
                    return nil
                }
                messages.append(ChatMessage(role: .assistant, content: text,
                                            toolCalls: calls.isEmpty ? nil : calls))
            case .toolResult(_, _, let callId, let content, let isError, _, _, _):
                guard latestResultSeq[callId] == event.seq else { continue }
                let contentText = isError ? content : content
                messages.append(ChatMessage(role: .tool, content: contentText,
                                            toolCallID: callId))
            case .compactionSummary(_, let summary, _, _, _, _):
                messages.append(ChatMessage(
                    role: .user,
                    content: "<compaction-summary>\n\(summary)\n</compaction-summary>"))
            default:
                break
            }
        }
        // 4. 出口防御（ERR-017）：剔除孤立 tool 消息——其前面不存在带匹配
        //    tool_call_id 的 assistant 时，OpenAI 兼容端点直接 400。正常序列
        //    由 Compactor 的边界平衡保证；此处兜底历史遗留/异常切分。
        var safe: [ChatMessage] = []
        var openCallIds = Set<String>()
        for message in messages {
            if let calls = message.toolCalls, !calls.isEmpty {
                for call in calls { openCallIds.insert(call.id) }
                safe.append(message)
                continue
            }
            if message.role == .tool {
                guard let id = message.toolCallID, openCallIds.contains(id) else { continue }
                safe.append(message)
                continue
            }
            // 非 tool 结果的普通消息（user/assistant 无调用）关闭所有未决对——
            // 中间隔了普通消息的 result 已不被 API 接受，同样按孤立处理。
            openCallIds.removeAll()
            safe.append(message)
        }
        // 5. 出口防御（ERR-021 反向）：assistant(tool_calls) 的某 callId 若无后续
        //    匹配 tool 消息（丢 result / 执行中断截断），合成错误 tool 消息补齐
        //    配对——与步骤 4 的孤立 tool 剔除方向对称，任何上游缺口都不会再产生
        //    "insufficient tool messages" 400。
        var paired: [ChatMessage] = []
        var index = 0
        while index < safe.count {
            let message = safe[index]
            paired.append(message)
            index += 1
            guard let calls = message.toolCalls, !calls.isEmpty else { continue }
            // 紧随其后的连续 tool 消息已回答的 callId 集合。
            var answered = Set<String>()
            var cursor = index
            while cursor < safe.count, safe[cursor].role == .tool,
                  let id = safe[cursor].toolCallID {
                answered.insert(id)
                cursor += 1
            }
            for call in calls where !answered.contains(call.id) {
                paired.append(ChatMessage(
                    role: .tool,
                    content: "tool execution was interrupted before completion",
                    toolCallID: call.id))
            }
        }
        self.messages = paired
    }
}
