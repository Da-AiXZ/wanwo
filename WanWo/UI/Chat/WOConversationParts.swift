//
//  WOConversationParts.swift
//  WanWo
//
//  R2c 对话区全量批 —— 对话域共享小件（digest-H 原型逐值；引擎零改动）：
//  - WOEntryModifier：消息入场 mInL/mInR（.55s out 曲线 translateX ±16 + scale .95，
//    digest-H §4 消息入场；reduceMotion 直达终态）；附件 chip 复用为 fadeUp .35s
//  - WOShimmerText：「深度求索中...」流光文字（1.8s 蓝→浅蓝渐变带 masked，
//    digest-H turn-status；reduceMotion 恒色）
//  - WOSweepModifier：思考披露运行中白色扫光（2.6s 循环，digest-H .think）
//  - WOAssistantAvatar：Bot 22px 圆形渐变头像（135deg #679EFE→#4176E6 =
//    deepseek400→deepseek500，digest-H 消息区节）
//  - WOTurnUsagePill：轮次尾用量/用时 pill（TurnUsagePanel.tsx 语义；
//    数据源 = 投影器 TurnUsageSummary，TTFT/吞吐/模型路由事件流无记录 → 行缺席，
//    dsh「组缺席」口径，见 ConversationProjector.TurnUsageSummary 头注）
//  - WOStatsDock：composer 下方状态条（恒渲染=用户既定裁定；数据源 VM.statsLine
//    —— settled 引用，流式 delta 不触发变化；dsh StatsLine dock 槽语义）
//

import SwiftUI

// MARK: - 消息入场（mInL/mInR；digest-H §4：translateX ±16 + scale .95，.55s out）

/// out 曲线（digest-H --out: cubic-bezier(.16,1,.3,1)）——入场动画专用，
/// 与 WOMotion.bezier（通用 .4,0,.2,1）分立：原型对消息入场单独拍板该曲线。
private func woEntryCurve(_ duration: Double) -> Animation {
    .timingCurve(0.16, 1, 0.3, 1, duration: min(duration, WOMotion.maxDuration))
}

struct WOEntryModifier: ViewModifier {
    var offset: CGSize
    var scale: CGFloat = 0.95
    var duration: Double
    /// 批12+回归八校（点4 手术）：入场级联延迟——同批落盘的思考（0）与
    /// 工具（0.3s）错峰入场，视觉上"思考先上屏、工具随后各自入场"。
    var delay: Double = 0
    /// 一次性入场门（animate=false 直达终态——历史/已播节点不重播）。
    var animate: Bool
    /// 批12+回归七校：入场决策诊断行（非 nil 时 onAppear 落
    /// Documents/entry-diag.log 一行；宿主仅对未 seen 节点传值）。
    var diag: String? = nil
    /// 动画结束后回调（宿主记 id 防滚动重建时重播；nil = 不需要）。
    var onSeen: (() -> Void)?

    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(offset: CGSize, scale: CGFloat = 0.95, duration: Double,
         delay: Double = 0, animate: Bool, diag: String? = nil,
         onSeen: (() -> Void)? = nil) {
        self.offset = offset
        self.scale = scale
        self.duration = duration
        self.delay = delay
        self.animate = animate
        self.diag = diag
        self.onSeen = onSeen
        _shown = State(initialValue: !animate)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : scale)
            .offset(x: shown ? 0 : offset.width,
                    y: shown ? 0 : offset.height)
            .onAppear {
                // 批12+回归七校：shown 终态（animate=false）也登记 seen——
                // 配合宿主"单一身份入场门"（常驻 modifier，animate 随 seen
                // 翻转），消灭 onSeen 换枝时的视图重建（二次动画嫌疑源）。
                if let diag { WOEntryDiag.event(diag) }
                if shown {
                    onSeen?()
                } else if reduceMotion {
                    // R6：减弱动态直达终态（无过渡），seen 即刻登记。
                    shown = true
                    onSeen?()
                } else {
                    withAnimation(woEntryCurve(duration).delay(delay)) { shown = true }
                    if let onSeen {
                        // 动画完成后登记 seen（结构体值捕获，无引用循环面）。
                        let interval = UInt64((duration + delay + 0.1) * 1_000_000_000)
                        Task {
                            try? await Task.sleep(nanoseconds: interval)
                            onSeen()
                        }
                    }
                }
            }
    }
}

// MARK: - 深度求索流光行（digest-H turn-status：1.8s 蓝→浅蓝 background-clip:text）

struct WOShimmerText: View {
    let text: String
    var font: Font = .system(size: 14, weight: .medium)

    @State private var sweeping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text)
                .font(font)
                .foregroundColor(WOAlias.stateBusinessPrimary)
        } else {
            Text(text)
                .font(font)
                .foregroundColor(WOAlias.stateBusinessPrimary)
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, WOStatic.deepseek200, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width)
                            .offset(x: sweeping ? geo.size.width : -geo.size.width)
                            .mask(Text(text).font(font))
                    }
                    .allowsHitTesting(false)
                )
                .onAppear {
                    guard !sweeping else { return }
                    // digest-H：1.8s 循环；单周期单向（autoreverses false）。
                    withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                        sweeping = true
                    }
                }
        }
    }
}

// MARK: - 扫光（digest-H .think running：白色渐变带 2.6s 循环，每周期单向）

struct WOSweepModifier: ViewModifier {
    var active: Bool

    @State private var sweeping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    if active, !reduceMotion {
                        LinearGradient(colors: [.clear, WOStatic.neutral00.opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: sweeping ? geo.size.width
                                                : -geo.size.width * 0.6)
                            .allowsHitTesting(false)
                    }
                }
            )
            .clipped()
            .onAppear {
                guard active, !reduceMotion, !sweeping else { return }
                // digest-H .think：2.6s 循环。
                withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                    sweeping = true
                }
            }
    }
}

// MARK: - 助手头像（digest-H：22px 圆形渐变 135deg #679EFE→#4176E6）

struct WOAssistantAvatar: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [WOStatic.deepseek400, WOStatic.deepseek500],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }
}

// MARK: - 轮次尾用量/用时 pill（TurnUsagePanel.tsx:99-235 语义；WO 令牌）

struct WOTurnUsagePill: View {
    let summary: ConversationProjector.TurnUsageSummary

    @State private var open = false

    /// 缓存命中占比（分母 = billedInput；cacheRead 缺席 → 行缺席）。
    private var cacheHitText: String? {
        guard let read = summary.cacheReadTokens, summary.billedInputTokens > 0
        else { return nil }
        return "\(Int((Double(read) / Double(summary.billedInputTokens) * 100).rounded()))%"
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10))
                Text("已消耗 \(SessionStatsFold.formatTokens(summary.totalTokens)) tok")
                    .font(.system(size: 11, design: .monospaced))
                if summary.runMs > 0 {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(SessionStatsFold.formatDuration(summary.runMs))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundColor(WOAlias.labelSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(WOAlias.bgModulePlatform))
            .overlay(Capsule().strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .woPressable()
        .accessibilityLabel("本轮已消耗 \(summary.totalTokens) tokens")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").font(.system(size: 12))
                    Text("本轮用量")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOAlias.labelPrimary)
                    Spacer()
                    Text("\(summary.totalTokens)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(WOAlias.labelSecondary)
                }
                Divider().opacity(0.5)
                detailRow(label: "输入", value: "\(summary.inputTokens)")
                if let read = summary.cacheReadTokens {
                    detailRow(label: "缓存读", value: "\(read)")
                }
                if let hit = cacheHitText {
                    detailRow(label: "缓存命中", value: hit)
                }
                HStack(alignment: .firstTextBaseline) {
                    detailRow(label: "输出", value: "\(summary.outputTokens)")
                    if let reasoning = summary.reasoningTokens {
                        Text("（含推理 \(reasoning)）")
                            .font(.system(size: 11))
                            .foregroundColor(WOAlias.labelTertiary)
                    }
                }
                if summary.runMs > 0 {
                    detailRow(label: "用时",
                              value: SessionStatsFold.formatDuration(summary.runMs))
                }
            }
            .padding(14)
            .frame(maxWidth: 240, alignment: .leading)
            .background(WOAlias.bgBase)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(WOAlias.labelPrimary)
        }
    }
}

// MARK: - StatsLine dock（composer 下方恒渲染；用户既定裁定 + dsh StatsLine dock 语义）

struct WOStatsDock: View {
    let line: String?

    var body: some View {
        // 恒渲染：无数据时以单空格行盒撑住等高（首条统计出现只填充内容，无高度跳变）。
        // 批12+回归二校（2026-09-24 用户令）：文字在 620 同轴盒内居中——文字
        // 自身对称轴与 dock 卡中心同一条竖线（首版 .leading 被用户截图
        // IMG_2421 判定未对齐：文字短、左对齐时文字中心偏离轴线）。
        Text(line ?? " ")
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(WOAlias.labelTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .accessibilityLabel("会话统计")
    }
}

// MARK: - LED 走字尾随窗（批12+回归五校；思考行 running 专用）
//
//  dsh ReasoningRow.module.css :77-89 data-follow-end 的 SwiftUI 等价：
//  单行窗口右缘钉住内容末端，内容增长时整体向左丝滑滑动（滑动速度=
//  模型思考出字速度，实时）；内容短于窗口时左对齐（min-width:100% 同语义）。

private struct WOLedWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct WOLedTail: View {
    let text: String
    var color: Color
    var font: Font = .system(size: 13)

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: WOLedWidthKey.self,
                                               value: inner.size.width)
                    }
                )
                // 右缘钉住：窗口装得下→左对齐；装不下→整体左移露末端。
                .offset(x: min(0, geo.size.width - textWidth))
                .animation(.linear(duration: 0.12), value: textWidth)
                .frame(width: geo.size.width, height: geo.size.height,
                       alignment: .leading)
        }
        .onPreferenceChange(WOLedWidthKey.self) { textWidth = $0 }
        .clipped()
    }
}

// MARK: - 流光换字状态行（批12+回归五校；用户参考件"流光换字·多文案循环"机制 1:1）
//
//  机制=参考 HTML：光束以 easeInOutQuad 扫过字符槽，字符距光束越近越亮
//  （高斯晕影），光束越过字符中心即刻替换为下一条文案对应字符；扫完 hold
//  再下一条。文案池每次出现洗牌轮换（用户令"每轮随机轮换，不重样"）。

struct WOBeamSwapper: View {
    var font: Font = .system(size: 14, weight: .medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 文案池（全中文=等宽槽；可随时扩充）。
    static let pool: [String] = [
        "深度求索中", "思维链铺设中", "检索脑缓存中", "正在编译直觉",
        "灵感组装中", "脑内风暴中", "翻记忆页中", "大脑风扇加速",
        "想法排队入场", "思路收敛中", "神经元点名中", "直觉对齐中",
        "脑洞装配中", "灵感蒸馏中", "答案呼之欲出", "脑回路通电中",
        "智慧点火中", "思绪高速运转"
    ]

    private static let hold: Double = 0.9
    private static let sweep: Double = 0.55
    private static let spread: CGFloat = 42
    private static let slot: CGFloat = 14

    @State private var order: [String] = []
    @State private var appearAt: Date = .distantPast

    var body: some View {
        Group {
            if reduceMotion || order.isEmpty {
                Text(order.first ?? Self.pool[0])
                    .font(font)
                    .foregroundColor(WOAlias.stateBusinessPrimary)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    slots(at: timeline.date)
                }
            }
        }
        .onAppear {
            order = Self.pool.shuffled()
            appearAt = Date()
        }
    }

    /// 确定性时间线：k=第几轮换字，local=本轮进度；hold 段显当前文案，
    /// sweep 段光束扫过逐字替换为下一条。
    private func slots(at now: Date) -> some View {
        let elapsed = max(0, now.timeIntervalSince(appearAt))
        let cycle = Self.hold + Self.sweep
        let k = Int(elapsed / cycle)
        let local = elapsed - Double(k) * cycle
        let n = order.count
        let from = order.isEmpty ? "" : order[k % n]
        let to = order.isEmpty ? "" : order[(k + 1) % n]
        let slotCount = max(from.count, to.count)
        let contentWidth = CGFloat(slotCount) * Self.slot

        return HStack(spacing: 0) {
            ForEach(0..<slotCount, id: \.self) { i in
                let cx = CGFloat(i) * Self.slot + Self.slot / 2
                let state = slotState(index: i, cx: cx, local: local,
                                      from: from, to: to, contentWidth: contentWidth)
                Text(state.char)
                    .font(font)
                    .foregroundColor(state.color)
                    .shadow(color: state.shadowColor, radius: state.shadowRadius)
                    .frame(width: Self.slot)
            }
        }
    }

    private func slotState(index i: Int, cx: CGFloat, local: Double,
                           from: String, to: String, contentWidth: CGFloat)
        -> (char: String, color: Color, shadowColor: Color, shadowRadius: CGFloat) {
        let charAt: (String) -> String = { s in
            guard i < s.count else { return "" }
            let idx = s.index(s.startIndex, offsetBy: i)
            return String(s[idx])
        }
        // hold 段：当前文案静默（暗灰）。
        guard local >= Self.hold else {
            return (charAt(from), WOAlias.labelTertiary, .clear, 0)
        }
        // sweep 段：光束扫过——亮度随距离衰减，过束即换字。
        let t = min(1, (local - Self.hold) / Self.sweep)
        let et = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let beamX = -Self.spread + (contentWidth + 2 * Self.spread) * CGFloat(et)
        var glow = max(0, 1 - abs(beamX - cx) / Self.spread)
        glow *= glow
        let char = beamX >= cx ? charAt(to) : charAt(from)
        if glow > 0.01 {
            return (char,
                    WOAlias.stateBusinessPrimary.opacity(0.35 + 0.65 * glow),
                    WOAlias.stateBusinessPrimary.opacity(Double(glow) * 0.6),
                    CGFloat(glow) * 5)
        }
        return (char, WOAlias.labelTertiary, .clear, 0)
    }
}

// MARK: - AI 截图图片条（批12+联动，2026-09-26）

/// AI 回复内嵌截图的渲染条（`![…](wanwo://browser/…)` 经 WOChatView
/// .splitAgentImages 提取后传入）。文件解析走 WanwoURLSchemeHandler
/// .resolveWanwoURL（与 WKWebView 内同源同语义：活动会话四桶→全局扫描）；
/// tap 全屏放大（简版——黑底 scaledToFit，点按关闭）。
struct WOAgentImageStrip: View {
    let sources: [URL]

    private struct ZoomItem: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    @State private var zoom: ZoomItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sources, id: \.absoluteString) { url in
                thumb(url)
            }
        }
        .fullScreenCover(item: $zoom) { item in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            }
            .onTapGesture { zoom = nil }
        }
    }

    /// 单图缩略：解析宿主文件 → UIImage；解析失败/读取失败显示占位行
    /// （不崩不空转——截图文件可能被会话清理驱逐）。
    @ViewBuilder
    private func thumb(_ url: URL) -> some View {
        if let fileURL = WanwoURLSchemeHandler.resolveWanwoURL(url),
           let image = UIImage(contentsOfFile: fileURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 260)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(WOAlias.bgModulePlatform.opacity(0.6), lineWidth: 0.5))
                .onTapGesture { zoom = ZoomItem(image: image) }
                .accessibilityLabel("AI 浏览器截图，点按放大")
        } else {
            Label("截图已不可用", systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AI 浏览轻提示胶囊（批12+联动B 2026-09-27 用户参考件 1:1）

/// AI 自主干活时的轻提示（dock 上方一行，不展开右栏不弹卡——两路展开语义的
/// "不打扰"路）。动画=用户参考件（网页加载动效.txt）1:1：闪烁圆点（1.4s
/// opacity 呼吸）+ 静态文案 + 域名逐字符波浪（translateY -8px、相邻延迟
/// 0.13s、单字符周期 1.2s、hold 0.5s、总周期 2.87s、cubic-bezier(0.45,0,
/// 0.55,1) 近似、等宽字体）。TimelineView 驱动（30fps 足够；字符数=域名长度，
/// 非热路径）。reduceMotion=静态直出。
struct WOAgentHintPill: View {
    let title: String
    let domain: String

    /// 参考件节拍（秒）。
    private static let charDelay = 0.13
    private static let charRise = 1.20
    private static let hold = 0.50
    /// 总周期 = 9×0.13 + 1.20 + 0.50（域名字符数决定；实例计算——参考件
    /// 域名 10 字符 ≈ 2.87s）。
    private var totalCycle: Double {
        Double(max(0, domain.count - 1)) * Self.charDelay + Self.charRise + Self.hold
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if reduceMotion {
                Circle().frame(width: 5, height: 5).foregroundStyle(.secondary)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.4) / 1.4
                    let opacity = 1.0 - 0.8 * abs(sin(t * .pi))
                    Circle().frame(width: 5, height: 5)
                        .foregroundStyle(WOAlias.labelSecondary.opacity(opacity))
                }
            }
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            waveText
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14).fill(WOAlias.bgLayer2))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(domain)")
    }

    /// 域名逐字符波浪（参考件 keyframes：0→0 / 21%→-8px / 42%→0 / 100%→0；
    /// 相位 = 全局时间 − i×0.13 对总周期取模）。SwiftUI Text 逐字符独立渲染
    /// （monospaced 防抖动）。
    @ViewBuilder
    private var waveText: some View {
        if reduceMotion {
            Text(domain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 1) {
                    ForEach(Array(domain.enumerated()), id: \.offset) { index, ch in
                        let phase = (now - Double(index) * Self.charDelay)
                            .truncatingRemainder(dividingBy: totalCycle)
                        let offset = waveOffset(phase: phase < 0 ? phase + totalCycle : phase)
                        Text(String(ch))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .offset(y: offset)
                    }
                }
            }
        }
    }

    /// 参考件单字符位移曲线（秒→px；21% 到顶 -8px，42% 回落，其后保持）。
    private func waveOffset(phase: Double) -> CGFloat {
        let p = phase / totalCycle
        switch p {
        case 0..<0.21:
            let k = p / 0.21
            return CGFloat(-8 * sin(k * .pi / 2))
        case 0.21..<0.42:
            let k = (p - 0.21) / 0.21
            return CGFloat(-8 * cos(k * .pi / 2))
        default:
            return 0
        }
    }
}
