//
//  WOHelpers.swift
//  WanWo
//
//  环 2 批 A —— ui-primitives 工具层 SwiftUI 等价物（细读文档 7.1 节，行 3044-3141）。
//  语义 1:1；React hook → Swift 惯用法映射逐条登记 ring2a-token-audit.md 机制映射列。
//

import SwiftUI
import UIKit

// MARK: - 相对时间分桶（7.1.6 relative-time.ts，37 行——分桶集中保证两处一致，词汇归调用方）

public enum WORelativeTimeUnit: Equatable {
    case now, minutes, hours, days, months, years
}

public struct WORelativeTime: Equatable {
    public let unit: WORelativeTimeUnit
    public let n: Int
}

public enum WORelativeTimeBucket {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86400

    /// relativeTime(at, now)：纯函数（手册 3053-3055 行逐规则）
    public static func relativeTime(at: Date, now: Date) -> WORelativeTime {
        let diff = max(0, now.timeIntervalSince(at))
        if diff < minute { return .init(unit: .now, n: 0) }
        if diff < hour { return .init(unit: .minutes, n: Int(floor(diff / minute))) }
        if diff < day { return .init(unit: .hours, n: Int(floor(diff / hour))) }
        if diff < 30 * day { return .init(unit: .days, n: Int(floor(diff / day))) }
        if diff < 365 * day { return .init(unit: .months, n: Int(floor(diff / (30 * day)))) }
        return .init(unit: .years, n: Int(floor(diff / (365 * day))))
    }
}

// MARK: - head-tail 截断算术（7.1.7 head-tail-cap.ts，28 行）

public struct WOHeadTailCap: Equatable {
    /// 上限外隐藏的行数（列表长 − maxLines）；≤0 = 没有隐藏
    public let hidden: Int
    /// 超限且未展开 → 显示头尾切片
    public let capped: Bool
    /// 头部切片行数 = ceil(maxLines / 2)
    public let headLines: Int
    /// 尾部 = 余量
    public let tailLines: Int

    /// 纯算术；调用方用 headLines/tailLines 自行切片（SearchBlock 要在尾片恢复文件头等）
    public static func cap(total: Int, maxLines: Int, expanded: Bool) -> WOHeadTailCap {
        let hidden = total - maxLines
        let head = Int(ceil(Double(maxLines) / 2))
        return .init(hidden: hidden,
                     capped: hidden > 0 && !expanded,
                     headLines: head,
                     tailLines: maxLines - head)
    }
}

// MARK: - 指针宽限（7.1.8 pointer-grace.ts，48 行）
//
// "Grace before a pointer-dismissed popup closes. Covers the anchor->popup gap
// (8px for HoverCard, 4px for Menu) at a hand's travel speed."

public final class WOPointerGrace {
    /// 200ms——锚到弹层缝隙的手速宽限
    public static let graceMS: TimeInterval = 0.2

    private var pending: DispatchWorkItem?

    /// 安排 200ms 后关闭；重复 arm 替换挂起的那个
    public func arm(_ close: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: close)
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceMS, execute: item)
    }

    /// 指针回来了——撤销挂起的关闭
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    public init() {}
}

// MARK: - 复制回执（7.1.9 use-copy-feedback.ts，32 行）
//
// 简版（无 epoch 句柄管理——那是 MessageIconActions 的加强版，环 5b 做）：
// copied 为 true 期间跳过；写入被拒时静默。

@MainActor
public final class WOCopyFeedback: ObservableObject {
    /// 写入成功后维持 1000ms
    public static let feedbackMS: TimeInterval = 1.0

    @Published public private(set) var copied = false
    private var resetTask: Task<Void, Never>?

    public init() {}

    /// 复制 text；成功后置 copied 1 秒
    public func onCopy(_ text: String) {
        guard !copied else { return }
        UIPasteboard.general.string = text
        copied = true
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.feedbackMS * 1_000_000_000))
            if !Task.isCancelled { self?.copied = false }
        }
    }
}

// MARK: - 剪贴板（7.1.5 clipboard.ts，48 行——iOS 直接 UIPasteboard，成功即 true）

public enum WOClipboard {
    /// "Success feedback stays with each control; this helper only reports whether the host accepted a write."
    @discardableResult
    public static func write(_ text: String) -> Bool {
        UIPasteboard.general.string = text
        return true
    }
}

// MARK: - 锚定视口贴合（7.1.11 useAnchoredMaxHeight.ts，39 行）
//
// 底部锚定浮层（slash 菜单/popupSelect）：底缘固定、向上生长，只有顶缘会撞视口——
// 把设计上限钳到「元素底缘 − 视口顶」之间。MARGIN=12 镜像 Menu 的 portal 边距。

public enum WOAnchoredFit {
    public static let margin: CGFloat = 12

    /// cap 与可用空间的较小者（SwiftUI 侧由 GeometryReader 提供 viewport 高与底缘 y）
    public static func maxHeight(cap: CGFloat, elementBottomY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(cap, max(0, elementBottomY - margin))
    }
}

// MARK: - 视口钳位（7.1.10 useAnchoredPosition.ts 的 clamp 核；portal 模式共用）
//
// "measure the anchor, offset the panel below or above it, clamp the result inside the viewport."
// SwiftUI overlay（原位）模式自动跟随锚；全屏 overlay（portal）模式用本函数按锚 rect 求面板原点。

public enum WOAnchoredPlacement {
    public static let margin: CGFloat = 12

    /// side bottom：top = anchor.bottom + gap；side top：top = anchor.top − gap − height
    /// left 按 align start/end 对齐后整体 clamp 进视口（双侧 margin；宽高 >0 才钳）
    public static func place(anchor: CGRect, panelSize: CGSize,
                             side: WOPopupSide, align: WOPopupAlign, gap: CGFloat,
                             viewport: CGRect) -> CGPoint {
        // x/y 均在 switch 每分支完整赋值（确定性初始化；7.1.10 行 3078 语义）
        let x: CGFloat
        let y: CGFloat
        switch side {
        case .bottom:
            y = anchor.maxY + gap
            switch align {
            case .start: x = anchor.minX
            case .end: x = anchor.maxX - panelSize.width
            }
        case .top:
            y = anchor.minY - gap - panelSize.height
            switch align {
            case .start: x = anchor.minX
            case .end: x = anchor.maxX - panelSize.width
            }
        case .right:
            x = anchor.maxX + 4
            y = anchor.minY
        }
        if panelSize.width > 0, panelSize.height > 0 {
            let cx = min(max(x, viewport.minX + margin), viewport.maxX - margin - panelSize.width)
            let cy = min(max(y, viewport.minY + margin), viewport.maxY - margin - panelSize.height)
            return CGPoint(x: cx, y: cy)
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - 弹层方位/对齐（Menu/Modal 共享词表）

public enum WOPopupSide: String {
    case top, bottom, right
}

public enum WOPopupAlign: String {
    case start, end
}

// MARK: - 虚线描边卡（DashedCard 语义：composer 触发态/RiskConfirmation 共用画法）
//
// dsh 用 ::after + SVG mask（rect rx=22 dasharray 4 4）保圆角虚线；SwiftUI 等价 =
// 圆角 strokeBorder + dash 样式（4/4 同拍）。hover 虚线转 business primary（100ms）。

public struct WODashedBorder: ViewModifier {
    var radius: CGFloat
    var dash: [CGFloat] = [4, 4]
    var color: Color = WOAlias.borderL4
    var active: Color = WOAlias.stateBusinessPrimary
    var isActive: Bool = false

    public func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(isActive ? active : color,
                              style: StrokeStyle(lineWidth: 1, dash: dash, dashPhase: 0))
                .animation(.easeInOut(duration: 0.1), value: isActive) // hover→primary 100ms
        )
    }
}

public extension View {
    /// 触发态虚线卡（整卡点击靶语义由调用方 onTapGesture 承担）
    func woDashedCard(radius: CGFloat, active: Bool = false) -> some View {
        modifier(WODashedBorder(radius: radius, isActive: active))
    }
}
