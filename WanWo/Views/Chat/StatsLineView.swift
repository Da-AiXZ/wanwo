//
//  StatsLineView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】composer 下方状态条（T2.2 派单项 8）。
//  出处（packages/client/ui-chat/src/client/chat/StatsLine.tsx）：
//    - :1-3 —— 挂 conversation.composer.dock（随 composer 停靠，不随流滚动）。
//    - :48-79 —— deriveStats 折叠：assistant 节点计 turns（去重）/steps/llmMs
//      （step/start → assistant/message 墙钟差），tool-result 节点计 toolMs
//      （tool/call → tool/result 墙钟差）。
//    - :86-94 —— formatDuration：一分钟内 45.2s，之外 2m42s。
//    - :173-206 —— 竖线分组（「|」分隔）；无数据的组整组缺席（a group with
//      no data drops out whole）；ttft/tok/s 组在 WanWo 事件词汇（无 TTFT/
//      decode 时长记录）下恒缺席——与 dsh「组缺席」语义同形，非砍件。
//    - :191 —— 上下文占用不进状态条（home = composer 的 ContextMeter 环，
//      「one home per fact」）。
//  P1-5 缓存口径（dsh StatsLine.tsx:103-121 billedInputTokens 对齐）：分母 =
//  三桶计费输入（uncached + cacheRead + cacheWrite）；WanWo 解析层
//  inputTokens = prompt_tokens − cacheRead（即 uncached 桶）、无 cacheWrite
//  桶（恒 0）→ billed = inputTokens + cacheReadTokens。tokIn 显示与缓存命中
//  共用该分母；「输入 N」组显示计费输入（dsh :129-131 tokIn = billedInput）。
//

import SwiftUI

// MARK: - 折叠（纯函数；StatsLine.tsx:48-79 deriveStats 的 WanWo 事件词汇形态）

/// 会话统计折叠（输入 = 会话事件流全量；输出 = 展示总量）。
enum SessionStatsFold {
    struct Stats: Equatable {
        var turns = 0
        var steps = 0
        /// 请求墙钟总和（step/start → assistant/message；ms）。
        var llmMs: Int64 = 0
        /// 工具墙钟总和（tool/call → tool/result；ms）。
        var toolMs: Int64 = 0
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        /// 计费输入（dsh StatsLine.tsx:108-117 billedInputTokens 三桶口径；
        /// WanWo cacheWrite 恒 0 → uncached + cacheRead）。
        var billedInputTokens: Int { inputTokens + cacheReadTokens }
    }

    static func fold(events: [SessionEvent]) -> Stats {
        var stats = Stats()
        var stepStartTimes: [String: Int64] = [:]   // "turn:step" → timeMs
        var callTimes: [String: Int64] = [:]        // callId → timeMs
        var turnSet = Set<Int>()
        for event in events {
            switch event.payload {
            case .stepStart(let turn, let step):
                stepStartTimes["\(turn):\(step)"] = event.timeMs
            case .assistantMessage(let turn, let step, _, let usage, _):
                turnSet.insert(turn)
                stats.steps += 1
                if let started = stepStartTimes["\(turn):\(step)"] {
                    stats.llmMs += max(0, event.timeMs - started)
                }
                if let usage {
                    stats.inputTokens += usage.inputTokens
                    stats.outputTokens += usage.outputTokens
                    stats.cacheReadTokens += usage.cacheReadTokens ?? 0
                }
            case .toolCall(_, _, let callId, _, _):
                callTimes[callId] = event.timeMs
            case .toolResult(_, _, let callId, _, _, _, _, _):
                if let callTime = callTimes[callId] {
                    stats.toolMs += max(0, event.timeMs - callTime)
                }
            default:
                break
            }
        }
        stats.turns = turnSet.count
        return stats
    }

    // MARK: - 展示（:86-94 formatDuration + :173-206 分组）

    /// 45.2s / 2m42s（StatsLine.tsx:86-94 语义）。
    static func formatDuration(_ ms: Int64) -> String {
        let seconds = Double(ms) / 1_000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m\(whole % 60)s"
    }

    /// 1.2k 形态 token 缩写（dsh token-format formatTokens 的最小近似）。
    static func formatTokens(_ count: Int) -> String {
        guard count >= 1_000 else { return "\(count)" }
        let thousands = Double(count) / 1_000
        return String(format: "%.1fk", thousands)
    }

    /// 缓存命中占比（dsh cacheHitPercent：分母 = billedInputTokens；整数 <100，
    /// 否则取能保持在 100 以下的最小一位小数；无计费输入 → nil——:103-106）。
    static func cacheHitPercent(stats: Stats) -> String? {
        let billed = stats.billedInputTokens
        guard billed > 0 else { return nil }
        let percent = Double(stats.cacheReadTokens) / Double(billed) * 100
        let rounded = (percent * 10).rounded() / 10
        let display = rounded >= 100 ? 100.0 : rounded
        return display == display.rounded()
            ? "\(Int(display))%"
            : String(format: "%.1f%%", display)
    }

    /// 状态条整行（组间「 | 」；无数据组缺席；全空 → nil 不渲染——:206-208）。
    static func line(for stats: Stats) -> String? {
        var groups: [String] = []
        if stats.steps > 0 {
            groups.append("\(stats.turns) 轮 · \(stats.steps) 步")
            var durations: [String] = []
            if stats.llmMs > 0 { durations.append("LLM \(formatDuration(stats.llmMs))") }
            if stats.toolMs > 0 { durations.append("工具 \(formatDuration(stats.toolMs))") }
            if !durations.isEmpty { groups.append(durations.joined(separator: " · ")) }
            // 首 token / tok/s 组：WanWo 事件词汇无 TTFT 与 decode 时长记录，
            // 整组缺席（dsh group drops out whole——非砍件，见文件头注）。
        }
        // Billing rides the durable projection: tokIn = 计费输入
        // （billedInputTokens——dsh StatsLine.tsx:125-131 的组门与显示口径）。
        if stats.billedInputTokens > 0 || stats.outputTokens > 0 {
            if let cacheHit = cacheHitPercent(stats: stats) {
                groups.append("缓存命中 \(cacheHit)")
            }
            groups.append("输入 \(formatTokens(stats.billedInputTokens)) · "
                + "输出 \(formatTokens(stats.outputTokens))")
        }
        guard !groups.isEmpty else { return nil }
        return groups.joined(separator: " | ")
    }
}

// MARK: - 视图（composer dock）

/// 状态条（挂在 composer 之下；不随消息流滚动——dsh dock 语义）。
struct StatsLineView: View {
    let line: String

    var body: some View {
        Text(line)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityLabel("会话统计")
    }
}
