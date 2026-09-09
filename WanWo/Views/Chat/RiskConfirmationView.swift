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
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button {
                    acknowledged = false
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭")
            }
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 风险知悉勾选（dsh acknowledged；未勾选 → 确认恒禁用）。
            Button {
                acknowledged.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: acknowledged ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(acknowledged ? Color.accentColor : Color.secondary)
                    Text(acknowledgeLabel)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                Spacer()
                Button(cancelLabel) {
                    acknowledged = false
                    onCancel()
                }
                .buttonStyle(.bordered)
                Button(confirmLabel) {
                    guard acknowledged, !extraDisabled else { return }
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!acknowledged || extraDisabled)
            }
        }
        .padding(18)
        .frame(maxWidth: 420)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(24)
    }
}
