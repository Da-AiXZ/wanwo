//
//  ApprovalPanelView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T1 · ERR-028 修复项】出处（呈现形态 = 原件）：
//    - packages/client/ui-approval/src/client/ApprovalPanel.tsx —— 结构 1:1：
//      卡片 = 琥珀条（dot + waiting 文案）→ 滚动文本区（headline + 配对命令）
//      → 动作行（拒绝 outline / 允许一次 primary），动作行在滚动区外恒可见。
//    - packages/client/ui-approval/src/client/ApprovalPanel.module.css —— 样式
//      常量来源（card 圆角 20 / strip 字号 13·行高 18 / headline 15·500·行高 24 /
//      command 13·等宽·行高 20 / body 内边距 12 16 0 / actionRow 14 16）。
//    - .agents/notes/implemented/bug-fix/2026-07-30-approval-panel-command-cap.md
//      —— 文本区高度上限与 composer 草稿区同值（--dsh-composer-text-max-height:
//      336px）；琥珀条与动作行在滚动区外；文本不截断（命令是待批准对象，
//      截断=让用户批准读不到的文本，笔记 Alternatives 明文否决）。
//    - packages/client/ui-approval/src/client/locales.ts —— zh 文案逐字：
//      waiting「等待审批」/ escalation「工具 {toolName} 请求越权执行」/
//      reject「拒绝」/ allowOnce「允许一次」。
//    - dsh 笔记 2026-07-23 —— 按钮点击后本地禁用；结算失败 re-arm；
//      一次性拒绝/允许（allowed-once）。
//  样式分层纪律：dsw 色彩别名 → iOS 系统色映射集中在 ApprovalPanelStyle
//  常量表（M9 全局样式体系化前不散落硬编码）。
//

import SwiftUI

/// 呈现样式常量（结构+样式分层；值对照 dsh 原件，M9 体系化时统一替换色彩别名）。
enum ApprovalPanelStyle {
    /// dsh --dsh-composer-text-max-height（2026-07-30 笔记：与 InputBar 文本
    /// 上限同值，接管不改变 composer 座位高度，防跳动）。
    static let textMaxHeight: CGFloat = 336
    /// .card border-radius: 20px。
    static let cardCornerRadius: CGFloat = 20
    /// --dsw-alias-state-warn-primary（琥珀警示主色）→ 系统橙。
    static let warnPrimary = Color.orange
    /// --dsw-alias-state-warn-tertiary（琥珀条底色）→ 橙 12% 透明。
    static let warnTertiary = Color.orange.opacity(0.12)
    /// --dsw-specific-input-major（卡片底）→ 输入底色。
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    /// --dsw-alias-label-primary / -tertiary → 主/三级文本色。
    static let labelPrimary = Color.primary
    static let labelTertiary = Color.secondary
}

/// 审批 composer 接管（取代输入框：理由标题 + 配对命令 + 一次性拒绝/允许按钮；
/// 答后由 settleApproval 退位恢复 composer）。
struct ApprovalPanelView: View {
    let pending: PendingApprovalPresentation
    /// 提交在途（按钮禁用；结算失败由 VM re-arm——dsh re-arm 语义）。
    let answering: Bool
    /// allow=true → allowed-once；false → rejected。
    let onAnswer: (_ allow: Bool) -> Void

    /// headline：请求理由，缺省走 dsh escalation 文案模板（locales.ts 逐字）。
    private var headline: String {
        pending.reason ?? "工具 \(pending.toolName) 请求越权执行"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 琥珀条（滚动区外；dot 8px 圆点 + waiting 文案 13/18）。
            HStack(spacing: 8) {
                Circle()
                    .fill(ApprovalPanelStyle.warnPrimary)
                    .frame(width: 8, height: 8)
                Text("等待审批")
                    .font(.system(size: 13, weight: .regular).leading(.tight))
            }
            .foregroundStyle(ApprovalPanelStyle.warnPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ApprovalPanelStyle.warnTertiary)

            // 滚动文本区（高度上限 336 与输入框草稿区同值；命令不截断，
            // 溢出滚动——2026-07-30 command-cap 笔记语义）。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.system(size: 15, weight: .medium))
                        .lineSpacing(24 - 15)
                        .foregroundStyle(ApprovalPanelStyle.labelPrimary)
                    if let detail = pending.commandDetail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 13).monospaced())
                            .foregroundStyle(ApprovalPanelStyle.labelTertiary)
                            .lineSpacing(20 - 13)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .frame(maxHeight: ApprovalPanelStyle.textMaxHeight, alignment: .top)
            .accessibilityLabel("审批详情")

            // 动作行（滚动区外恒可见；拒绝 outline / 允许一次 primary）。
            HStack(spacing: 8) {
                Spacer()
                Button {
                    onAnswer(false)
                } label: {
                    Text("拒绝")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(answering)

                Button {
                    onAnswer(true)
                } label: {
                    Text("允许一次")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(answering)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(ApprovalPanelStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ApprovalPanelStyle.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ApprovalPanelStyle.cardCornerRadius)
                .stroke(ApprovalPanelStyle.warnPrimary.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-panel-\(pending.id)")
    }
}
