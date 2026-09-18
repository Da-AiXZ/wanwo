//
//  WOHoverCard.swift
//  WanWo
//
//  环 2 批 A —— HoverCard（7.2.12-13：可驻留预览卡 + 复制回执）。
//  与 Tooltip 差异：卡可悬停驻留（pointer 可移入保持打开）、内容可读可选、openDelay 500ms。
//

import SwiftUI

public struct WOHoverCard<Anchor: View, CardContent: View>: View {
    @ViewBuilder public let anchor: () -> Anchor
    @ViewBuilder public let content: () -> CardContent
    /// hover 驻留时长（默认 500ms——预览卡是重内容，比 Tooltip 慢得多）
    public var openDelayMs: Double = 500
    public var disabled: Bool = false
    public var copyText: String? = nil
    public var copyLabel: String = "复制"
    public var copiedLabel: String = "已复制"

    @State private var open = false
    @State private var copied = false
    @State private var copyHeight: CGFloat = 0
    @State private var anchorFrame: CGRect = .zero
    private let grace = WOPointerGrace()
    private let copyFeedback = WOCopyFeedback()

    public init(openDelayMs: Double = 500, disabled: Bool = false,
                copyText: String? = nil, copyLabel: String = "复制", copiedLabel: String = "已复制",
                anchor: @escaping () -> Anchor, content: @escaping () -> CardContent) {
        self.openDelayMs = openDelayMs
        self.disabled = disabled
        self.copyText = copyText
        self.copyLabel = copyLabel
        self.copiedLabel = copiedLabel
        self.anchor = anchor
        self.content = content
    }

    public var body: some View {
        // root：block 而非 inline——消费者拿它包全宽列表行（手册 3336 行）
        anchor()
            .background(GeometryReader { g in
                Color.clear.preference(key: WOAnchorFrameKey.self, value: g.frame(in: .global))
            })
            .onPreferenceChange(WOAnchorFrameKey.self) { anchorFrame = $0 }
            .onHover { hovering in
                // onPointerEnter：grace 期内回来保留现卡；已 open 直接回（手册 3328 行）
                if disabled { return }
                if hovering {
                    grace.cancel()
                    guard !open else { return }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(openDelayMs * 1_000_000))
                        if !Task.isCancelled { withAnimation(WOMotion.nonInteractive) { open = true } }
                    }
                } else {
                    if open { grace.arm { open = false } } // 仅 open 时 arm（与 Menu 形状一致）
                }
            }
            .overlay {
                if open {
                    // 卡片放锚右侧 8px；底缘 clamp 到视口内 8px（手册 3320 行）
                    HoverCardView(copied: copied, copyLabel: copyLabel, copiedLabel: copiedLabel,
                                  content: content)
                        .frame(width: 244)
                        .background(
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(hex: 0x2C2C2E)) // --dsw-hovercard-bg：两主题同值（figma）
                                    .shadow(color: .black.opacity(0.04), radius: 8)
                                    .shadow(color: .black.opacity(0.05), radius: 20) // shadow-lv3
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(WOAlias.borderL4, lineWidth: 0.5))
                                    .preference(key: WOCardHeightKey.self, value: g.size.height)
                            }
                        )
                        .onPreferenceChange(WOCardHeightKey.self) { copyHeight = $0 }
                        .position(position())
                        .transition(.opacity.animation(WOMotion.nonInteractive))
                        .onHover { hovering in
                            if !hovering { grace.arm { open = false } } else { grace.cancel() }
                        }
                        .allowsHitTesting(true) // 故意可命中：驻卡保持打开是功能（手册 3337 行）
                        .onTapGesture { performCopy() }
                }
            }
    }

    private func position() -> CGPoint {
        let h = copyHeight > 0 ? copyHeight : 120
        let x = anchorFrame.maxX + 8
        var y = anchorFrame.minY
        // 底缘 clamp：r.top + h > innerHeight − 8 → innerHeight − h − 8
        if anchorFrame.minY + h > UIScreen.main.bounds.height - 8 {
            y = UIScreen.main.bounds.height - h - 8
        }
        return CGPoint(x: x + 122, y: y + h / 2)
    }

    /// 复制：epoch 互斥 + 1s 回执（SwiftUI 侧高度由 copied 内容切换 + copyHeight 锁定语义简化）
    private func performCopy() {
        guard let copyText, !copyFeedback.copied else { return }
        WOClipboard.write(copyText)
        copyHeight = 0
        copyFeedback.onCopy(copyText)
        copied = copyFeedback.copied
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(WOCopyFeedback.feedbackMS * 1_000_000_000))
            copied = false
        }
    }
}

// MARK: - 卡片视图（copied 态以回执替代 content；高度锁定防塌缩抖动）

private struct HoverCardView<CardContent: View>: View {
    let copied: Bool
    let copyLabel: String
    let copiedLabel: String
    @ViewBuilder let content: () -> CardContent

    var body: some View {
        if copied {
            Text(copiedLabel)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            content()
                .padding(.vertical, 12).padding(.horizontal, 16)
        }
    }
}

// MARK: - 偏好键

public struct WOAnchorFrameKey: PreferenceKey {
    public static var defaultValue: CGRect = .zero
    public static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

public struct WOCardHeightKey: PreferenceKey {
    public static var defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - hex 构造（HoverCard 卡面 #2C2C2E：figma 值两主题一致，组件级变量非主题 token）

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
