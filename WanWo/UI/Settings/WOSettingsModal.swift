//
//  WOSettingsModal.swift
//  WanWo
//
//  设置模态壳（按用户验收过的 HTML 原型 wanwo-ui-prototype.html「设置」节；
//  digest-H §3：居中模态 800×min(720,100vh-48)、圆角 32、遮罩 rgba(0,0,0,.24)
//  +blur(2px)、左 nav 188px cell 40px 高 active #EBEEF2、右上角 X 关闭）。
//
//  内容区直接承载既有旧设置页（真功能零重写——ProvidersView/MCPServersView/
//  SkillsView/PermissionDefaultsView/MountedFoldersSettingsView/EventStreamView
//  原样挂入，路由方式与旧 SettingsPanelView contentBody 一致；旧 Views 目录
//  只读未动）。分区文案沿用旧页原文（SettingsPane.title）。
//
//  与 AppEnvironment 既有状态的接缝：
//    · 内容页均直持 environment 的各 store（真功能）；
//    · 打开时若 AppEnvironment.settingsPane 有值（openSettings(at:) 深链落点，
//      wanwo://settings/permissions → .permissions 的 Offload deny 闭环），
//      自动采纳为当前分区；打开中再次变更同样跟随。
//
//  动效（Motion.swift 纪律）：遮罩淡入 + 卡片 spring 弹入（原型 translateY(10px)
//  scale(.96) → spring）；出场 ×0.65 加速淡出；分区切换 = slide 12px 语义位移；
//  reduceMotion 降级为纯淡入淡出（.woMotion 自动 + 转场手动分流）。
//
//  颜色一律 WO 令牌（WOStatic/WOAlias/WOSpecific）；nav active 底 #EBEEF2 =
//  WOStatic.neutralBluish100（与原型逐值同源）。
//
//  iOS 16.6 红线自查：.onChange 单参版（16.0+）；.scrollContentBackground
//  （16.0+）；未用双参 onChange/ScrollPosition/ContentUnavailableView/@Observable。
//

import SwiftUI

/// 设置模态壳（原型「设置」节 1:1 形态；WORootFrame 以
/// `WOSettingsModal(isPresented:)` 挂 overlay 调用）。
struct WOSettingsModal: View {
    // MARK: - 对外接口

    @Binding private var isPresented: Bool
    /// 可选：打开时的初始分区（缺省 nil = 采纳 AppEnvironment.settingsPane
    /// 深链值，再缺省 .providers——与旧 SettingsPanelView 缺省一致）。
    private let initialPane: SettingsPane?

    init(isPresented: Binding<Bool>, initialPane: SettingsPane? = nil) {
        _isPresented = isPresented
        self.initialPane = initialPane
    }

    // MARK: - 状态

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPane: SettingsPane = .providers

    // MARK: - 规格（原型逐值）

    /// 原型：面板 800 宽 / min(720, 视口-48) 高。
    private static let maxCardWidth: CGFloat = 800
    private static let maxCardHeight: CGFloat = 720
    /// 原型：视口缘最小距 24（两侧共 48）。
    private static let viewportMargin: CGFloat = 24
    /// 原型：左 nav 188px。
    private static let navWidth: CGFloat = 188
    /// 原型：卡片圆角 32。
    private static let cardRadius: CGFloat = 32

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let cardSize = Self.cardSize(in: geo.size)
            ZStack {
                if isPresented {
                    maskLayer
                    cardLayer(size: cardSize)
                }
            }
            // 出入场动画全部内嵌在各自 transition（.animation 自驱动）——
            // 容器级 woMotion 与 transition 内嵌动画双驱动会在 removal 上叠加，
            // 造成关闭残影（2026-09-20 真机反馈）。
        }
        .onAppear { adoptIncomingPane(force: false) }
        .onChange(of: isPresented) { presented in
            guard presented else { return }
            adoptIncomingPane(force: true)
        }
        // 深链在模态已打开时再次落 pane（openSettings(at:) 既有入口）→ 跟随。
        .onChange(of: environment.settingsPane) { pane in
            guard isPresented, let pane else { return }
            selectedPane = pane
        }
        // Escape 关闭（iPad 硬件键盘；触屏主路径 = 右上 X / 遮罩点击）。
        .background {
            Button("") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - 遮罩（原型 bg-mask-1 + blur(2px)，点击关闭）

    private var maskLayer: some View {
        Rectangle()
            .fill(WOAlias.bgMask1)
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { isPresented = false }
            .transition(.opacity.animation(.easeOut(duration: 0.15)))
            .accessibilityLabel("关闭设置")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - 卡片（r32 白底 + prominent 阴影；左 nav + 右内容）

    private func cardLayer(size: CGSize) -> some View {
        HStack(spacing: 0) {
            navColumn
                .frame(width: Self.navWidth)
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(WOAlias.borderL2)
                .frame(width: 1)
            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
        // 内容先裁圆角（旧页 List 内容不出 32 圆角），再叠 prominent 阴影与发丝描边。
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
        .background(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .fill(WOAlias.bgLayer2))
        .shadow(color: .black.opacity(WOElevation.prominent.shadows[0].opacity),
                radius: WOElevation.prominent.shadows[0].blur,
                y: WOElevation.prominent.shadows[0].y)
        .shadow(color: .black.opacity(WOElevation.prominent.shadows[1].opacity),
                radius: WOElevation.prominent.shadows[1].blur,
                y: WOElevation.prominent.shadows[1].y)
        .overlay(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .strokeBorder(WOElevation.prominent.strokeColor,
                          lineWidth: WOElevation.prominent.strokeWidth))
        .transition(cardTransition)
    }

    /// 出入场：遮罩淡入之上，卡片自 translateY(10px) scale(.96) spring 弹入；
    /// 出场加速淡出（R2 出场 ×0.65）；reduceMotion 降级纯淡入淡出。
    private var cardTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(.easeOut(duration: 0.15))
        }
        return .asymmetric(
            insertion: .modifier(
                active: WOShift(x: 0, y: 10, opacity: 0),
                identity: WOShift(x: 0, y: 0, opacity: 1))
                .combined(with: .scale(scale: 0.96))
                .animation(WOMotion.standardSpring),
            removal: .opacity.animation(.easeOut(duration: 0.15)))
    }

    // MARK: - 左 nav（188px；cell 40px 高 active #EBEEF2）

    private var navColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置")
                .font(.system(size: WOType.m18.size, weight: WOType.m18.weight))
                .foregroundColor(WOAlias.labelPrimary)
                .padding(.leading, 20)
                .padding(.top, 22)
                .padding(.bottom, 10)
            // 分区 = 旧面板实际有的六分区（SettingsPane.allCases；文案旧页原文）。
            ForEach(SettingsPane.allCases) { pane in
                navRow(pane)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    private func navRow(_ pane: SettingsPane) -> some View {
        let isActive = selectedPane == pane
        return Button {
            selectedPane = pane
        } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.iconName)
                    .font(.system(size: 14))
                    .foregroundColor(isActive ? WOAlias.labelPrimary : WOAlias.labelSecondary)
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: WOType.xsStrong13.size,
                                  weight: isActive ? WOType.xsStrong13.weight : .regular))
                    .foregroundColor(WOAlias.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40) // 原型 cell 40px
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? WOStatic.neutralBluish100 : Color.clear)) // 原型 active #EBEEF2
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel(pane.title)
        .accessibilityHint(pane.footer)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    // MARK: - 右内容区（承载旧页；右上角 X 关闭）

    private var contentColumn: some View {
        ZStack(alignment: .topTrailing) {
            activePaneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 首行让位右上角悬浮 X（28px + 14 边距）。
                .padding(.top, 44)
            closeButton
                .padding(.trailing, 14)
                .padding(.top, 14)
        }
    }

    private var closeButton: some View {
        Button {
            isPresented = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .background(Circle().fill(WOAlias.interactiveBgHover))
                .foregroundColor(WOAlias.labelSecondary)
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel("关闭设置")
    }

    // MARK: - 分区路由（旧页视图原样迁入，与旧 SettingsPanelView contentBody 同构）

    @ViewBuilder
    private var activePaneContent: some View {
        paneContent(selectedPane)
            .id(selectedPane)
            // 面板/视图切换：12px 方向性轻位移 + 淡入（Motion.swift 平级切换语义）。
            .transition(reduceMotion ? .opacity : WOTransition.slide(directionX: 1))
            .woMotion(WOMotion.standardSpring, value: selectedPane)
            // 旧页均为 List（默认绘制 systemGroupedBackground 灰底）——隐藏其
            // 滚动区底色并衬卡片白底，与原型白底卡片贯通（包一层适配容器，
            // 旧页源码零改动；.scrollContentBackground 为 iOS 16.0+ API）。
            .scrollContentBackground(.hidden)
            .background(WOAlias.bgBase)
    }

    /// 分区 → 旧页视图（真功能；注入方式与旧面板逐项一致）。
    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        switch pane {
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

    // MARK: - 深链 pane 采纳

    /// 打开时决定初始分区：显式 initialPane > AppEnvironment.settingsPane
    /// （openSettings(at:) 既有深链落点）> .providers（旧面板缺省）。
    private func adoptIncomingPane(force: Bool) {
        if let initialPane {
            selectedPane = initialPane
        } else if let linked = environment.settingsPane {
            selectedPane = linked
        } else if force {
            selectedPane = .providers
        }
    }

    // MARK: - 尺寸（原型：800 × min(720, 视口-48)）

    private static func cardSize(in container: CGSize) -> CGSize {
        CGSize(width: min(maxCardWidth, container.width - viewportMargin * 2),
               height: min(maxCardHeight, container.height - viewportMargin * 2))
    }
}
