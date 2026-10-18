//
//  WOBrowserTabSwitcher.swift
//  WanWo
//
//  【切换器（2026-10-18 用户拍板并入批 2a-1 修 2）· 语义源 = 浏览器2（标签页
//  切换器）.html tabs-view 段 :652-830 + :1786-1896】AI 浏览导航轨迹切换器：
//    · 入口 = 浏览器页右上角「⋯」更多菜单 →「标签页切换器」（用户拍板挪入
//      更多工具；原型的底部独立钮位退役）。
//    · 数据 = WOWorkspaceStore.browserTrail（per-session；AI navigate 成功
//      追加——BrowserUseTool 记录点；手动导航不记；卡片 × 移出轨迹）。
//    · 形态 = 页签内全覆盖毛玻璃层 + 两列卡片网格（白卡 r17 / 头部首字母
//      favicon + 标题 / 右上圆形 × / 激活卡蓝描边 / 55ms 交错入场）。
//    · 切换 = 点卡 → 右栏页签池 loadURL（展示切换；AI 池与页签池独立，
//      不改 AI 浏览状态）。
//  差异登记：原型底部「新建标签页」虚线钮不搬——右栏「+」已是新建页签的
//  唯一入口（本切换器管理的是 AI 页面轨迹，语义错位）；卡片预览区为简化
//  灰条（真缩略图需逐页截图，成本高，登记后置）。
//

import SwiftUI

// MARK: - 切换器覆盖层

struct WOBrowserTabSwitcher: View {
    /// AI 导航轨迹（新→旧呈现；存储为旧→新，此处反转）。
    let entries: [WOWorkspaceStore.BrowserTrailEntry]
    /// 当前展示页（激活卡描边判定）。
    let activeURL: String?
    /// 点卡切换。
    let onPick: (URL) -> Void
    /// 卡片 × 移出轨迹。
    let onCloseEntry: (WOWorkspaceStore.BrowserTrailEntry) -> Void
    /// 完成（右上蓝字钮 / 点卡切换后自动收）。
    let onDone: () -> Void

    var body: some View {
        // 原型 .tabs-view：全覆盖毛玻璃（rgba(242,242,247,.97)+blur 26 的
        // material 等价物）；容器三态外挂 transition（:667 opacity .34s）。
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 0) {
                header
                grid
            }
        }
        .transition(.opacity)
    }

    /// 头部（原型 .tabs-head：标题 21px + 完成蓝字）。
    private var header: some View {
        HStack {
            Text("标签页")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(WOAlias.labelPrimary)
            Spacer(minLength: 0)
            Button {
                onDone()
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(WOAlias.stateBusinessPrimary)
            }
            .buttonStyle(.plain)
            .woPressable()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    /// 两列卡片网格（原型 .tabs-grid gap 13 + .tab-card 3:4 白卡 r17）。
    private var grid: some View {
        let reversed = entries.reversed().enumerated().map { $0 }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 13),
                                GridItem(.flexible(), spacing: 13)],
                      spacing: 13) {
                ForEach(reversed, id: \.element.id) { index, entry in
                    trailCard(entry, displayIndex: index)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
    }

    /// 单卡（原型 .tab-card：头部 favicon+标题+×、预览区灰条、激活蓝描边）。
    private func trailCard(_ entry: WOWorkspaceStore.BrowserTrailEntry,
                           displayIndex: Int) -> some View {
        let isActive = activeURL == entry.url.absoluteString
        let host = entry.url.host ?? entry.url.absoluteString
        let initial = String(host.prefix(1)).uppercased()
        return Button {
            onPick(entry.url)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Text(initial)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(WOAlias.labelSecondary)
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color(.secondarySystemFill)))
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .padding(.top, 11)
                .padding(.bottom, 9)
                // 预览区（简化灰条——真缩略图登记后置，见文件头）。
                ZStack {
                    Color(.systemGray6)
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(height: 38)
                            .opacity(0.8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(height: 8)
                            .padding(.horizontal, 10)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(height: 8)
                            .padding(.horizontal, 22)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(height: 8)
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxHeight: .infinity)
            }
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 17)
                .strokeBorder(isActive ? WOAlias.stateBusinessPrimary : Color.clear,
                              lineWidth: 2.5))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .shadow(color: Color.black.opacity(0.09), radius: 10, y: 3)
            .frame(height: 210)
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .woPressable()
        // 激活卡的 × 悬浮右上（原型 .tab-close 22px 圆灰底）。
        .overlay(alignment: .topTrailing) {
            Button {
                onCloseEntry(entry)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(WOAlias.labelSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 7)
            .padding(.trailing, 7)
            .accessibilityLabel("关闭" + entry.title + "标签页")
        }
        // 原型 cardIn .5s + 55ms 交错（itemIn 12px 近似）。
        .woItemIn(index: displayIndex, step: 0.055, base: 0.02)
    }
}
