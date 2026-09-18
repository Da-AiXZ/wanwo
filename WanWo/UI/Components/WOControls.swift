//
//  WOPill.swift + WOButton.swift + WOInput.swift
//  WanWo
//
//  环 2 批 A —— Pill（7.2.2）/ Button（7.2.3）/ Input（7.2.18-19）。
//  三件都是小原子，合在一份文件；数值逐值照抄细读文档。
//

import SwiftUI

// MARK: - Pill（7.2.2：小圆角标签片——视图切换页签/过滤器/徽章）

public struct WOPill: View {
    public let active: Bool
    public let action: (() -> Void)?
    @ViewBuilder public let label: () -> Text

    public init(active: Bool = false, action: (() -> Void)? = nil, label: @escaping () -> Text) {
        self.active = active
        self.action = action
        self.label = label
    }

    public var body: some View {
        // 无 onClick → 静态 span；有 → button（手册 3155 行）
        Group {
            if let action {
                label()
                    .woPressable()
                    .onTapGesture(perform: action)
                    .interactiveStyle()
            } else {
                label()
            }
        }
        .font(.system(size: 12, weight: .regular))
        .lineSpacing(6) // 12px/18px
        .foregroundColor(active ? WOAlias.brandPrimary : WOAlias.labelSecondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            Capsule()
                .fill(active ? WOAlias.buttonGhostActiveFill : WOAlias.bgLayer2)
        )
        .overlay(
            Capsule().strokeBorder(active ? WOAlias.buttonGhostActiveBorder : .clear, lineWidth: 1) // inset 1px
        )
    }
}

// MARK: - Button（7.2.3：变体映射 --dsw-alias-button-* 家族）

public enum WOButtonVariant {
    case primary, ghost, outline, toolbar
}

public enum WOButtonSize {
    case md   // 36px 胶囊（figma Button：h36 pad 14/7 gap4 r18）
    case sm   // 28px 紧凑（稠密行；几何为本包自定）
}

public struct WOButton: View {
    public let variant: WOButtonVariant
    public let size: WOButtonSize
    public let icon: Image?
    public let action: () -> Void
    @ViewBuilder public let label: () -> Text
    @Environment(\.isEnabled) private var isEnabled

    public init(variant: WOButtonVariant = .ghost, size: WOButtonSize = .md,
                icon: Image? = nil, action: @escaping () -> Void,
                label: @escaping () -> Text) {
        self.variant = variant
        self.size = size
        self.icon = icon
        self.action = action
        self.label = label
    }

    public var body: some View {
        // 胶囊几何（figma 1:155）：md h36 pad0 14 gap4 r18 14px/22px；sm h28 pad0 10 r14 12px/18px
        HStack(spacing: 4) {
            if let icon { icon.resizable().scaledToFit().frame(width: 16, height: 16) }
            label()
        }
        .font(.system(size: size == .md ? 14 : 12, weight: .regular))
        .lineSpacing(size == .md ? 8 : 6)
        .foregroundColor(foreColor)
        .padding(.horizontal, size == .md ? 14 : 10)
        .frame(height: size == .md ? 36 : 28)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(outlineColor, lineWidth: 0.5))
        .opacity(isEnabled ? 1 : 0.4) // disabled opacity 0.4
        .woPressable()
        .onTapGesture(perform: action)
    }

    private var fill: Color {
        switch variant {
        case .primary: return WOAlias.buttonPrimaryFill
        case .ghost, .outline: return .clear
        case .toolbar: return WOAlias.buttonToolBarFill
        }
    }

    private var foreColor: Color {
        switch variant {
        case .primary: return WOAlias.labelPrimaryForeground
        case .ghost, .outline, .toolbar: return WOAlias.labelPrimary
        }
    }

    private var outlineColor: Color {
        variant == .outline ? WOAlias.borderL3 : .clear // outline：0.5px l3 边框（对话框 Cancel）
    }
}

// MARK: - Input（7.2.18-19：单行输入原子；composer 的多行 textarea 归 ui-conversation，不在此）

public struct WOInput: View {
    public let icon: Image?
    @Binding public var text: String
    public var placeholder: String = ""

    @FocusState private var focused: Bool

    public init(icon: Image? = nil, text: Binding<String>, placeholder: String = "") {
        self.icon = icon
        self._text = text
        self.placeholder = placeholder
    }

    public var body: some View {
        // wrap：inline-flex 居中 gap6 高 32 pad 0 8 border 0.5 l4 r8 层1 背景；焦点态画在 wrapper
        HStack(spacing: 6) {
            if let icon {
                icon.resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundColor(WOAlias.labelTertiary)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelPrimary)
                .focused($focused)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? WOAlias.brandPrimary : WOAlias.borderL4, lineWidth: 0.5))
    }
}

// MARK: - 交互底色（Pill.interactive hover；ghost Button hover/active 同源）

extension View {
    /// hover 底色（手册 3155 行 .interactive；桌面 hover 语义，iPad 指针场景消费）
    @ViewBuilder
    func interactiveStyle() -> some View {
        background(WOAlias.interactiveBgHover)
    }
}
