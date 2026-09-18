//
//  Motion.swift
//  WanWo
//
//  环 1 动效基建——全库唯一动画供货处。
//  纪律（九环链横切）：环 2-8 组件的任何动画只准引用本文件常量/modifier，
//  禁裸 withAnimation 手写参数、禁无 value 的 .animation()（红线 4）、禁嵌套 withAnimation。
//  依据：ui-rebuild-plan-v3.md 环 1 | ui-motion-aesthetics-playbook.md 手法篇 4.1-4.9 + R2/R3 + 红线 7 条
//  拍板：Hero 四式=动效基准（SwiftUI 原生 1:1 复刻，Hero 库 UIKit 不引入）；
//        曲线全库唯一 cubic-bezier(0.4,0,0.2,1)；级联 40ms 步进/scale 0.5→1；按压 0.97；
//        Reduce Motion 做（2026-09-19 拍板）。
//

import SwiftUI

// MARK: - 全库动效常量（手册 R2 时长五档 + R3 曲线档位；红线 7：同类交互参数逐字节一致）

public enum WOMotion {

    // ── R2 时长五档（标准值；区间依据见手册 R2 表）──
    /// T0 即时（高频键盘操作、命令面板）
    public static let t0: Double = 0
    /// T1 微交互 120-200ms（按压/hover/开关/勾选）
    public static let t1: Double = 0.15
    /// T2 状态过渡 200-300ms（菜单/popover/toast/页签切换/列表增删）
    public static let t2: Double = 0.22
    /// T3 面板转场 300-450ms（侧栏收展/sheet/卡片↔详情共享元素/键盘伴随）
    public static let t3: Double = 0.35
    /// T4 全屏/hero 450-550ms（全屏接管/大型共享元素转场；硬上限 600ms）
    public static let t4: Double = 0.5
    /// 全库动画硬上限（"Never >600ms"）
    public static let maxDuration: Double = 0.6

    /// R2 硬规则：出场 = 该档位 × 0.65，且出场只用 opacity/轻位移
    public static func exitDuration(_ tier: Double) -> Double {
        min(tier * 0.65, maxDuration)
    }

    // ── R3 弹簧档位（iPadOS 16.6 兼容形态：response/dampingFraction，禁 iOS17 .smooth/.bouncy）──
    /// 默认（90% 场景）
    public static let standardSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// 按压/极小反馈（快、几乎无回弹）
    public static let pressSpring = Animation.spring(response: 0.2, dampingFraction: 0.9)
    /// 手势释放/拖拽归位（打断混合优化）
    public static let gestureSpring = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.6)
    /// 共享元素/hero（大元素避免回弹，bounce ≤0.3）
    public static let heroSpring = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// 非交互性变化进场（加载、自动出现——不用 spring）
    public static let nonInteractive = Animation.easeOut(duration: t1)
    /// 非交互性变化出场（加速离场 130ms）
    public static let nonInteractiveExit = Animation.easeIn(duration: 0.13)

    // ── 唯一贝塞尔曲线（拍板：Hero 演示 keySplines / dsh / Material 三方同一条）──
    /// 关键帧类动画专用；弹簧类场景用上方 R3 档位
    public static func bezier(duration: Double) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: min(duration, maxDuration))
    }
}

// MARK: - Hero 四式 ①：共享元素变形（matchedGeometryEffect 纪律封装，手册 4.2）
//
// 用法纪律（手册 4.2 坑位清单，review 逐条核对）：
// - 同一 namespace 内 id 必须唯一；重复 id 且都为 source → 运行时警告/破图
// - 转场瞬间源与目标必须同时在树中（ZStack + 条件渲染，不要立刻移除源）
// - 源在 ScrollView 内、目标在外时坐标系会错位——hero 目标一律放全屏 overlay 层
// - "永远存在只换位置"的元素（页签指示器胶囊）：目标侧用 isSource: false
// - 动画一律 WOMotion.heroSpring（配 .woMotion(_:value:) 挂接）

public extension View {
    /// 共享元素标记——源侧（驱动几何）
    func woHeroSource<ID: Hashable>(id: ID, in ns: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id, in: ns, isSource: true)
    }

    /// 共享元素标记——目标侧（跟随几何；内置 zIndex 置顶防转场闪烁，手册 4.2）
    func woHeroTarget<ID: Hashable>(id: ID, in ns: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id, in: ns, isSource: false)
            .zIndex(1)
    }

    /// 完整形态（需要显式控制 isSource 时用）
    func woHero<ID: Hashable>(id: ID, in ns: Namespace.ID, isSource: Bool) -> some View {
        matchedGeometryEffect(id: id, in: ns, isSource: isSource)
    }
}

// MARK: - Hero 四式 ②：级联延迟入场（拍板：40ms 步进 / scale 0.5→1 + opacity 0→1）
//
// 封顶（手册 R2 级联算术）：前 8 项步进，之后随第 8 项同现；7×40ms 步进 + 单项 0.32s = 0.60s 恰触 maxDuration。
// 算术：0.32s 单项时长取 T3 档，贝塞尔唯一曲线驱动（拍板）。

public struct WOCascadeModifier: ViewModifier {
    let index: Int
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        let step = Double(min(max(index, 0), 7)) * 0.04
        content
            .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.5))
            .opacity(appeared ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    // R6：降级为 150ms 淡入，去掉缩放（"Reduce, don't remove"）
                    withAnimation(.easeOut(duration: 0.15)) { appeared = true }
                } else {
                    withAnimation(WOMotion.bezier(duration: 0.32).delay(step)) { appeared = true }
                }
            }
    }
}

public extension View {
    /// 级联入场：index = 项在列表/网格中的序号（0 起）
    func woCascade(index: Int) -> some View {
        modifier(WOCascadeModifier(index: index))
    }
}

// MARK: - Hero 四式 ③：方向转场五式（拍板；AnyTransition 封装）
//
// 位移量分级依据：全屏层级转场（push/cover）允许全幅——拍板五式本身即验收基准；
// 平级切换（slide）用 12px 语义位移（手册场景表"方向性轻位移"）。
// 自创的"从屏幕角落飞入整屏"仍然打回（红线 1 针对无因果对角飞行，与拍板五式不冲突）。

/// 轻位移过渡（自定义 modifier 形态，用于 slide 的 12px 语义位移——AnyTransition.move 做不了限距位移）
public struct WOShift: ViewModifier {
    let x: CGFloat
    let y: CGFloat
    let opacity: Double
    public func body(content: Content) -> some View {
        content.offset(x: x, y: y).opacity(opacity)
    }
}

public enum WOTransition {
    /// push 推挤：新页自右推入 + 淡入；旧页加速淡出（出场 ×0.65，R2）
    public static var push: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity.animation(.easeIn(duration: WOMotion.exitDuration(WOMotion.t3))))
    }

    /// slide 平移：12px 方向性轻位移 + 淡入（平级切换；手册场景表）；参数 dir=1 自右、-1 自左
    public static func slide(directionX: CGFloat = 1) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: WOShift(x: 12 * directionX, y: 0, opacity: 0),
                identity: WOShift(x: 0, y: 0, opacity: 1)),
            removal: .modifier(
                active: WOShift(x: -12 * directionX, y: 0, opacity: 0),
                identity: WOShift(x: 0, y: 0, opacity: 1)))
    }

    /// zoomSlide 退后缩：新页淡入；旧页缩至 0.5 退后 + 淡出（Hero 演示 zoomSlide 语义）
    public static var zoomSlide: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale(scale: 0.5).combined(with: .opacity)
                .animation(.easeIn(duration: WOMotion.exitDuration(WOMotion.t3))))
    }

    /// cover 底部覆盖：新页自底滑上盖住；配合 `woCoverUnderlay` 让被盖页缩暗让位
    public static var cover: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity.animation(.easeIn(duration: WOMotion.exitDuration(WOMotion.t4))))
    }

    /// page 让位：被新页覆盖的下层页缩至 0.7 让位（Hero 演示 page 语义；配合 cover 或专用容器用）
    public static var pageUnderlay: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale(scale: 0.7).combined(with: .opacity))
    }
}

public extension View {
    /// cover/page 组合：本视图作为"被覆盖层"，上层有全屏覆盖时施加缩让（拍板 page 语义：缩 0.7 让位）
    func woCoverUnderlay(isCovered: Bool) -> some View {
        scaleEffect(isCovered ? 0.7 : 1)
    }
}

// MARK: - Hero 四式 ④：按压反馈（拍板 0.97；Emil 标准 0.95-0.98，press 快 release 带 spring）

public struct WOPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            // R6：减弱动态时反馈保留、动效瞬变（"保留轻量反馈，不做全瞬变"的按压特例——scale 仍在，仅无过渡）
            .animation(reduceMotion ? nil : WOMotion.pressSpring, value: configuration.isPressed)
    }
}

public extension View {
    /// 全库按钮/可点击件统一按压反馈（红线：同类交互参数逐字节一致）
    func woPressable() -> some View {
        buttonStyle(WOPressableStyle())
    }
}

// MARK: - 纪律护栏（手册 R5/4.7；红线 4）

public extension View {
    /// 全库唯一的状态动画挂接形态：
    /// - 必须带 value（红线 4：禁无 value 的 .animation()）
    /// - 自动跟随系统"减弱动态效果"降级（拍板 2026-09-19；R6：spring→0.15s easeOut）
    func woMotion<V: Equatable>(_ prefer: Animation, value: V) -> some View {
        modifier(WOMotionAwareModifier(prefer: prefer, value: value))
    }

    /// 阻断上游动画传播到本子树（手册 R5：transaction 阻断）
    func woStaticMotion() -> some View {
        transaction { $0.animation = nil }
    }
}

public struct WOMotionAwareModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let prefer: Animation
    let value: V
    public func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeOut(duration: 0.15) : prefer, value: value)
    }
}
