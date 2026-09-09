//
//  SlashMenuView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】composer 命令菜单（T2.2 派单项 7）。
//  出处：
//    - ui-conversation/src/client/skeleton/InputBar.tsx:441-454 —— 「+」按钮
//      打开命令菜单（非附件）：aria-label = input.commands =「指令」。
//    - ui-input-trigger/src/client/MenuView.tsx:37-189 —— slash 菜单交互
//      （combobox：焦点不离开输入框；行 = 名称 + 描述；MAX_HEIGHT 320 设计上限
//      :25；点外关闭：菜单与 composer 卡之外——:59-72；手输 "/" 即过滤）。
//    - ui-commands/src/client/PopupSelectView.tsx:21-22 —— 同 MenuDropdown 家族
//      设计上限 MAX_HEIGHT = 320。
//  WanWo 形态：SwiftUI 无焦点保留需求（TextField 恒可编辑），菜单以浮动卡片
//  呈现于 composer 上方；选择 = 写回 claim token "/name "（dsh claim token
//  带尾随空格，InputBar.tsx:346 注释「/name 」格式）。
//

import SwiftUI

/// composer 命令菜单（+ 按钮与 "/" 触发共用一菜单——dsh onToggleCommandMenu）。
struct SlashMenuView: View {
    /// 当前过滤词（"" = 全列；"/np" 前缀过滤——MenuView 查询细化语义）。
    let query: String
    let commands: [SlashCommandRegistry.Command]
    let onPick: (SlashCommandRegistry.Command) -> Void
    let onDismiss: () -> Void

    /// 设计高度上限（MenuView.tsx:25 / PopupSelectView.tsx:22 MAX_HEIGHT 320）。
    private let maxHeight: CGFloat = 320

    private var filtered: [SlashCommandRegistry.Command] {
        let prefix = query.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return commands }
        return commands.filter { "/\($0.name)".hasPrefix(prefix) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 滚动列表（高度上限 320）。
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if filtered.isEmpty {
                        Text("无匹配指令")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(filtered, id: \.name) { command in
                        Button {
                            onPick(command)
                        } label: {
                            // 行 = 名称 + 描述（MenuView.tsx 行形态）。
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("/\(command.name)")
                                    .font(.footnote.monospaced().weight(.semibold))
                                Text(command.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
        .frame(maxWidth: 420)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityLabel("指令菜单")
    }
}
