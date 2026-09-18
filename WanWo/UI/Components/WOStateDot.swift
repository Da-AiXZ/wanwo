//
//  WOStateDot.swift
//  WanWo
//
//  环 2 批 A —— StateDot（细读文档 7.2.1，行 3143-3151）。
//  四色状态点：done 绿 / warning 琥珀 / ongoing 蓝色像素追逐环 / error 红。
//  ongoing 蓝是组件级钉死的 deepseek-450（手册：state-business-primary 是 500 档，不是这个 450）。
//

import SwiftUI

public enum WOStateDotState: Equatable {
    case done, warning, ongoing, error
}

public struct WOStateDot: View {
    public let state: WOStateDotState
    /// 点尺寸（默认 10px；ongoing 固定按 10 网格画像素环）
    public var size: CGFloat = 10

    /// ongoing 外圈 3×3 矩阵的 8 个外格坐标（2px 像素、10px 网格），顺时针自左上（手册 3146 行）
    static let matrixCells: [(CGFloat, CGFloat)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]

    public init(state: WOStateDotState, size: CGFloat = 10) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Group {
            if state == .ongoing {
                ChaseRing(cell: 2 * (size / 10))
            } else {
                SolidDot(color: Self.color(for: state), size: size)
            }
        }
        .accessibilityHidden(true) // "aria-hidden; pair with text for accessibility"
    }

    /// 三态 color 映射（CSS data-state；done/warning/error 按语义映射 state-* primary）
    static func color(for state: WOStateDotState) -> Color {
        switch state {
        case .done: return WOAlias.stateSuccessPrimary
        case .warning: return WOAlias.stateWarnPrimary
        case .error: return WOAlias.stateErrorPrimary
        case .ongoing: return WOStatic.deepseek450 // 组件级钉死（手册 3150 行）
        }
    }
}

/// 实心态：同色 0.10 外层 halo（::before）+ 6/10 实心核（::after inset 20%）
private struct SolidDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.1))
            Circle().fill(color).padding(size * 0.2) // inset 20% = 实心核 6/10
        }
        .frame(width: size, height: size)
    }
}

/// ongoing 像素追逐环：每格离散亮度阶梯（flat keyframe 无 tween——retro 手感），
/// 追逐峰值逐格衰减 1 / 0.6 / 0.35 / 0.15；相位 = (index − 8) × 125ms（挂载即动）。
private struct ChaseRing: View {
    let cell: CGFloat
    private let step: Double = 0.125 // 125ms；8 步 × 125ms = 1s 周期

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: step)) { timeline in
            let tick = Int(timeline.date.timeIntervalSinceReferenceDate / step)
            return Canvas { ctx, _ in
                for (i, xy) in WOStateDot.matrixCells.enumerated() {
                    // 衰减阶梯：追到该格 = 1，随后三格 0.6 / 0.35 / 0.15（keyframes 0/12.5/25/37.5%）
                    let since = (tick - i).mod(8)
                    let brightness: Double
                    switch since {
                    case 0: brightness = 1
                    case 1: brightness = 0.6
                    case 2: brightness = 0.35
                    default: brightness = 0.15
                    }
                    let rect = CGRect(x: xy.0 * cell, y: xy.1 * cell, width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(WOStateDot.color(for: .ongoing).opacity(brightness)))
                }
            }
            .frame(width: cell * 3, height: cell * 3)
        }
        .frame(width: 10 * (cell / 2), height: 10 * (cell / 2)) // 10px 视觉网格
    }
}

private extension Int {
    /// 正取模（追逐相位回绕）
    func mod(_ m: Int) -> Int { ((self % m) + m) % m }
}
