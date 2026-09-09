//
//  PermissionSelectView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】composer 权限挡位下拉（权限入口①）。
//  出处（packages/client/ui-conversation/src/client/skeleton/PermissionSelect.tsx）：
//    - :13-42 —— 盾牌图标集（design set 1556）：勾=只读 / 笔=工作区写 /
//      叹号=完全权限；WanWo 以 SF Symbols 等义映射（注释逐条对照）。
//    - :101-106 —— 触发器 = 挡位图标 + 挡位名 + chevron（busy 时禁用）。
//    - :108-117 —— 菜单 = options 过滤 custom（WanWo 无 custom 档，恒全列）。
//    - :119-147 —— 提交走 command(`/permission <id>`)——「both surfaces write
//      through one path」（ui-permission-presets/src/index.ts:8-10）：本下拉与
//      手输 /permission 命令同一写通路径；Full access 先 RiskConfirmation。
//    - :177-190 —— Full access 确认文案 = accessZh（locales.ts:43-47，当前
//      会话挡：「智能体将减少确认步骤…当前任务」）。
//  宿主接线：onCommand 回传 ChatViewModel.runCommandLine（command/run → run →
//  command/done 落盘 + 重投影，与手输完全同路）。
//

import SwiftUI

/// composer 权限挡位下拉（当前会话旋钮的可视面）。
struct PermissionSelectView: View {
    /// 当前预设名（PermissionKnobs.currentPresetName()）。
    let currentPreset: String
    /// 提交在途（busy 禁用——dsh pick/confirmation 期间 disabled）。
    let busy: Bool
    /// 命令行提交缝（"/permission <id>"；与手输同路——one path 纪律）。
    /// confirmed = 本下拉内的 RiskConfirmation 已通过（P2-⑪ 双弹修复：
    /// dsh 确认缝归入口所有——确认后直达提交，不再触发命令门控二次确认）。
    let onCommand: (String, _ confirmed: Bool) -> Void

    @State private var open = false
    @State private var confirmingFullAccess = false
    @State private var acknowledged = false

    // MARK: - 挡位表（文案 zh 逐字：ui-permission-presets locales.ts:40-42）

    private struct Option: Identifiable {
        let id: String
        let label: String
        /// SF Symbols 等义映射（dsh PermissionSelect.tsx:13-42 design set 1556）。
        let glyph: String
    }

    /// dsh settings schema 广播三挡；custom 为派生态不进菜单（:108-117 滤除语义）。
    private static let options: [Option] = [
        Option(id: "read-only", label: "仅可查看", glyph: "checkmark.shield"),
        Option(id: "workspace-write", label: "工作区内修改", glyph: "square.and.pencil"),
        Option(id: "danger-full-access", label: "完全权限", glyph: "exclamationmark.shield"),
    ]

    private var currentOption: Option? {
        Self.options.first { $0.id == currentPreset }
    }

    var body: some View {
        Menu {
            ForEach(Self.options) { option in
                Button {
                    choose(option.id)
                } label: {
                    Label(option.label, systemImage: option.glyph)
                }
            }
        } label: {
            // 触发器（:158-175）：挡位图标 + 挡位名 + chevron。
            HStack(spacing: 4) {
                Image(systemName: currentOption?.glyph ?? "shield")
                    .font(.footnote)
                Text(currentOption?.label ?? currentPreset)
                    .font(.footnote)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .disabled(busy)
        .accessibilityLabel("访问模式，当前：\(currentOption?.label ?? currentPreset)")
        // Full access 前置风险确认（dsh :129-133 特判 + :177-190 确认面）。
        // P2-⑫：呈现由 sheet 改居中模态（dsh RiskConfirmation 对话框形态）。
        .fullScreenCover(isPresented: $confirmingFullAccess, onDismiss: { acknowledged = false }) {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                confirmSheet
            }
            .presentationBackground(.clear)
        }
    }

    // MARK: - 选择（dsh choose/submit :126-147）

    private func choose(_ id: String) {
        if id == currentPreset { return }
        if id == "danger-full-access" {
            acknowledged = false
            confirmingFullAccess = true
            return
        }
        submit(id)
    }

    private func submit(_ id: String, confirmed: Bool = false) {
        // 同一写通路径：GUI 与命令行均落 /permission <id> 命令（one path）。
        // confirmed = 入口确认已过（Full access 下拉确认后直达——双弹修复）。
        onCommand("/permission \(id)", confirmed)
    }

    private var confirmSheet: some View {
        RiskConfirmationView(
            title: "确认启用完全权限？",
            description: "启用完全权限后，智能体将减少确认步骤，并且可以直接执行更多操作，"
                + "包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。",
            acknowledgeLabel: "我已了解风险，并愿意继续",
            cancelLabel: "取消",
            confirmLabel: "启用完全权限",
            acknowledged: $acknowledged,
            onCancel: { confirmingFullAccess = false },
            onConfirm: {
                confirmingFullAccess = false
                submit("danger-full-access", confirmed: true)
            })
    }
}
