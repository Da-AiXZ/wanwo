//
//  OffloadPermissionDialog.swift
//  WanWo
//
//  【语义源=OpenMinis OffloadPermissionDialog（B1c ④审批卡接线）→ 批12+归挡
//   重塑（2026-09-27 用户裁决）】
//  askOnce 档 offload 命令的权限确认卡。形态演变：
//   1. 原件：sheet（ContentView 挂载）；
//   2. 权限域修复批：sheet 迁 WORootFrame（旧根死视图修复）；
//   3. 本批：**composer 座位接管卡**（WOChatView.composerSeat 第三顺位，
//      WOApprovalCard 同款骨架——用户指名对齐"仅可查看询问权限盖在 dock
//      上层"的现有样式；sheet 形态退役）。
//  应答链不变：WOOffloadPermissionCard → OffloadApprovalPresenter.respond
//  → 缝应答闭包回写 OffloadPermissionManager（sessionGrants/30s 超时语义
//  原样保留）。
//

import SwiftUI

/// offload 权限确认卡（composer 座位接管形态；WOApprovalCard 骨架 1:1）。
struct WOOffloadPermissionCard: View {
    @ObservedObject private var presenter = OffloadApprovalPresenter.shared
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.stateWarnLabel)
                Text("需要你的授权")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Text(request.displayLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            if !request.description.isEmpty {
                Text(request.description)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            if !request.fullCommand.isEmpty {
                Text(request.fullCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(WOAlias.bgModulePlatform))
                    .lineLimit(6)
            }
            HStack(spacing: 10) {
                Button {
                    presenter.respond(to: request.id, allowed: true)
                } label: {
                    Text("允许（本会话免弹）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.buttonPrimaryFill))
                }
                .buttonStyle(.plain)
                .woPressable()

                Button {
                    presenter.respond(to: request.id, allowed: false)
                } label: {
                    Text("拒绝")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOAlias.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                }
                .buttonStyle(.plain)
                .woPressable()
            }
        }
        .padding(14)
        // 原型卡规格：白底 r22 + soft 阴影 + 0.5px l3 发丝描边（与 WOApprovalCard
        // 同款；琥珀语义保留在图标）。
        .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgBase))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.03), radius: 24)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}
