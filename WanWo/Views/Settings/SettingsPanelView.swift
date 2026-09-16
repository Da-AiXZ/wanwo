//
//  SettingsPanelView.swift
//  WanWo
//
//  【批3 A 新写】设置面板（dsh ui-settings SettingsRoot.tsx 形态，审计矩阵 §6.2）：
//    · 全屏 mask + 居中大模态（iPad 横屏预算 1080×700，SettingsRoot.tsx panel 语义；
//      取舍：自定义 mask overlay 而非 fullScreenCover——面板需与左侧栏共存于同一
//      window 且深链打开时不打断 detail 区 NavigationStack，报告注明）；
//    · 左 nav 分区行（icon+label+脚注+当前高亮；dsh navCell aria-current :78 →
//      isSelected 辅助功能 trait）；
//    · 右侧内容列（仅渲染 active 分区；既有六页视图原样迁入——简报 A.6）；
//    · 关闭三路径：右上关闭钮 / mask 点击 / Escape（.cancelAction 键盘快捷键；
//      dsh Escape listener 挂载期语义）；
//    · 打开聚焦关闭钮 / 关闭还原触发钮（SettingsRoot.tsx:61-63, 118-126）——桌面
//      焦点管理在触屏无对应，降级登记报告。
//  挂点：RootView 全窗 overlay（dsh SettingsRoot 为 app 级对话框同位）；开关经
//  AppEnvironment.settingsPane（nil = 关——dsh activeId=undefined 语义）。detail
//  区不切换，免 preSettings 记忆与 NavigationStack 状态丢失（取舍见报告）。
//  六分区（简报 A.4 迁移映射；「通用」按"并入现有项"口径不单列，登记报告）：
//  Providers / MCP / Skills / 权限 / 外挂载文件夹 / 诊断。
//

import SwiftUI

/// 设置面板分区（批3 A——现侧栏六入口一一对应迁入；id/order 自定，语义保留）。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case providers
    case mcpServers
    case skills
    case permissions
    case mounts
    case diagnostics

    var id: String { rawValue }

    /// 分区标题（沿用侧栏原入口词汇）。
    var title: String {
        switch self {
        case .providers: return "Providers"
        case .mcpServers: return "MCP"
        case .skills: return "Skills"
        case .permissions: return "权限"
        case .mounts: return "外挂载文件夹"
        case .diagnostics: return "诊断"
        }
    }

    /// 分区图标（SF Symbol——与侧栏原 footButton 图标同源）。
    var iconName: String {
        switch self {
        case .providers: return "cpu"
        case .mcpServers: return "puzzlepiece.extension"
        case .skills: return "square.stack.3d.up"
        case .permissions: return "lock.shield"
        case .mounts: return "externaldrive.badge.plus"
        case .diagnostics: return "list.bullet.rectangle"
        }
    }

    /// nav 行脚注（迁移来源一句话——帮助用户从旧入口词汇过渡）。
    var footer: String {
        switch self {
        case .providers: return "OpenAI 兼容端点与 API Key"
        case .mcpServers: return "MCP server 管理"
        case .skills: return "技能启停与导入"
        case .permissions: return "新会话默认权限"
        case .mounts: return "外挂载文件夹管理"
        case .diagnostics: return "事件流（只读）"
        }
    }

    /// 测试面：分区 → 迁入视图标识（路由完整性断言；六项全达=简报 E）。
    var destinationIdentifier: String {
        switch self {
        case .providers: return "ProvidersView"
        case .mcpServers: return "MCPServersView"
        case .skills: return "SkillsView"
        case .permissions: return "PermissionDefaultsView"
        case .mounts: return "MountedFoldersSettingsView"
        case .diagnostics: return "EventStreamView"
        }
    }
}

/// 设置面板（批3 A；挂 RootView 全窗 overlay，见文件头）。
struct SettingsPanelView: View {
    @ObservedObject var environment: AppEnvironment

    /// iPad 横屏面板预算（简报 A.2：1080×700 量级居中；小屏自动收缩到安全区）。
    static let maxPanelWidth: CGFloat = 1080
    static let maxPanelHeight: CGFloat = 700
    /// 左 nav 列宽（dsh SettingsRoot navCell 形态折算）。
    private let navWidth: CGFloat = 236

    var body: some View {
        ZStack {
            // mask 点击关闭（关闭路径 2/3；关闭路径 1=contentHeader 关闭钮、
            // 路径 3=下方 Escape 快捷键）。
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { environment.closeSettings() }
                .accessibilityLabel("关闭设置")
                .accessibilityAddTraits(.isButton)
            panelContent
                .frame(maxWidth: Self.maxPanelWidth, maxHeight: Self.maxPanelHeight)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
                .padding(28)
        }
        // Escape 关闭（关闭路径 3——iPad 硬件键盘；.cancelAction 系统映射
        // Esc/macOS、Cmd+. /iOS。触屏无键盘=降级登记报告）。
        .background {
            Button("") { environment.closeSettings() }
                .keyboardShortcut(.cancelAction, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 面板骨架（左 nav + 右内容列）

    private var panelContent: some View {
        HStack(spacing: 0) {
            navColumn
                .frame(width: navWidth)
                .frame(maxHeight: .infinity)
            Divider()
            VStack(spacing: 0) {
                contentHeader
                Divider()
                contentBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 左 nav 分区行列表（dsh SettingsRoot nav 列语义）。
    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)
            ForEach(SettingsPane.allCases) { pane in
                navRow(pane)
            }
            Spacer(minLength: 0)
        }
    }

    private func navRow(_ pane: SettingsPane) -> some View {
        let isActive = environment.settingsPane == pane
        return Button {
            environment.settingsPane = pane
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(pane.footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isActive ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        // dsh SettingsRoot navCell aria-current（:78）→ 选中态辅助功能 trait。
        .accessibilityLabel(pane.title)
        .accessibilityHint(pane.footer)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// 当前 active 分区（settingsPane 恒非 nil 时才挂面板；?? 兜底编译面）。
    private var activePane: SettingsPane {
        environment.settingsPane ?? .providers
    }

    /// 右侧内容列头（分区标题 + 右上关闭钮——关闭路径 1/3；dsh SettingsRoot
    /// closeButton :61-63 同位）。
    private var contentHeader: some View {
        HStack {
            Text(activePane.title)
                .font(.headline)
            Spacer()
            Button {
                environment.closeSettings()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(Color(.secondarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭设置")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 右侧内容路由——既有六页视图**原样迁入**（简报 A.6：内容不改，只换容器；
    /// M4/M6 交互零变化。批2 B③ 外挂载 fullScreenCover 命名卡链路在本容器内
    /// 保持可用；深链落点 .permissions 由 AppEnvironment.openSettings 承接）。
    @ViewBuilder
    private var contentBody: some View {
        switch activePane {
        case .providers:
            ProvidersView(environment: environment)
        case .mcpServers:
            MCPServersView(environment: environment)
        case .skills:
            SkillsView(environment: environment)
        case .permissions:
            PermissionDefaultsView(environment: environment)
        case .mounts:
            MountedFoldersSettingsView()
        case .diagnostics:
            EventStreamView(environment: environment)
        }
    }
}
