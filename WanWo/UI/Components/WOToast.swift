//
//  WOToast.swift + WOConnectionIndicator.swift
//  WanWo
//
//  环 2 批 A —— Toast（7.2.20-21：顶部瞬时横幅）+ ConnectionIndicator（7.2.22-23：连接恢复条）。
//

import SwiftUI

// MARK: - Toast（顶部居中瞬时横幅；hold 由 owner 设，一个值驱动卸载与淡出延迟）

public struct WOToast: View {
    public static let holdDefault: TimeInterval = 3.0  // HOLD_MS 3000
    public static let fade: TimeInterval = 1.0         // FADE_MS 1000（须与样式表淡出一致）

    public let text: String
    public var icon: Image? = nil
    public var holdMs: TimeInterval = WOToast.holdDefault
    /// 水平中心跟随的锚（如 composer 卡）——省略则对视口居中
    public var anchorFrame: CGRect? = nil
    public let onDone: () -> Void

    @State private var shown = false
    @State private var fading = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(text: String, icon: Image? = nil, holdMs: TimeInterval = WOToast.holdDefault,
                anchorFrame: CGRect? = nil, onDone: @escaping () -> Void) {
        self.text = text
        self.icon = icon
        self.holdMs = holdMs
        self.anchorFrame = anchorFrame
        self.onDone = onDone
    }

    public var body: some View {
        // role="alert"；z1100（压过 lightbox 1000）；pointer-events none（公告永不拦截）
        HStack(spacing: 8) {
            if let icon {
                icon.resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(WOAlias.stateWarnLabel) // 默认 icon 即警告语义
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelPrimaryInverted)
        }
        .padding(.horizontal, 14)
        .frame(height: 40, alignment: .center)
        .background(Capsule().fill(WOAlias.buttonContrastFill)) // 反色底
        .shadow(color: .black.opacity(0.04), radius: 8)
        .shadow(color: .black.opacity(0.05), radius: 20) // --dsw-shadow-lv3
        .frame(maxWidth: 560)
        .opacity(shown ? (fading ? 0 : 1) : 0)
        .offset(y: shown ? 0 : -6) // dsh-toast-in：from translateY(-6px)
        .onAppear {
            if reduceMotion {
                // 只留延迟淡出——滑入降级，但淡出仍要在卸载前结束（手册 3466 行）
                shown = true
            } else {
                withAnimation(.easeOut(duration: 0.16)) { shown = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + holdMs) {
                withAnimation(.easeInOut(duration: Self.fade)) { fading = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + holdMs + Self.fade) { onDone() }
        }
        .id(text) // 同文本重显由 owner 重挂载重启周期（手册 3446 行）
    }
}

// MARK: - WOUndoToast（批12+右栏重构批1 2026-09-27：页签关闭撤销条——用户
//  裁决方式 B：✕ 后底部飘「已关闭 X · 撤销」，点撤销恢复；cc-haha
//  reopenClosedTab 语义 + dsh toast 形态）

public struct WOUndoToast: View {
    public let text: String
    public let undoLabel: String
    public let onUndo: () -> Void
    public let onDone: () -> Void
    /// 停留时长（【批0 件2】独立窗口宿主可传长 hold——询问条需更长决策
    /// 时间；默认 4.0 = 既有页签关闭撤销条节奏不变）。
    public var hold: TimeInterval = 4.0

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(text: String, undoLabel: String = "撤销", hold: TimeInterval = 4.0,
                onUndo: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.text = text
        self.undoLabel = undoLabel
        self.hold = hold
        self.onUndo = onUndo
        self.onDone = onDone
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelPrimaryInverted)
                .lineLimit(1)
            Button {
                onUndo()
                onDone()
            } label: {
                Text(undoLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOStatic.neutral00)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(WOAlias.buttonPrimaryFill))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Capsule().fill(WOAlias.buttonContrastFill))
        .shadow(color: .black.opacity(0.05), radius: 12)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                withAnimation(.easeInOut(duration: 0.5)) { shown = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onDone() }
            }
        }
        .id(text)
    }
}

// MARK: - ConnectionIndicator（断连/重连中/已恢复三态横幅）

public enum WOConnectionState: Equatable {
    case disconnected, connecting, recovered
}

public struct WOConnectionIndicator: View {
    public let state: WOConnectionState?
    public let disconnectedLabel: String
    public let reconnectLabel: String      // hover/focus 动作文本
    public let connectingLabel: String     // 重试文本+点号
    public let recoveredLabel: String
    public let onReconnect: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: WOConnectionState?, disconnectedLabel: String, reconnectLabel: String,
                connectingLabel: String, recoveredLabel: String, onReconnect: @escaping () -> Void) {
        self.state = state
        self.disconnectedLabel = disconnectedLabel
        self.reconnectLabel = reconnectLabel
        self.connectingLabel = connectingLabel
        self.recoveredLabel = recoveredLabel
        self.onReconnect = onReconnect
    }

    public var body: some View {
        if let state {
            HStack(spacing: 6) {
                Image(systemName: state == .recovered ? "checkmark" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                ZStack(alignment: .leading) {
                    // sizeLabel 防宽跳：四种文案全部隐形撑宽，state 切换宽度不跳（手册 3476 行）
                    VStack(alignment: .leading, spacing: 0) {
                        Text(disconnectedLabel); Text(reconnectLabel)
                        Text(connectingLabel); Text(recoveredLabel)
                    }
                    .font(.system(size: 12))
                    .hidden()
                    .accessibilityHidden(true)

                    // stateLabel / hoverLabel 同格叠放（grid-area 1/1 语义）
                    if state != .recovered && hovering {
                        Text(reconnectLabel)
                    } else if state == .connecting {
                        HStack(spacing: 0) { Text(connectingLabel); Dots() }
                    } else {
                        Text(state == .recovered ? recoveredLabel : disconnectedLabel)
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
            .foregroundColor(fore)
            .onHover { hovering = $0 }
            .onTapGesture { if state != .recovered { onReconnect() } } // connecting 点按钮语义=重新开始
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: state) // 背景色 160ms 过渡
        }
    }

    private var fill: Color {
        state == .recovered ? WOAlias.stateSuccessTertiary : WOAlias.stateWarnTertiary
    }
    private var fore: Color {
        state == .recovered ? WOAlias.stateSuccessPrimary : WOAlias.stateWarnLabel
    }

    /// 省略号：0.5em 宽度预留三点位，step 阶梯显现（33.33%/66.66% 留 0.01 缝防浮点闪烁）
    private struct Dots: View {
        @State private var phase = 0
        let step: Double = 0.4

        var body: some View {
            TimelineView(.periodic(from: .now, by: step)) { timeline in
                let t = Int(timeline.date.timeIntervalSinceReferenceDate / step) % 3
                Text("." + (t >= 1 ? "." : " ") + (t >= 2 ? "." : ""))
                    .fixedSize()
            }
        }
    }
}
