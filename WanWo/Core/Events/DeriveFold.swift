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
        self.messages = messages
    }
}
