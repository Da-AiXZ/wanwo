//
//  Theme.swift
//  WanWo
//
//  环 0 设计令牌（dsh UI 全量重写九环链 · 第一环）——纯数据零视图
//  唯一色值来源：analysis/dsh-full-source-compendium.md 令牌总表 T.1-T.4（行 165-357）
//  字号阶梯：同文档行 441；Elevation：行 349/438；字体链/曲线/时长：行 397-399
//  深色档：按用户 2026-09-18 拍板固定浅色，不实现（深色值见细读文档 T.2 右列）
//  消费纪律：环 1-8 组件禁硬编码色值/字号/阴影，一律引用本文件。
//

import SwiftUI

// MARK: - 颜值构造助手（私有，非令牌）

@inline(__always)
private func woRGB(_ r: Int, _ g: Int, _ b: Int) -> Color {
    Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
}

@inline(__always)
private func woRGBA(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> Color {
    Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0, opacity: a)
}

// MARK: - T.1 静态色板（--dsw-static-*，浅色档；对应 enum WOStatic）

public enum WOStatic {
    // amber ×5
    public static let amber100 = woRGB(254, 245, 231)
    public static let amber400 = woRGB(247, 173, 49)
    public static let amber500 = woRGB(245, 158, 11)
    public static let amber600 = woRGB(221, 134, 41)
    public static let amber900 = woRGB(39, 36, 31)

    // blue ×12
    public static let blue50 = woRGB(239, 246, 255)
    public static let blue50p = woRGB(234, 243, 255)
    public static let blue75 = woRGB(229, 240, 255)
    public static let blue100 = woRGB(219, 234, 254)
    public static let blue300 = woRGB(147, 197, 253)
    public static let blue400 = woRGB(96, 165, 250)
    public static let blue450 = woRGB(77, 147, 248)
    public static let blue500 = woRGB(59, 130, 246)
    public static let blue600 = woRGB(37, 99, 235)
    public static let blue800 = woRGB(30, 64, 175)
    public static let blue900 = woRGB(14, 48, 116)
    public static let blue950 = woRGB(23, 37, 84)

    // deepseek ×11（-700-delete：上游标记删除但仍在源码，照录）
    public static let deepseek50 = woRGB(237, 243, 254)
    public static let deepseek100 = woRGB(228, 237, 253)
    public static let deepseek200 = woRGB(211, 226, 255)
    public static let deepseek300 = woRGB(183, 200, 254)
    public static let deepseek400 = woRGB(103, 158, 254)
    public static let deepseek450 = woRGB(86, 134, 254)
    public static let deepseek500 = woRGB(65, 118, 230)
    public static let deepseek600 = woRGB(72, 104, 178)
    public static let deepseek700Delete = woRGB(47, 76, 143)
    public static let deepseek800 = woRGB(52, 65, 91)
    public static let deepseek900 = woRGB(40, 49, 66)

    // green ×4
    public static let green100 = woRGB(230, 250, 237)
    public static let green400 = woRGB(78, 209, 126)
    public static let green500 = woRGB(34, 197, 94)
    public static let green900 = woRGB(35, 60, 44)

    // neutral ×16
    public static let neutral00 = woRGB(255, 255, 255)
    public static let neutral50 = woRGB(250, 250, 250)
    public static let neutral100 = woRGB(245, 245, 245)
    public static let neutral150 = woRGB(237, 237, 237)
    public static let neutral200 = woRGB(229, 229, 229)
    public static let neutral250 = woRGB(220, 220, 220)
    public static let neutral300 = woRGB(212, 212, 212)
    public static let neutral400 = woRGB(162, 164, 166)
    public static let neutral500 = woRGB(127, 130, 135)
    public static let neutral550 = woRGB(101, 103, 107)
    public static let neutral600 = woRGB(84, 85, 87)
    public static let neutral700 = woRGB(60, 60, 61)
    public static let neutral800 = woRGB(41, 41, 41)
    public static let neutral850 = woRGB(33, 33, 35)
    public static let neutral900 = woRGB(15, 15, 15)
    public static let neutral1000 = woRGB(0, 0, 0)

    // neutral-bluish ×19（-60 的 dark 覆盖为 rgb(249,250,251)，浅色档无关；
    //  -600 值取 design-platform.css 原章 rgb(129,133,140)，T.1 表该行误植为 -60 的值，对拍表已裁定挂复核）
    public static let neutralBluish00 = woRGB(255, 255, 255)
    public static let neutralBluish50 = woRGB(249, 250, 251)
    public static let neutralBluish60 = woRGB(245, 246, 247)
    public static let neutralBluish75 = woRGB(241, 243, 245)
    public static let neutralBluish100 = woRGB(235, 238, 242)
    public static let neutralBluish150 = woRGB(233, 236, 242)
    public static let neutralBluish200 = woRGB(225, 229, 238)
    public static let neutralBluish300 = woRGB(207, 211, 214)
    public static let neutralBluish400 = woRGB(173, 178, 184)
    public static let neutralBluish500 = woRGB(151, 157, 166)
    public static let neutralBluish600 = woRGB(129, 133, 140)
    public static let neutralBluish700 = woRGB(97, 102, 107)
    public static let neutralBluish750 = woRGB(67, 69, 74)
    public static let neutralBluish800 = woRGB(53, 54, 56)
    public static let neutralBluish850 = woRGB(44, 44, 46)
    public static let neutralBluish875 = woRGB(35, 35, 36)
    public static let neutralBluish900 = woRGB(27, 27, 28)
    public static let neutralBluish950 = woRGB(21, 21, 23)
    public static let neutralBluish1000 = woRGB(15, 17, 21)

    // red ×6
    public static let red50 = woRGB(254, 242, 242)
    public static let red100 = woRGB(254, 226, 226)
    public static let red400 = woRGB(242, 90, 90)
    public static let red500 = woRGB(239, 68, 68)
    public static let red600 = woRGB(236, 19, 19)
    public static let red900 = woRGB(87, 12, 12)
}

// MARK: - T.2 语义别名（--dsw-alias-*，浅色档；对应 enum WOAlias）

public enum WOAlias {
    // bg-*
    public static let bgBase = WOStatic.neutralBluish00
    public static let bgLayer1 = WOStatic.neutralBluish00
    public static let bgLayer2 = WOStatic.neutralBluish00
    public static let bgLayer3 = WOStatic.neutralBluish00
    public static let bgMask1 = woRGBA(0, 0, 0, 0.24)
    public static let bgMask2 = woRGBA(0, 0, 0, 0.12)
    public static let bgMask3 = woRGBA(0, 0, 0, 0.48)
    public static let bgMaskPhoto = woRGBA(0, 0, 0, 0.88)
    public static let bgMaskDrop = woRGBA(255, 255, 255, 0.7)
    public static let bgModulePlatform = WOStatic.neutralBluish60
    public static let bgMultiSelect = WOStatic.neutralBluish60
    public static let bgOverlay = WOStatic.neutralBluish150
    public static let bgSkeleton = woRGBA(0, 0, 0, 0.04)

    // border-*
    public static let borderInverted2 = woRGBA(0, 0, 0, 0)
    public static let borderInverted = woRGBA(0, 0, 0, 0)
    public static let borderL1 = woRGBA(0, 0, 0, 0.04)
    public static let borderL2DarkmodeThin = woRGBA(0, 0, 0, 0.1)
    public static let borderL2 = woRGBA(0, 0, 0, 0.1)
    public static let borderL3 = woRGBA(0, 0, 0, 0.12)
    public static let borderL4 = woRGBA(0, 0, 0, 0.16)

    // brand-*
    public static let brandPrimaryInvert = WOStatic.neutralBluish1000
    /// 上游手滑名 --dsw-alias-brand-primary-new-colorprimary-new-color 照录
    public static let brandPrimaryNewColorprimaryNewColor = woRGB(65, 118, 230)
    public static let brandPrimary = WOStatic.neutralBluish1000
    public static let brandText = WOStatic.neutralBluish1000

    // button-*
    public static let buttonContrastFill = WOStatic.neutralBluish700
    public static let buttonElevatedFill = WOStatic.neutralBluish00
    public static let buttonFloatingFill = WOStatic.neutralBluish00
    public static let buttonFloatingHover = WOStatic.neutralBluish75
    public static let buttonGhostActiveBorder = WOStatic.neutralBluish500
    public static let buttonGhostActiveFill = WOStatic.neutralBluish100
    public static let buttonGhostActiveHover = WOStatic.neutralBluish150
    public static let buttonInfoFill = WOStatic.deepseek500
    public static let buttonInfoHover = WOStatic.deepseek400
    public static let buttonPrimaryDimmed = WOStatic.neutralBluish100
    public static let buttonPrimaryFill = WOAlias.brandPrimary
    public static let buttonPrimaryHover = WOStatic.neutralBluish750
    public static let buttonToolBarFillInvisible = woRGBA(31, 31, 31, 0.36)
    public static let buttonToolBarFill = woRGBA(84, 85, 87, 0.5)
    public static let buttonToolBarHover = woRGBA(84, 85, 87, 0.6)

    // interactive-*
    public static let interactiveBgActive = woRGBA(38, 49, 72, 0.1)
    public static let interactiveBgHoverAccent = woRGBA(38, 49, 72, 0.14)
    public static let interactiveBgHoverDanger = woRGBA(236, 19, 19, 0.05)
    public static let interactiveBgHoverSolid = WOStatic.neutralBluish75
    public static let interactiveBgHover = woRGBA(38, 49, 72, 0.06)

    // label-*
    public static let labelCaption = WOStatic.neutralBluish400
    public static let labelDimmed = WOStatic.neutralBluish200
    public static let labelPrimaryBluish = WOStatic.blue900
    public static let labelPrimaryDimmed = WOStatic.neutralBluish950
    public static let labelPrimaryForeground = WOStatic.neutralBluish00
    public static let labelPrimaryInverted = WOStatic.neutralBluish00
    public static let labelPrimary = WOStatic.neutralBluish1000
    public static let labelSecondary = WOStatic.neutralBluish700
    public static let labelTertiary = WOStatic.neutralBluish600

    // markdown-*
    public static let markdownCitation = WOStatic.neutralBluish100
    public static let markdownCodeBlockBanner = WOStatic.neutralBluish50
    public static let markdownCodeBlock = WOStatic.neutralBluish50
    public static let markdownCodeSegmentSelected = WOStatic.neutralBluish00
    public static let markdownCodeSegmentUnselected = WOStatic.neutralBluish75
    public static let markdownInlineCode = WOStatic.neutralBluish100
    public static let markdownPlaceholder = WOStatic.neutralBluish60
    public static let markdownTag = WOStatic.neutralBluish75

    // scrollbar-*
    public static let scrollbarBgL1 = WOStatic.neutral200
    public static let scrollbarBgL2 = WOStatic.neutral200
    public static let scrollbarHoverL1 = WOStatic.neutral300
    public static let scrollbarHoverL2 = WOStatic.neutral300

    // state-*
    public static let stateBusinessPrimary = WOStatic.deepseek500
    public static let stateBusinessTertiary = WOStatic.deepseek100
    public static let stateErrorPrimary = WOStatic.red600
    public static let stateErrorSecondary = WOStatic.red400
    public static let stateSuccessPrimary = WOStatic.green500
    public static let stateSuccessSecondary = WOStatic.green400
    public static let stateSuccessTertiary = WOStatic.green100
    public static let stateWarnLabel = WOStatic.amber600
    public static let stateWarnPrimary = WOStatic.amber500
    public static let stateWarnSecondary = WOStatic.amber400
    public static let stateWarnTertiary = WOStatic.amber100

    // toast / tooltip
    public static let toastBg = WOStatic.neutralBluish800
    public static let tooltipBg = WOStatic.neutralBluish850
}

// MARK: - T.2 具象（--dsw-specific-*，浅色档；对应 enum WOSpecific）

public enum WOSpecific {
    public static let bubbleHighlight = WOStatic.deepseek200
    public static let bubble = WOStatic.deepseek50
    public static let inputMajor = WOStatic.neutralBluish00
    public static let loginInput = WOStatic.neutralBluish50
    public static let menu = WOAlias.bgLayer3
    public static let selector = WOStatic.neutralBluish60
    public static let sidebarFill = WOStatic.neutralBluish50
    public static let sidebarNavItemActiveAccent = WOStatic.deepseek100
    public static let sidebarNavItemActive = WOStatic.neutralBluish100
    public static let sidebarNavItemHover = WOStatic.neutralBluish75
    public static let tip = WOStatic.neutralBluish60
}

// MARK: - 字号阶梯（细读文档行 441，13 档；对应 enum WOType）

public struct WOTypeSpec {
    public let weight: Font.Weight
    public let size: CGFloat
    public let lineHeight: CGFloat
}

public enum WOType {
    public static let xl24 = WOTypeSpec(weight: .semibold, size: 24, lineHeight: 32)
    public static let l20 = WOTypeSpec(weight: .medium, size: 20, lineHeight: 28)
    public static let m18 = WOTypeSpec(weight: .medium, size: 16, lineHeight: 28)
    public static let base16 = WOTypeSpec(weight: .regular, size: 16, lineHeight: 24)
    public static let baseStrong16 = WOTypeSpec(weight: .medium, size: 16, lineHeight: 24)
    public static let s14 = WOTypeSpec(weight: .regular, size: 14, lineHeight: 22)
    public static let sStrong14 = WOTypeSpec(weight: .medium, size: 14, lineHeight: 22)
    public static let xs13 = WOTypeSpec(weight: .regular, size: 13, lineHeight: 20)
    public static let xsStrong13 = WOTypeSpec(weight: .medium, size: 13, lineHeight: 20)
    public static let xxs12 = WOTypeSpec(weight: .regular, size: 12, lineHeight: 18)
    public static let xxsStrong12 = WOTypeSpec(weight: .medium, size: 12, lineHeight: 18)
    public static let xxxs11 = WOTypeSpec(weight: .regular, size: 11, lineHeight: 14)
    public static let xxxsStrong11 = WOTypeSpec(weight: .medium, size: 11, lineHeight: 14)
}

// MARK: - 字体链（base.css，细读文档行 397-398）

public enum WOFontFamily {
    /// --dsw-font-family（正文链，照录 CSS 串）
    public static let text = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei', 'Helvetica Neue', Helvetica, Arial, sans-serif"
    /// --ds-font-family-code（代码链，照录 CSS 串；上游注释：刻意不带裸 monospace 尾，否则 Windows CJK 回退宋体）
    public static let code = "'SF Mono', 'JetBrains Mono', 'Fira Code', Consolas, 'Liberation Mono', Menlo, Courier, 'PingFang SC', 'Microsoft YaHei'"
}

// MARK: - Elevation 三件套 + mask-blur（细读文档行 349/438；对应 enum WOElevation）

public struct WOShadowSpec {
    public let x: CGFloat
    public let y: CGFloat
    public let blur: CGFloat
    public let opacity: Double
    public init(x: CGFloat, y: CGFloat, blur: CGFloat, opacity: Double) {
        self.x = x; self.y = y; self.blur = blur; self.opacity = opacity
    }
}

public struct WOElevationSpec {
    /// 0.5px 发丝描边色（dsh --dsw-elevation-stroke-color 默认 alias-border-l4，组件可重绑）
    public let strokeColor: Color
    /// 0.5px 发丝描边宽（dsh: 0 0 0 0.5px）
    public let strokeWidth: CGFloat
    public let shadows: [WOShadowSpec]
}

public enum WOElevation {
    /// --dsw-elevation-panel
    public static let panel = WOElevationSpec(
        strokeColor: WOAlias.borderL4, strokeWidth: 0.5,
        shadows: [WOShadowSpec(x: 0, y: 3, blur: 8, opacity: 0.03),
                  WOShadowSpec(x: 0, y: 0, blur: 16, opacity: 0.02)])
    /// --dsw-elevation-prominent
    public static let prominent = WOElevationSpec(
        strokeColor: WOAlias.borderL4, strokeWidth: 0.5,
        shadows: [WOShadowSpec(x: 0, y: 3, blur: 8, opacity: 0.04),
                  WOShadowSpec(x: 0, y: 0, blur: 20, opacity: 0.05)])
    /// --dsw-elevation-soft
    public static let soft = WOElevationSpec(
        strokeColor: WOAlias.borderL4, strokeWidth: 0.5,
        shadows: [WOShadowSpec(x: 0, y: 4, blur: 16, opacity: 0.03),
                  WOShadowSpec(x: 0, y: 0, blur: 24, opacity: 0.03)])
    /// --dsw-mask-blur
    public static let maskBlur: CGFloat = 2
}

// MARK: - 动效基础参数（base.css，细读文档行 399；环 1 Motion.swift 引用）

public enum WOMotionBase {
    /// --ds-ease-in-out: cubic-bezier(0.4, 0, 0.2, 1)——全库唯一曲线
    public static let easeInOutControlPoints: (Double, Double, Double, Double) = (0.4, 0, 0.2, 1)
    /// --ds-transition-duration
    public static let duration: Double = 0.2
    /// --ds-transition-duration-fast
    public static let durationFast: Double = 0.1
    /// --ds-transition-duration-slow
    public static let durationSlow: Double = 0.3
}

// MARK: - 滚动条全局规格（scrollbar.css，细读文档行 344；thumb/hover 颜色见 WOAlias.scrollbar*）

public enum WOScrollbar {
    /// --dsh-scrollbar-width（组件级 l2 重绑钩子归环 2，T.4 拍板）
    public static let width: CGFloat = 8
}
