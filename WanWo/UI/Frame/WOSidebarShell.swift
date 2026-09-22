//
//  WOSidebarShell.swift
//  WanWo
//
//  环 3 —— 侧栏列壳（细读文档第 3 章 SidebarRoot.tsx 222 行 + SidebarRoot.module.css 359 行）。
//  折叠态机：collapsed → 320ms settled（批D2：内容同步轻渐隐后卸载）→ 卸载宽内容上轨道；
//  展开立即 remount（wide-in 200ms）；
//  lastWideWidth 冻结淡出宽度；everWide = railIn（49px 横移入场，冷刷新直折不播）；
//  滚动条跟随：指针离开 2s linger 后隐藏（quietBars 透明重绑，保 gutter 不 reflow）。
//

import SwiftUI

public struct WOSidebarShell<Region: View, Footer: View>: View {
    let collapsed: Bool
    /// 外壳让位输出的渲染宽（56 轨或偏好宽）
    let width: CGFloat
    let onToggleSidebar: () -> Void
    let onNewSession: () -> Void
    /// 工作区浏览区（环 4 填）；quiet = 指针不在列内（滚动条透明重绑）
    @ViewBuilder public let region: (_ wide: Bool, _ quiet: Bool) -> Region
    /// footer 动作 + 设置入口（环 7 填）
    @ViewBuilder public let footer: (_ wide: Bool) -> Footer

    // 折叠态机（手册 622-629 行）
    @State private var settled = false
    @State private var lastWideWidth: CGFloat = WOLayoutContract.sidebarDefault
    @State private var everWide = false
    @State private var pointerInside = false
    @State private var lingerTask: Task<Void, Never>? = nil
    @State private var toggleHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let inlinePad: CGFloat = 12
    /// 批D2：COLLAPSE_SETTLE_MS 0.15→0.32（手册 622-629 行语义引用同步）——
    /// 内容渐隐（.3s ease 同步）完成后再卸载宽内容上轨道。
    private let settleMS: Double = 0.32
    private let lingerMS: Double = 2.0      // SCROLLBAR_LINGER_MS：滚动条保留时长

    /// wide = !collapsed || !settled（折叠动画期间宽内容仍挂载原地淡出）
    private var wide: Bool { !collapsed || !settled }

    public init(collapsed: Bool, width: CGFloat,
                onToggleSidebar: @escaping () -> Void, onNewSession: @escaping () -> Void,
                @ViewBuilder region: @escaping (_ wide: Bool, _ quiet: Bool) -> Region,
                @ViewBuilder footer: @escaping (_ wide: Bool) -> Footer) {
        self.collapsed = collapsed
        self.width = width
        self.onToggleSidebar = onToggleSidebar
        self.onNewSession = onNewSession
        self.region = region
        self.footer = footer
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            if !wide {
                // 折叠静止 rail：36×36 控件盒居中 56px 轨；插入过渡=49px 横移+淡入（SwiftUI 保证播放）
                railContent
                    .transition(.asymmetric(
                        insertion: .offset(x: 49).combined(with: .opacity),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
            }
            if wide {
                wideContent
                    .frame(width: collapsed ? lastWideWidth : width, alignment: .leading)
                    // 批D2（原型 32/35 行 .sidebar-left{transition:width .42s, opacity .3s}）：
                    // 收起 = 宽度收缩（列宽 0.42s 由 WOColumnsAnimation 承担）+ 内容
                    // 同步轻渐隐 .3s ease（不再"先快速淡出后消失"）。
                    .opacity(collapsed ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: collapsed)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(WOMotion.bezier(duration: 0.2)), // wide-in 200ms
                        removal: .opacity.animation(.easeIn(duration: 0.15))))          // settled 后卸载（内容已渐隐至 0，无可见跳变）
            }
        }
        // transition 由 value 驱动（reduced-motion 时无动画=瞬切）
        .animation(reduceMotion ? nil : WOMotion.standardSpring, value: wide)
        .onAppear {
            if !collapsed { everWide = true; lastWideWidth = width }
        }
        .onChange(of: collapsed) { isCollapsed in
            if isCollapsed {
                // 320ms 计时置 settled（批D2：内容 .3s 渐隐完成再卸载，手册 626 行）
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(settleMS * 1_000_000_000))
                    settled = true
                }
            } else {
                settled = false
                everWide = true
                lastWideWidth = width
            }
        }
        .onChange(of: width) { w in
            if !collapsed { lastWideWidth = w } // 非折叠记录 width（淡出期间内容冻结在展开宽）
        }
        // 指针跟随滚动条（iPad 指针场景；触屏无 hover 语义，linger 兜底隐藏）
        .onHover { inside in
            pointerInside = inside
            if inside {
                lingerTask?.cancel()
            } else {
                lingerTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(lingerMS * 1_000_000_000))
                    if !Task.isCancelled { pointerInside = false }
                }
            }
        }
    }

    // ── 宽态 ────────────────────────────────────────────────
    @ViewBuilder
    private var wideContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // logoRow：h60 justify-end gap8 pad 8 0 8 4 mb8
            HStack(spacing: 8) {
                // 品牌钮兼新会话快捷键（aria=新建会话）
                Button(action: onNewSession) {
                    HStack(spacing: 8) {
                        WOBrandMark.mark(size: 24) // 批10：品牌标统一换原型四芒星
                        Text("万我")
                            .font(.system(size: 18, weight: .semibold))
                            .kerning(0.72) // letter-spacing 0.04em
                            .foregroundColor(WOAlias.labelPrimary)
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                // toggle 28×28 圆钮（aria 打开/收起侧边栏）
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundColor(WOAlias.labelSecondary)
                .background(Circle().fill(WOAlias.interactiveBgHover))
                .woTooltip("收起侧边栏", side: .bottom, delayMs: 500)
            }
            .frame(height: 60, alignment: .center)
            .padding(.leading, 4)
            .padding(.bottom, 8)

            // 新会话钮：批D3 h38→44（触屏 HIG）；r12 0.5px l3 边 elevated-fill
            Button(action: onNewSession) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.message")
                        .font(.system(size: 14, weight: .medium))
                    Text("新会话")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(WOAlias.buttonElevatedFill))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
            }
            .buttonStyle(WOPressableStyle())
            .foregroundColor(WOAlias.labelPrimary)
            .padding(.horizontal, 2)
            .padding(.bottom, 8)
            .background(
                // hover floating-hover（elevated→floating 语义）
                RoundedRectangle(cornerRadius: 12).fill(.clear)
            )

            // regionArea：flex1 margin 负值让嵌套滚动条贴栏缘
            region(true, !pointerInside)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, -4)
                .padding(.trailing, -inlinePad)
                .padding(.leading, 4)

            // footArea：footerActions + settingsArea
            VStack(alignment: .leading, spacing: 0) {
                footer(true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, inlinePad)
    }

    // ── 折叠 rail（56px 轨：36×36 盒居中，10px 侧内边距）──
    @ViewBuilder
    private var railContent: some View {
        VStack(alignment: .center, spacing: 0) {
            // collapsed logoRow：h36 pad0 mb12 justify-start
            // toggle：折叠 hover 鲸鱼标↔panel 图标互换（figma sidebar-hover flow）
            Button(action: onToggleSidebar) {
                ZStack {
                    WOBrandMark.mark(size: 24) // 批10：品牌标统一换原型四芒星
                        .opacity(toggleHovering ? 0 : 1)
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(toggleHovering ? 1 : 0)
                }
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundColor(toggleHovering ? WOAlias.labelPrimary : WOAlias.labelSecondary)
            .background(Circle().fill(toggleHovering ? WOAlias.interactiveBgHover : .clear))
            .onHover { toggleHovering = $0 }
            .woTooltip("打开侧边栏", side: .bottom, delayMs: 500)
            .padding(.bottom, 12)

            // 折叠新会话：36×36 透明钮 hover interactive-bg-hover
            Button(action: onNewSession) {
                Image(systemName: "plus.message")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundColor(WOAlias.labelPrimary)
            .background(Circle().fill(WOAlias.interactiveBgHover))
            .padding(.bottom, 12)
            .woTooltip("新建会话", side: .bottom, delayMs: 500)

            region(false, !pointerInside)
                .frame(maxHeight: .infinity, alignment: .top)

            footer(false)
        }
        .padding(.top, 18)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .frame(width: WOLayoutContract.sidebarCollapsed)
    }
}

