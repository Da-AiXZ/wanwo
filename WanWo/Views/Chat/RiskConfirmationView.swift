//
//  RiskConfirmationView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】RiskConfirmation 对话框的 SwiftUI 移植
//  （packages/client/ui-client-ui-primitives RiskConfirmation：标题 + 说明 +
//  风险知悉勾选 + 取消/确认按钮；未勾选知悉前确认钮恒禁用——fail closed）。
//  共用三入口（T2.2 派单 A2/A3/A4「与入口①③共文案」）：
//    ①composer 权限挡位下拉（PermissionSelectView）；
//    ③设置·新会话默认权限行（PermissionDefaultsView）；
//    ②/permission danger-full-access 命令前置确认（ChatViewModel gate）。
//  文案逐字来源：
//    - 当前会话挡（入口①②）：ui-permission-presets/src/client/locales.ts
//      accessZh:43-47（「智能体将减少确认步骤…当前任务」）；
//    - 新会话默认挡（入口③）：同文件 zh:12-16（「新会话将减少确认步骤…后续任务」）。
//

import SwiftUI

/// 风险确认对话框（RiskConfirmation 结构 1:1：标题/说明/知悉勾选/取消+确认）。
struct RiskConfirmationView: View {
    let title: String
    let description: String
    let acknowledgeLabel: String
    let cancelLabel: String
    let confirmLabel: String
    @Binding var acknowledged: Bool
    /// 确认钮禁用条件（busy 等；知悉未勾选恒禁用——dsh disabled 语义并集）。
    var extraDisabled = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题 + 关闭（dsh closeLabel 位）。
            HStack(alignment: .top) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer()
                Button {
                    acknowledged = false
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WOAlias.labelSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            Text(description)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // 风险知悉勾选（dsh acknowledged；未勾选 → 确认恒禁用）。
            Button {
                acknowledged.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: acknowledged ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(acknowledged
                                         ? WOAlias.stateBusinessPrimary
                                         : WOAlias.labelTertiary)
                    Text(acknowledgeLabel)
                        .font(.system(size: 14))
                        .foregroundColor(WOAlias.labelPrimary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                Spacer()
                Button {
                    acknowledged = false
                    onCancel()
                } label: {
                    Text(cancelLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.bgLayer3)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5)))
                }
                .buttonStyle(.plain)
                .woPressable()
                Button {
                    guard acknowledged, !extraDisabled else { return }
                    onConfirm()
                } label: {
                    Text(confirmLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(acknowledged ? WOAlias.stateErrorPrimary
                                               : WOAlias.buttonPrimaryDimmed))
                }
                .buttonStyle(.plain)
                .woPressable()
                .disabled(!acknowledged || extraDisabled)
            }
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 24).fill(WOAlias.bgLayer2))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(WOAlias.borderL4, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 20)
        .padding(24)
    }
}
