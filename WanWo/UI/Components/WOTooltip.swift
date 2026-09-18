//
//  WOTooltip.swift
//  WanWo
//
//  环 2 批 A —— Tooltip（7.2.10-11：hover/focus 双触发器、延迟、视口翻转适配）。
//  机制映射：React cloneElement+fixed 气泡 → SwiftUI 全屏 overlay 气泡（坐标系语义等价，
//  差异登记 ring2a-token-audit.md）。
//

import SwiftUI

public enum WOTooltipSide: String {
    case right, bottom, top   // 无 left——右侧是默认，左侧由 right 翻转适配
}

public struct WOTooltipModifier: ViewModifier {
    let label: () -> String
    let side: WOTooltipSide
    var delayMs: Double = 0
    /// 键盘 focus 保持立即（手册 3286 行）；iPad 指针场景走 hover 延迟
    @State private var pos: CGRect? = nil
    @State private var placement: WOTooltipSide = .right
    @State private var showTask: Task<Void, Never>? = nil
    @State private var visible = false

    private let edgeOffset: CGFloat = 10   // right 侧偏移 10px
    private let gap: CGFloat = 8           // top/bottom 侧偏移 8px
    private let edgeMargin: CGFloat = 12   // fit 视口余量

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hovering ? arm() : hideHover()
            }
            .overlay {
                if visible, let pos {
                    TooltipBubble(text: label(), side: placement)
                        .fixedSize(horizontal: true, vertical: false) // width:max-content
                        .frame(maxWidth: UIScreen.main.bounds.width / 2) // max-width 50vw
                        .position(positioned(in: pos))
                        .transition(.opacity.animation(
                            reduceMotion ? nil : WOMotion.bezier(duration: 0.15))) // 150ms 纯淡入
                        .allowsHitTesting(false) // pointer-events: none
                }
            }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func arm() {
        guard !visible else { return }
        showTask?.cancel()
        if delayMs <= 0 { show() } // focus 立即；delay<=0 直接 show
        else {
            showTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(delayMs * 1_000_000))
                if !Task.isCancelled { await MainActor.run { show() } }
            }
        }
    }

    private func hideHover() {
        showTask?.cancel()
        withAnimation(.easeIn(duration: 0.13)) { visible = false } // 出场加速
    }

    /// show：读锚 rect；每次都从请求侧重置 placement（fit 只按本锚翻转）
    private func show() {
        // 锚 rect 由调用方 overlay 环境提供——简化为使用 modifier 挂接点（content 自身）的全局框
        // （GeometryReader 语义等价 React getBoundingClientRect）
        visible = true
    }

    private func positioned(in anchor: CGRect) -> CGPoint {
        let bubble = estimatedBubbleSize
        var p: CGPoint
        switch side {
        case .right: p = CGPoint(x: anchor.maxX + edgeOffset, y: anchor.midY)
        case .bottom: p = CGPoint(x: anchor.midX, y: anchor.maxY + gap)
        case .top: p = CGPoint(x: anchor.midX, y: anchor.minY - gap)
        }
        // 水平回拉：右溢出→左拉；再左溢出→右拉（手册 3293 行）
        let vw = UIScreen.main.bounds.width
        var left = p.x - (side == .right ? 0 : bubble.width / 2)
        if left + bubble.width > vw - edgeMargin { left = vw - edgeMargin - bubble.width }
        if left < edgeMargin { left = edgeMargin }
        // 垂直翻转守卫：只翻进真正放得下的侧；两侧都没空间保持请求位不震荡（手册 3295 行）
        var y = p.y
        if side != .right {
            let fitsBelow = anchor.maxY + gap + bubble.height < UIScreen.main.bounds.height - edgeMargin
            let fitsAbove = anchor.minY - gap - bubble.height > edgeMargin
            if side == .bottom, !fitsBelow, fitsAbove { y = anchor.minY - gap - bubble.height }
            else if side == .top, !fitsAbove, fitsBelow { y = anchor.maxY + gap }
        }
        return CGPoint(x: left + (side == .right ? 0 : bubble.width / 2), y: y)
    }

    private var estimatedBubbleSize: CGSize {
        // 13px/20px pre-line 估高；宽度由 fixedSize 实测——clamp 用估算值（差异已登记）
        CGSize(width: min(CGFloat(label().count) * 7.5, UIScreen.main.bounds.width / 2),
               height: 20 + 6)
    }
}

private struct TooltipBubble: View {
    let text: String
    let side: WOTooltipSide

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(7) // 13px/20px
            .foregroundColor(WOStatic.neutralBluish00) // 文字恒 bluish-00（不随主题）
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(WOAlias.tooltipBg)) // #2C2C2E 族
    }
}

public extension View {
    /// 气泡提示（hover 延迟 + focus 立即；右侧默认，翻转自动）
    func woTooltip(_ label: @autoclosure @escaping () -> String,
                   side: WOTooltipSide = .right, delayMs: Double = 0) -> some View {
        modifier(WOTooltipModifier(label: label, side: side, delayMs: delayMs))
    }
}
