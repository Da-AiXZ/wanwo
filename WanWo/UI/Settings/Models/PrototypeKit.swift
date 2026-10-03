//
//  PrototypeKit.swift
//  WanWo
//
//  【m7-fix2 · E2】设置·模型分区原型件库——用户 HTML 原型
//  「设置模型配置原型（带动画）.html」逐值翻译的设计令牌 + 原子组件。
//
//  令牌纪律说明（报告登记）：本批唯一视觉基准 = 用户 HTML 原型（派单简报
//  「禁自创」），原型色值与 Theme.swift 令牌不同源（原型为独立设计稿）。
//  处理方式：原型值**集中**在本文件 WOMP 令牌表（单一来源、禁散落硬编码），
//  组件一律引用 WOMP；与 Theme 令牌的取舍对照表进 e2-report.md。
//
//  动效纪律说明（报告登记）：原型全站曲线 --ease: cubic-bezier(.22,1,.36,1)
//  与 Motion.swift 唯一曲线（0.4,0,0.2,1）不同。本批按原型逐值翻译
//  （WOMP.ease(_:)），时长逐值对齐原型（0.58s 折叠 / 0.38s 下拉 chev /
//  0.42s 分区 chev / 0.5s 行入场 / 0.4s 行删除 / 0.5s+0.3s 弹窗），
//  全部 ≤ WOMotion.maxDuration(0.6)。reduceMotion 统一降级 0.15s easeOut。
//
//  触屏红线（2026-09-19 血训）：所有可点目标 ≥44pt（视觉尺寸照原型，
//  命中区经 .frame(minWidth/minHeight: 44) + contentShape 撑满）；
//  hover 只做纯视觉增强（onHover 修饰，触屏路径直达）。
//  iOS 16.6 红线：不用 foregroundStyle / 双参 onChange / iOS17+ API。
//

import SwiftUI

// MARK: - 设计令牌（原型 :root 逐值）

/// 原型令牌（设置·模型分区专用；单一来源，禁在组件内硬编码原型值）。
enum WOMP {

    // ---- 原型 :root 色值（逐值照录）----
    /// --text #0b0b0e
    static let text = woRGB(0x0b, 0x0b, 0x0e)
    /// --text-2 #6b6b76
    static let text2 = woRGB(0x6b, 0x6b, 0x76)
    /// --text-3 #9a9aa5
    static let text3 = woRGB(0x9a, 0x9a, 0xa5)
    /// --blue #2f6fed
    static let blue = woRGB(0x2f, 0x6f, 0xed)
    /// key 状态点绿 #22c55e（原型 .provider-dot）
    static let green = woRGB(0x22, 0xc5, 0x5e)
    /// key 状态点光晕 rgba(34,197,94,.15)
    static let greenHalo = woRGBA(0x22, 0xc5, 0x5e, 0.15)
    /// danger 红 #dc2626（mini-btn.danger / model-err）
    static let red = woRGB(0xdc, 0x26, 0x26)
    /// --line rgba(0,0,0,.1)
    static let line = Color.black.opacity(0.1)
    /// --line-soft rgba(0,0,0,.07)
    static let lineSoft = Color.black.opacity(0.07)
    /// hover 边框加深 rgba(0,0,0,.12)
    static let lineHover = Color.black.opacity(0.12)
    /// editing 边框 rgba(0,0,0,.14)
    static let lineEditing = Color.black.opacity(0.14)
    /// 内联编辑面板底 #f5f5f7（.edit-panel）
    static let editPanelBg = woRGB(0xf5, 0xf5, 0xf7)
    /// 表单卡底 #fafafb（.form-card）
    static let formCardBg = woRGB(0xfa, 0xfa, 0xfb)
    /// 输入占位 #b4b4be（.input::placeholder）
    static let placeholder = woRGB(0xb4, 0xb4, 0xbe)
    /// 输入焦点环 rgba(47,111,237,.13)
    static let blueRing = woRGBA(0x2f, 0x6f, 0xed, 0.13)

    // ---- 原型曲线/时长（逐值照录；全 ≤0.6s）----
    /// 全站唯一曲线 cubic-bezier(.22,1,.36,1)
    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: min(duration, 0.6))
    }
    /// 折叠容器 .58s（.collapsible）
    static let durCollapse: Double = 0.58
    /// 下拉 chev .38s（.select-btn .chev）
    static let durChevSelect: Double = 0.38
    /// 分区 chev .42s（.section-toggle .chev / 行展开 chev）
    static let durChevSection: Double = 0.42
    /// 模型行入场 .5s（modelRowIn）
    static let durRowIn: Double = 0.5
    /// 行删除折叠 .4s（removeModelRow transition）
    static let durRowOut: Double = 0.4
    /// 弹窗主体 .5s / 遮罩 .3s（.modal / .modal-mask）
    static let durModalIn: Double = 0.5
    static let durMask: Double = 0.3
    /// provider 卡入场 .55s / 出场 .45s（.provider-item）
    static let durCardIn: Double = 0.55
    static let durCardOut: Double = 0.45

    /// hex 字节 → 0-1 浮点归一（组件内 hex 色必须经此或 /255.0——
    /// Color(red:green:blue:) 参数域是 0-1，裸 hex 字节越界被钳白，M4② 血训）。
    static func woRGB(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }
    private static func woRGBA(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> Color {
        woRGB(r, g, b).opacity(a)
    }
}

// MARK: - 折叠容器（.collapsible grid-template-rows 0fr→1fr 的 SwiftUI 等价）

/// 原型 .collapsible/.collapsible-inner/.collapsible-content 三层结构的
/// SwiftUI 等价：实测自然高度 → 高度 0↔natural 动画（.58s 原型曲线）+
/// 内容 opacity/translate 入场（开：opacity .4s ease .1s 延迟（原型 :307）；
/// 关：opacity .28s ease（原型 :302））。
///
/// 裁切（m7-fix2 M4①）：原型 `.collapsible-inner { overflow: hidden }` +
/// `body.select-open .collapsible-inner { overflow: visible }`（:297/:311）。
/// SwiftUI 等价：mask 替代 .clipped()——渲染中高度（GeometryReader 实测
/// 逐帧跟随动画值）< 自然高（折叠中/收起）→ 精确幕帘裁切；**完全展开
/// （渲染高==自然高）→ 底部留 600pt headroom**，让 WOSelect 下拉弹层溢出
/// 容器边界（原型 overflow visible 语义），同时开合动画期保持幕帘不穿帮。
///
/// 批6 G3（b6 第三轮根治）：动画接线重构。旧实现把 `.animation(.58s,
/// value: open)` 与 `.animation(.28s/.4s, value: open)` **同值叠置**在一条
/// 修饰链上——SwiftUI 对同值叠置的动画覆盖语义不保证内外次序，真机上
/// frame 高度的 .58s 曲线可被外层 0.28s 覆盖（收起「瞬间闪上」）甚至整层
/// 失效（布局瞬跳、只剩 opacity 在动 = 用户实证「白色区域直接闪上来，编辑卡
/// 本身的收起动画正常执行」）；纯 toggle 调用点（添加卡/自定义设置）不包
/// withAnimation 时全靠隐式注入 → 无动画路径。现改为 **作用域不相交的两层**：
/// ① opacity + 自身动画（内层 Group，scope 只含 opacity）；② frame+offset +
/// 自身动画（外层，scope 不再包含内层动画各自的可动画值之外的重叠歧义——
/// 即使覆盖语义反转，也只会退化为全 .58s 的同步动画，**任何语义下都不存在
/// 无动画路径**）。同时所有 toggle 调用点一律补显式 withAnimation（见
/// WOSectionToggle / ProvidersSectionView / WOSelect——隐式注入只作兜底）。
struct WOCollapsible<Content: View>: View {

    var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: () -> Content

    /// 内容自然高度（fixedSize 理想高度，闭态也按理想测量）。
    @State private var naturalHeight: CGFloat = 0
    /// 渲染中高度（frame 动画逐帧实测；驱动 mask 幕帘）。
    @State private var renderedHeight: CGFloat = 0

    var body: some View {
        // 内层 Group：opacity 动画作用域止于此（scope 只含 opacity，
        // 与外层 frame 动画作用域不相交——同值叠置歧义根除，见结构注释）。
        Group {
            content()
                // fixedSize：保证闭态下也按理想高度测量（0 高提案不会压缩文本
                // 导致重开时两段跳变）。
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { naturalHeight = geo.size.height }
                            .onChange(of: geo.size.height) { naturalHeight = $0 }
                    }
                )
                .opacity(open ? 1 : 0)
                // 透明度逐值对齐原型 collapsible-content：开 .4s ease .1s 延迟
                // （:307）/ 关 .28s ease（:302）——关闭快速隐去，杜绝灰面板
                // 半透明期白卡底透色（M4⑥ 白闪根因之一）。
                .animation(reduceMotion
                           ? .easeOut(duration: 0.15)
                           : (open ? WOMP.ease(0.4).delay(0.1) : WOMP.ease(0.28)),
                           value: open)
        }
        .frame(height: open ? naturalHeight : 0, alignment: .top)
        // 渲染中高度实测（背景挂在 frame 之后 → 读到动画逐帧值）。
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { trackRendered(geo.size.height) }
                    .onChange(of: geo.size.height) { trackRendered($0) }
            }
        )
        .offset(y: open ? 0 : -6) // 收起时内容随手上移（原型 content 态）
        // 高度/位移：原型 grid-template-rows .58s（开合同曲线）。唯一外层
        // open 动画（scope = frame + offset）。
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durCollapse),
                   value: open)
        // overflow hidden ⇄ visible 的 SwiftUI 等价（见结构注释）。
        .mask(alignment: .top) {
            Rectangle().frame(height: maskHeight)
        }
        // 高度基准变化（内容增删行/子面板开合的理想高变化）——并入同曲线事务：
        // 布局与视觉同一时钟（"自定义设置"子面板 .58s 展开时外层高度平滑跟随，
        // 不再瞬跳）。【2026-10-03 重诊断】批9 S2 同款一行；当时被外层
        // WORemoveFold 的同款 nil 瞬传掩盖（按钮供值层=外层钉高），双层同修
        // 后此行才真正生效。
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durCollapse),
                   value: naturalHeight)
    }

    /// 渲染中高度逐帧追踪（禁动画事务——mask 必须紧贴动画帧，不滞后）。
    private func trackRendered(_ height: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { renderedHeight = height }
    }

    /// mask 高：折叠中/收起（渲染高 < 自然高）→ 精确幕帘；完全展开 →
    /// 底部 headroom 放行下拉弹层溢出（原型 select-open overflow visible）。
    private var maskHeight: CGFloat {
        let collapsed = renderedHeight < naturalHeight - 0.5
        return collapsed ? renderedHeight : renderedHeight + 600
    }
}

// MARK: - 出场折叠（.removing：remeasure→height 0 + opacity 0 + scale .97）

/// 原型 removeModelRow(:1313-1334) 出场形态的 SwiftUI 等价：
/// removing 时实测高度动画折叠到 0（.4s）+ opacity 0（.28s）+ scale .97，
/// 调用方 420ms 后真正移除数据。marginTop 语义由调用方把间距放进本视图
/// 内部（padding），折叠时一并归零。
struct WORemoveFold: ViewModifier {

    let removing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 逐帧实测高（仅 removing 起点捕获用；常态不参与布局）。
    @State private var liveHeight: CGFloat = 0
    /// 钉高：nil=常态零干预（透传——按钮/下方兄弟直接跟随内层动画）；
    /// 非 nil=折叠期钉住（remeasure→fold 两步）。
    @State private var pinnedHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            // fixedSize：折叠起点按理想高度测量（同 WOCollapsible 注）。
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { liveHeight = geo.size.height }
                        .onChange(of: geo.size.height) { liveHeight = $0 }
                }
            )
            // 【2026-10-03 重诊断（b3 终局根修 v2）】常态不再钉高：旧实现
            // `.frame(height: removing ? 0 : naturalHeight)` 把行卡钉在逐帧
            // 实测值上 + `.animation(nil, value: naturalHeight)` 瞬传——内层
            // WOCollapsible 的 .58s 展开动画被本层逐帧测量→逐帧瞬钉，按钮
            // 1-2 帧即到终态（瞬跳），内层幕帘/淡入照播（"面板慢悠悠"）=
            // 两口时钟分家的真凶层。批9 只修内层 WOCollapsible:176、本层
            // 原样 → 真机无差别（用户实证"批9 没区别"）。诊断页样本从不
            // 套本修饰器（grep 实证 0 处）→ 样本全部正常，差异点唯一。
            // 现常态透传（height nil=不约束），折叠改两步：先瞬钉当前
            // 实测高（禁动画事务），下一拍再曲线归零——remeasure→fold
            // 语义原样保留（ModelCatalogEditorView 行折叠/resetting 同享）。
            .frame(height: pinnedHeight, alignment: .top)
            .opacity(removing ? 0 : 1)
            .scaleEffect(removing ? 0.97 : 1)
            .clipped()
            .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durRowOut),
                       value: removing)
            .onChange(of: removing) { r in
                var instant = Transaction()
                instant.disablesAnimations = true
                if r {
                    withTransaction(instant) { pinnedHeight = liveHeight }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion
                                      ? .easeOut(duration: 0.15)
                                      : WOMP.ease(WOMP.durRowOut)) {
                            pinnedHeight = 0
                        }
                    }
                } else {
                    withTransaction(instant) { pinnedHeight = nil }
                }
            }
    }
}

// MARK: - 原型输入框（.input：r12 边框 line、焦点蓝环 3px .13）

/// 原型 .input 单行输入（pad 11/14、r12、focus 蓝边+3px 环）。
/// 触屏：整框高 ≥44pt（frame minHeight 44）。
struct WOProtoInput: View {

    var placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var keyboard: UIKeyboardType = .default
    var monospaced: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: $text,
                          prompt: Text(placeholder).foregroundColor(WOMP.placeholder))
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .font(.system(size: 13.5))
        .foregroundColor(WOMP.text)
        .focused($focused)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? WOMP.blue : WOMP.line, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? WOMP.blueRing : Color.clear, lineWidth: 3))
        .animation(.easeOut(duration: 0.25), value: focused)
    }
}

// MARK: - 字段组（.field：label 12.8 #55555f + 内容）

/// 原型 .field 壳（label 12.8px #55555f、间距 8）。
struct WOProtoField<Content: View>: View {

    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12.8))
                .foregroundColor(woLabelField) // #55555f
            content()
        }
    }

    private var woLabelField: Color {
        Color(red: 0x55 / 255.0, green: 0x55 / 255.0, blue: 0x5f / 255.0)
    }
}

// MARK: - 按钮（ghost-btn / mini-btn / btn.primary / link / add-provider-btn / add-model-btn）

/// 原型 .ghost-btn（pad 8/14、r10、边框 line；hover #f5f5f7）。
/// 触屏：命中区 ≥44pt（视觉居中不变）。
struct WOGhostButton: View {

    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(WOMP.text)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? WOMP.editPanelBg : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? Color.black.opacity(0.2) : WOMP.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .frame(minHeight: 44) // 触屏命中区
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .accessibilityLabel(title)
    }
}

/// 原型 .mini-btn（pad 6/12、r8、font 12.5；danger 变体红字红边）。
/// 触屏：命中区 ≥44pt。
struct WOMiniButton: View {

    let title: String
    var danger: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(danger ? WOMP.red : WOMP.text)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering
                          ? (danger ? WOMP.red.opacity(0.07) : WOMP.editPanelBg)
                          : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(danger ? WOMP.red.opacity(0.25) : WOMP.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .frame(minHeight: 44) // 触屏命中区
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .accessibilityLabel(title)
    }
}

/// 原型 .btn.primary（黑底白字 pad 9/22 r11 + 0 4 14 rgba(0,0,0,.16) 阴影；
/// hover #23232b）与 .btn.ghost 共用外壳。
/// m7-fix2 M4④：补禁用态视觉（opacity .4，同 WOAddModelButton 先例）——
/// 就绪门未过时保存钮肉眼可辨（此前禁用无任何视觉差，用户"点了没反应"）。
struct WOProtoButton: View {

    enum Kind { case primary, ghost }

    let title: String
    var kind: Kind = .ghost
    var disabled: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(kind == .primary ? Color.white : WOMP.text)
                .padding(.horizontal, 22)
                .frame(minWidth: 44, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(kind == .ghost ? WOMP.line : Color.clear, lineWidth: 1))
                .shadow(color: kind == .primary ? Color.black.opacity(0.16) : .clear,
                        radius: 14, y: 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .frame(minHeight: 44) // 触屏命中区
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.22), value: hovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        switch kind {
        case .primary:
            return hovering ? WOMP.woRGB(0x23, 0x23, 0x2b) : WOMP.text
        case .ghost:
            return hovering ? WOMP.woRGB(0xf4, 0xf4, 0xf6) : Color.white
        }
    }
}

/// 原型 .link（font 12.8 text-3；hover 变蓝）。
/// 触屏：命中区 ≥44pt。
struct WOLinkButton: View {

    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.8))
                .foregroundColor(hovering ? WOMP.blue : WOMP.text3)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .frame(minHeight: 44) // 触屏命中区（原型 12px 链接的触屏红线补足）
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.22), value: hovering)
        .accessibilityLabel(title)
    }
}

/// 原型 .add-provider-btn（虚线边框全宽、pad 17、r14；hover 底纹+边加深）。
struct WODashedAddButton: View {

    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5))
                .foregroundColor(foreground)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .padding(.vertical, 10)
                .background(backgroundFill)
                // strokeBorder 无 dash 参数——虚线改走 .stroke(_:style:)。
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(dashColor,
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: hovering)
        .accessibilityLabel(title)
    }

    // 子表达式拆分（CI 超时教训：大三元链导致 type-check 超时）。
    // m7-fix2 M4②：Color(red:green:blue:) 参数域 0-1——裸 hex 字节 0x4a=74
    // 越界被钳到 1.0 → 三通道全 1.0 = 纯白（用户实证）。改走 woRGB 归一。
    private var foreground: Color {
        hovering ? WOMP.text : WOMP.woRGB(0x4a, 0x4a, 0x55) // 原型 #4a4a55
    }
    private var backgroundFill: Color {
        hovering ? Color.black.opacity(0.022) : Color.clear
    }
    private var dashColor: Color {
        hovering ? Color.black.opacity(0.34) : Color.black.opacity(0.18)
    }
}

/// 原型 .add-model-btn（「＋ 添加模型」pad 9/15 r10 白底描边）。
struct WOAddModelButton: View {

    let title: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(WOMP.text)
                .padding(.horizontal, 15)
                .frame(minWidth: 44, minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? WOMP.woRGB(0xf4, 0xf4, 0xf6) : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? Color.black.opacity(0.2) : WOMP.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .frame(minHeight: 44) // 触屏命中区
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.22), value: hovering)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(title)
    }
}

/// 原型 .empty-box（虚线框空态，pad 17/16、r12、文案 12.5 text-3）。
/// m7-fix2 M2（IMG_2517 空虚线框无字）加固：Text 垂直 fixedSize 防
/// 折叠容器高度压缩吞行（fixedSize 宽度不限场景下的零行测量边界），
/// lineSpacing(5) 对齐原型 line-height 1.65；文案色 text-3 与原型一致。
struct WOEmptyBox: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(WOMP.text3)
            .multilineTextAlignment(.center)
            .lineSpacing(5) // 原型 line-height 1.65 的等价行距
            .fixedSize(horizontal: false, vertical: true) // 文本理想高度不被压缩
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 17)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear))
            // strokeBorder 无 dash 参数——虚线改走 .stroke(_:style:)。
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.17),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text)
    }
}

/// 原型 .chk 勾选框（16px r5 方框；checked 黑底 + 白色 8px r2 内块 scale 0→1 .24s）。
/// 触屏：命中区 ≥44pt（视觉框居中不变）。
struct WOCheckbox: View {

    @Binding var checked: Bool
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            checked.toggle()
        } label: {
            HStack(spacing: 8) {
                box
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(WOMP.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44) // 触屏命中区
        .accessibilityLabel(label)
        .accessibilityAddTraits(checked ? [.isSelected] : [])
    }

    private var box: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(checked ? WOMP.text : Color.clear)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(checked ? WOMP.text : Color.black.opacity(0.25), lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .scaleEffect(checked ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(0.24), value: checked)
    }
}

/// 勾选框本体（无 label——picker 行内复用；触屏命中由整行承担）。
struct WOCheckboxBox: View {

    let checked: Bool
    var disabled: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(checked && !disabled ? WOMP.text : Color.clear)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(checked && !disabled ? WOMP.text : Color.black.opacity(0.28),
                              lineWidth: 1.5)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .scaleEffect(checked && !disabled ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(0.22), value: checked)
    }
}

// MARK: - 分区开关（.section-toggle：chev rotate 90° .42s）

/// 原型 .section-toggle（「自定义设置」行；chevron.right 旋转 90° .42s）。
struct WOSectionToggle: View {

    let title: String
    @Binding var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            // 批6 G3：显式事务开合（.collapsible .58s 原型曲线）——此前裸
            // toggle 依赖 WOCollapsible 隐式 .animation 注入，真机上「自定义
            // 设置展开后收起直接没动画」（用户复测实证）即此路径。
            withAnimation(reduceMotion
                          ? .easeOut(duration: 0.15)
                          : WOMP.ease(WOMP.durCollapse)) {
                open.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WOMP.text2)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(WOMP.text2)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44) // 触屏命中区（原型 pad 8 → 44 红线补足）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

// MARK: - 自定义下拉（.select：select-btn + select-pop；chev rotate 180° .38s）

/// 原型 .select 自定义下拉。弹层 = 圆角13 白底大阴影（0 22 50 .16 / 0 3 10 .07）、
/// opt hover black 5%、selected 蓝底白字；开合 = opacity .26/.28 + translateY(-8)
/// scale(.98)→none .38/.42 + chev rotate 180° .38s。
/// m7-fix2 M4①（用户两次复测）：弹层改 **overlay 脱离布局流**——此前弹层写在
/// VStack 流内，open 时撑高容器把下方字段（API 密钥等）挤下去；.zIndex 只管
/// 绘制顺序不管布局。现对齐原型 `.select-pop { position: absolute; top:
/// calc(100% + 6px) }`（:476-478）：按钮占位恒定，弹层经 .overlay(topLeading)
/// + .offset(按钮高+6) 浮于下方内容之上，开合时下方字段纹丝不动。
/// 批6 G1（b1 返工根治）：弹层改 **恒挂载**——废除 `if open` 条件插入 +
/// AnyTransition。机制：条件插入让弹层在祖先 mask（WOCollapsible 幕帘）+
/// opacity + 双阴影的离屏合成组里做插拔重提交，iOS 16.6 真机上该组合会把
/// 弹层图层拆分（内容行单独成层、白底 Shape 被丢弃）→ 行内容半透明叠印在
/// 表单上（字段透出）、弹层文字与下层字段文字混叠成「乱码状重影」、半透明
/// 大阴影成灰雾（用户逐字三症）。恒挂载后白底与行内容永远在同一合成组内
/// （再经 compositingGroup 压平成单层后才施阴影/被幕帘裁切），开合只是
/// opacity/offset/scale 三个普通可动画值；开合动画全部走 **显式 withAnimation
/// 事务**（toggle 点注入，不再依赖 .animation(value:) 隐式注入——批6 G3 实证
/// 隐式注入在本视图族不可靠），无事务时不渲染中间态、无冻结半透明可言。
/// 弹层溢出容器边界仍由 WOCollapsible 的 mask headroom 放行（原型
/// body.select-open overflow visible，:311）。
/// 关闭路径：选项点选 / 按钮重按 / 表单收起（原型 document 级外点关闭监听无
/// SwiftUI 等价——报告登记，触屏路径直达不受影响）。
struct WOSelect: View {

    let options: [String]
    @Binding var selection: String
    var maxHeight: CGFloat = 258

    @State private var open = false
    /// 按钮实测高度（弹层 offset 基准 = 按钮底 + 6；按钮恒 44pt 单行，实测只为稳健）。
    @State private var buttonHeight: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 开合曲线（reduceMotion 降级 .15s easeOut）——toggle 点显式事务共用。
    private var toggleAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durChevSelect)
    }

    var body: some View {
        button
            // 原型 .select-pop top: calc(100% + 6px)——脱离文档流浮出。
            // 批6 G1：恒挂载 + 普通可动画值驱动（不再条件插入 + transition，
            // 根因见结构注释）。闭态还原原型 .select-pop translateY(-8)
            // scale(.98) 的隐藏基线，开态动画从基线过渡到原位。
            .overlay(alignment: .topLeading) {
                popup
                    .opacity(open ? 1 : 0)
                    .offset(y: buttonHeight + 6 + (open ? 0 : -8))
                    .scaleEffect(open ? 1 : 0.98, anchor: .top)
                    .allowsHitTesting(open) // 闭态弹层不拦截点击
            }
            // open 时压住同层后续兄弟（含两列并排卡场景，要求④）。
            .zIndex(open ? 10 : 0)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { buttonHeight = geo.size.height }
                        .onChange(of: geo.size.height) { buttonHeight = $0 }
                }
            )
    }

    /// 弹层高 = min(行数 × 44, maxHeight)（opt 行单行定高 44，见 optRow；
    /// 原型 .select-pop max-height: 258px + overflow-y: auto，:482-483）。
    private var popupHeight: CGFloat {
        min(CGFloat(options.count) * 44, maxHeight)
    }

    private var button: some View {
        Button {
            // 批6 G1：显式事务开合（chev 旋转/边框变色同事务，内联隐式注入退役）。
            withAnimation(toggleAnimation) { open.toggle() }
        } label: {
            HStack(spacing: 10) {
                Text(selection)
                    .font(.system(size: 13.5))
                    .foregroundColor(WOMP.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(open ? WOMP.text2 : WOMP.text3)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44) // 触屏命中区（原型 11px pad 输入同高）
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(open ? WOMP.blue : WOMP.line, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(open ? WOMP.blueRing : Color.clear, lineWidth: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection)
        .accessibilityAddTraits(open ? [.isSelected] : [])
    }

    private var popup: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    optRow(option)
                }
            }
        }
        .frame(height: popupHeight)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
        // 批6 G1：compositingGroup 把（白底+描边+行内容）压平成单一图层后才
        // 施阴影/被祖先幕帘裁切——阻断 iOS16 离屏合成期的图层拆分（白底丢失
        // 的直接机制），保证白底与行内容永远同层同透明度。
        .compositingGroup()
        // 原型 box-shadow: 0 22px 50px rgba(0,0,0,.16) / 0 3px 10px rgba(0,0,0,.07)
        // （:487-490）。CSS blur-radius ≈ SwiftUI .shadow(radius:) ×2 的换算——
        // 旧 radius 50/10 是把 CSS blur 直接照抄，模糊范围视觉翻倍（用户点名
        // 「那个阴影是什么情况」的成因之一），按换算改 25/5。
        .shadow(color: Color.black.opacity(0.16), radius: 25, y: 22)
        .shadow(color: Color.black.opacity(0.07), radius: 5, y: 3)
    }

    private func optRow(_ option: String) -> some View {
        let selected = option == selection
        return Button {
            selection = option
            withAnimation(toggleAnimation) { open = false }
        } label: {
            Text(option)
                .font(.system(size: 13.5))
                .foregroundColor(selected ? Color.white : WOMP.text)
                .lineLimit(1) // 单行定高——popupHeight = 行数 × 44 的前提
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) // 触屏命中
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? WOMP.blue : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - 按压反馈（原型 :active scale；复用全库 WOPressableStyle 语义 0.97）

/// 原型 :active scale(.95~.988) 的统一近似（全库按压纪律 0.97 同款）。
struct WOProtoPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : WOMotion.pressSpring, value: configuration.isPressed)
    }
}
