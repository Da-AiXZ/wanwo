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
                            // header pad 22 14 12 24（右 14 小——关闭钮自带命中区）
                            HStack(spacing: 8) {
                                Text(title)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(WOAlias.labelPrimary)
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
                            .padding(.top, 22).padding(.bottom, 12)
                            .padding(.leading, 24).padding(.trailing, 14)

                            if let description {
                                // description/body 共享 332px 内容列（24 侧 pad）
                                Text(description)
                                    .font(.system(size: 14))
                                    .foregroundColor(WOAlias.labelPrimary)
                                    .padding(.horizontal, 24)
                            }
                            content()
                                .padding(.horizontal, 24)
                                .padding(.top, description == nil ? 12 : 0)
                        }
                        footer()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 24)
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
