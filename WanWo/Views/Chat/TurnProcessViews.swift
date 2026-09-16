//
//  TurnProcessViews.swift
//  WanWo
//
//  【批2 2B 新写】轮次过程摘要行 + 轮次用量/用时 pill。
//  语义源（dsh ui-chat）：
//    · TurnProcessNodeView.tsx:7-60 —— turn-process 折叠行：计数标签段
//      （toolCalls/messages/subagents，count>0 才入列；全空 =
//      thoughtForAWhile「思考了一会儿」）+ chevron 开合。
//    · TurnUsagePanel.tsx:99-235 —— 轮次尾 pill（消耗总量）+ 点开明细 dl
//      （模型路由/缓存命中/输入/缓存读/缓存写/输出/推理）。
//  WanWo 数据面（2B 第 0 项核实结论，详见 ConversationProjector.TurnUsageSummary）：
//    · usage 分项可得（TokenUsage：uncached 输入/输出/缓存读/推理）；
//    · 模型路由（provider/model）事件流无记录 → 明细行缺席；
//    · TTFT/吞吐（decode 时长）事件流无记录 → TurnTimePanel 的 speed/ttft
//      行缺席（dsh「组缺席」语义，同 StatsLine 头注口径）；只保留 runMs 用时。
//    · cacheWrite 恒 0（mapUsage 无此桶）→ 行缺席。
//

import SwiftUI

// MARK: - 件 3：轮次过程摘要行

/// 折叠摘要行（TurnProcessNodeView 形态：标签段 + chevron；点击开合——
/// 展开内容由宿主 ChatView 渲染 group.bubbles，本视图只管行本体）。
struct TurnProcessRowView: View {
    let group: ConversationProjector.TurnProcessGroup
    let open: Bool
    let onToggle: () -> Void

    /// 标签段（:13-40 语义——计数段按序入列、全空回落「思考了一会儿」；
    /// 计数 =1 与 >1 中文同形「N 次/条」——zh locale 无复数分立）。
    private var label: String {
        var parts: [String] = []
        if group.toolCallCount > 0 { parts.append("\(group.toolCallCount) 次工具调用") }
        if group.messageCount > 0 { parts.append("\(group.messageCount) 条中间消息") }
        if group.subagentCount > 0 { parts.append("\(group.subagentCount) 个子代理") }
        return parts.isEmpty ? "思考了一会儿" : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 0 : -90))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(open ? [] : .isButton)
    }
}

// MARK: - 件 4：轮次用量/用时 pill

/// 轮次尾 pill + 明细 popover（TurnUsagePanel :108-178 形态：database icon +
/// 「已消耗 N」触发；点开 title 行 + dl 明细。用时并入触发标签——dsh
/// TurnTimePanel 是独立 pill，万我合并为单 pill 一行（呈现密度对齐 iOS 形态，
/// 偏差登记）。明细行：输入（uncached）/缓存读/缓存命中/输出（含推理小字）/
/// 用时；模型路由/缓存写/TTFT/吞吐缺席（数据不可得，见文件头注）。
struct TurnUsagePillView: View {
    let summary: ConversationProjector.TurnUsageSummary

    @State private var open = false

    /// 缓存命中占比（dsh formatCacheHitPercent：分母 = total-output =
    /// billedInput；cacheRead 缺席 → 行缺席）。
    private var cacheHitText: String? {
        guard let read = summary.cacheReadTokens, summary.billedInputTokens > 0
        else { return nil }
        return "\(Int((Double(read) / Double(summary.billedInputTokens) * 100).rounded()))%"
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "database")
                    .font(.caption2)
                Text("已消耗 \(SessionStatsFold.formatTokens(summary.totalTokens)) tok")
                    .font(.caption2.monospaced())
                if summary.runMs > 0 {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(SessionStatsFold.formatDuration(summary.runMs))
                        .font(.caption2.monospaced())
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("本轮已消耗 \(summary.totalTokens) tokens")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                // title 行（:128-134：图标 + 标题 + 精确总量）。
                HStack(spacing: 6) {
                    Image(systemName: "database").font(.footnote)
                    Text("本轮用量")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text("\(summary.totalTokens)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                Divider()
                // dl 明细（:136-172 行序语义；缺席行省略）。
                detailRow(label: "输入", value: "\(summary.inputTokens)")
                if let read = summary.cacheReadTokens {
                    detailRow(label: "缓存读", value: "\(read)")
                }
                if let hit = cacheHitText {
                    detailRow(label: "缓存命中", value: hit)
                }
                HStack(alignment: .firstTextBaseline) {
                    detailRow(label: "输出", value: "\(summary.outputTokens)")
                    if let reasoning = summary.reasoningTokens {
                        Text("（含推理 \(reasoning)）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if summary.runMs > 0 {
                    detailRow(label: "用时",
                              value: SessionStatsFold.formatDuration(summary.runMs))
                }
            }
            .padding(14)
            .frame(maxWidth: 240, alignment: .leading)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
        }
    }
}
