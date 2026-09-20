//
//  WOLayout.swift
//  WanWo
//
//  环 3 —— 三栏布局契约与状态机（细读文档第 2 章：columns.ts 行 543-546 + stores.ts 行 548-550）。
//

import SwiftUI

// MARK: - 布局契约常量（columns.ts，行 544）

public enum WOLayoutContract {
    /// 中心栏地板（仅最终回退可跌破）。
    /// iPad 适配：dsh 640 为桌面窗口契约，iPad Pro 12.9 逻辑宽仅 1024——
    /// 640 使左右栏数学上永不共存（280+640+300=1220>1024）。降 360 让左右共存（用户真机反馈 2026-09-19）。
    public static let centerMin: CGFloat = 360
    public static let sidebarMin: CGFloat = 264
    public static let sidebarMax: CGFloat = 420
    public static let sidebarDefault: CGFloat = 280
    /// 关闭时的轨道：24px 图标栏 + 两侧 16px 水平内边距
    public static let sidebarCollapsed: CGFloat = 56
    /// deepsuite LG 断点：低于此视口自动收拢侧栏
    public static let autoCollapseBreakpoint: CGFloat = 1024
    public static let detailsMin: CGFloat = 300
    public static let detailsMax: CGFloat = 520
    /// 右栏默认宽：原型 codex 右栏 400px（digest-H 右栏节；让位链自动收缩兜底）
    public static let detailsDefault: CGFloat = 400

    public static func clampWidth(_ px: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, px.rounded()))
    }
}

// MARK: - 让位链解算（columns.ts computeColumns：纯函数，无迟滞）

public struct WOColumns: Equatable {
    /// 侧栏实际渲染宽（关闭 = 56 轨）
    public let sidebar: CGFloat
    public let center: CGFloat
    /// 0 = 关闭
    public let details: CGFloat
}

public enum WOColumnSolver {
    /// 三步让位链（手册 546 行）：
    /// 步骤 1 侧栏固定偏好（或 56 轨）绝不退让，放得下则 center = viewport − s − d；
    /// 步骤 2 details 向 DETAILS_MIN 收缩（d1 = max(300, viewport − s − 640)）；
    /// 步骤 3 details 自动关闭（派生 0 不改偏好），中心吸收剩余亏空（可跌破 640，最低 max(0, viewport − s)）。
    public static func compute(viewport: CGFloat, sidebar: CGFloat, details: CGFloat) -> WOColumns {
        let v = max(0, viewport)
        let s = sidebar
        if details <= 0 {
            return .init(sidebar: s, center: max(0, v - s), details: 0)
        }
        let center0 = v - s - details
        if center0 >= WOLayoutContract.centerMin {
            return .init(sidebar: s, center: center0, details: details)
        }
        // 步骤 2：收缩但不低于地板
        let d1 = max(WOLayoutContract.detailsMin, v - s - WOLayoutContract.centerMin)
        let center2 = v - s - d1
        if center2 >= WOLayoutContract.centerMin {
            return .init(sidebar: s, center: center2, details: d1)
        }
        // 步骤 3：自动关闭（派生 0——偏好不动），中心吸收
        return .init(sidebar: s, center: max(0, v - s), details: 0)
    }
}

// MARK: - 布局 store（stores.ts createLayoutStore，行 548-550）

@MainActor
public final class WOLayoutStore: ObservableObject {
    /// 侧栏宽度偏好（0 = 关闭）
    @Published public private(set) var sidebar: CGFloat = WOLayoutContract.sidebarDefault
    /// 详情栏宽度偏好（0 = 关闭）
    @Published public private(set) var details: CGFloat = 0
    @Published public private(set) var narrow = false
    /// narrow 态的展开覆盖（宽度偏好不动）
    @Published public private(set) var narrowExpanded = false

    public init() {}

    /// clamp 进契约区间且**不跨开合线**（手册 stores.ts：拖到地板以下停在 264，关闭只走 toggle）
    public func setSidebar(_ px: CGFloat) {
        let clamped = WOLayoutContract.clampWidth(px, WOLayoutContract.sidebarMin, WOLayoutContract.sidebarMax)
        guard clamped != sidebar else { return }
        sidebar = clamped
    }

    public func setDetails(_ px: CGFloat) {
        guard px > 0 else { details = 0; return }
        let clamped = WOLayoutContract.clampWidth(px, WOLayoutContract.detailsMin, WOLayoutContract.detailsMax)
        guard clamped != details else { return }
        details = clamped
    }

    /// narrow：翻转 narrowExpanded 覆盖（宽度偏好不动）；宽：0 ⟷ 280
    public func toggleSidebar() {
        if narrow {
            narrowExpanded.toggle()
        } else {
            sidebar = sidebar == 0 ? WOLayoutContract.sidebarDefault : 0
        }
    }

    /// 跨断点时丢弃覆盖
    public func setNarrow(_ isNarrow: Bool) {
        guard narrow != isNarrow else { return }
        narrow = isNarrow
        if !isNarrow { narrowExpanded = false }
    }

    /// 已开则 no-op
    public func openDetails() {
        guard details == 0 else { return }
        details = WOLayoutContract.detailsDefault
    }

    public func closeDetails() {
        details = 0
    }
}
