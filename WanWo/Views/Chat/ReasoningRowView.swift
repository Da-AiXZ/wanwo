//
//  ReasoningRowView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · P2-⑬】思考披露行。
//  出处（packages/client/ui-chat/src/client/chat/ReasoningRow.tsx 全量 1:1）：
//    - :26-28 —— 默认折叠（expanded 初始 false）；summary = running 时取
//      latestLine（尾行跟随流式），完成后取 firstLine（首行）。
//    - :38-48 —— DisclosureRow：icon + title「思考」（ui-chat locale.ts:66
//      message.think zh 逐字）+ 行点击展开/收起 + chevron。
//    - :49-58 —— 折叠态附 summary 行；展开态 = 正文全文（thinkBody）。
//    - running 态（ui-chat locale.ts:113 row.running「运行中」）——WanWo 以
//      触发行的进行中指示（图标色/旋转）承载，不渲染独立 aria 行（B 级形态
//      偏差，随 M9 无障碍批次登记）。
//

import SwiftUI

/// 思考披露行（Think disclosure）：折叠 = 标题 + 摘要行；展开 = 全文。
struct ReasoningRowView: View {
    /// 完整或流式中的思考文本。
    let text: String
    /// 是否为流式尾块（dsh running——尾行跟随）。
    var running: Bool

    @State private var expanded = false

    // MARK: - 摘要（dsh :8-17 firstLine/latestLine 1:1）

    /// 首行（完成态摘要）。
    static func firstLine(_ text: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[..<newline])
    }

    /// 尾行（流式态摘要——dsh latestLine 1:1：trimEnd 后最后一个换行之后）。
    static func latestLine(_ text: String) -> String {
        let visible = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
        guard let newline = visible.lastIndex(of: "\n") else { return visible }
        return String(visible[visible.index(after: newline)...])
    }

    private var summary: String {
        running ? Self.latestLine(text) : Self.firstLine(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 披发行头（dsh DisclosureRow：icon + title + chevron；整行可点）。
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("思考")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                    if running {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 折叠态摘要行（dsh collapsedContent：分隔 + summary 尾随）。
            if !expanded {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 12, height: 0.5)
                        .padding(.trailing, 8)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // 展开态全文（dsh thinkBody）。
            if expanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
        .accessibilityLabel(expanded ? "思考已展开" : "思考已折叠")
    }
}
