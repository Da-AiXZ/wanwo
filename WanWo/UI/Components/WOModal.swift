//
//  WOModal.swift
//  WanWo
//
//  环 2 批 A —— Modal（7.2.16-17：居中模态 + 模糊遮罩；headless 变体）。
//

import SwiftUI

public struct WOModal<Content: View, Footer: View>: View {
    public let open: Bool
    public let onClose: () -> Void
    /// 所有模式下都是 aria-label
    public let title: String
    public var description: String? = nil
    /// 无头模式：children 直接进卡，无默认 header/close/body chrome（遮罩/卡/Escape/aria 保留）
    public var headless: Bool = false
    @ViewBuilder public let content: () -> Content
    @ViewBuilder public let footer: () -> Footer

    public init(open: Bool, onClose: @escaping () -> Void, title: String,
                description: String? = nil, headless: Bool = false,
                content: @escaping () -> Content, footer: @escaping () -> Footer) {
        self.open = open
        self.onClose = onClose
        self.title = title
        self.description = description
        self.headless = headless
        self.content = content
        self.footer = footer
    }

    public var body: some View {
        if open {
            // root：fixed 居中 z1000 pad24（视口缘最小距）；mask：bg-mask-1 + blur(2px)
            ZStack {
                Rectangle()
                    .fill(WOAlias.bgMask1)
                    .background(.ultraThinMaterial) // backdrop-filter: blur(2px)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() } // 遮罩点击关

                // dialog：w min(380,100%) r24 层2 背景 elevation-prominent gap20
                VStack(alignment: .leading, spacing: 20) {
                    if headless {
                        content()
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            // header：标题水平居中 + X 恒右上（用户裁定 2026-09-20）
                            ZStack {
                                Text(title)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(WOAlias.labelPrimary)
                                    .frame(maxWidth: .infinity)
                                HStack {
                                    Spacer(minLength: 0)
                                    Button { onClose() } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 12, weight: .medium))
                                            .frame(width: 28, height: 28)
                                            .background(RoundedRectangle(cornerRadius: 8)
                                                .fill(WOAlias.interactiveBgHover))
                                            .foregroundColor(WOAlias.labelSecondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 20).padding(.bottom, 10)
                            .padding(.leading, 24).padding(.trailing, 14)

                            if let description {
                                // description 居中（垂直贴标题、与按钮拉开——文字块
                                // 视觉居中于卡；2026-09-21 用户二次反馈"居下"）
                                Text(description)
                                    .font(.system(size: 14))
                                    .foregroundColor(WOAlias.labelPrimary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 24)
                                    .padding(.top, 6)
                            }
                            content()
                                .padding(.horizontal, 24)
                                .padding(.top, description == nil ? 10 : 14)
                        }
                        footer()
                            .frame(maxWidth: .infinity) // 等宽按钮对称构图（非右下角缩一起）
                            .padding(.horizontal, 24)
                            .padding(.top, 4)
                            .padding(.bottom, 20)
                    }
                }
                .frame(width: min(380, UIScreen.main.bounds.width - 48), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 24).fill(WOAlias.bgLayer2))
                .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
                .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 0) // elevation-prominent
                .overlay(RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(WOAlias.borderL4, lineWidth: 0.5)) // 发丝描边
            }
            .transition(.opacity)
            .woMotion(WOMotion.nonInteractive, value: open)
        }
    }
}
