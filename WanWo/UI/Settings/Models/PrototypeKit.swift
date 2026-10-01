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

    private static func woRGB(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }
    private static func woRGBA(_ r: Int, _ g: Int, _ b: Int, _ a: Double) -> Color {
        woRGB(r, g, b).opacity(a)
    }
}

// MARK: - 折叠容器（.collapsible grid-template-rows 0fr→1fr 的 SwiftUI 等价）

/// 原型 .collapsible/.collapsible-inner/.collapsible-content 三层结构的
/// SwiftUI 等价：实测自然高度 → 高度 0↔natural 动画（.58s 原型曲线）+
/// 内容 opacity/translate 入场（开：.4s ease .1s 延迟 / 位移 .55s .06s；
/// 关：opacity .28s）。clipped = inner overflow hidden。
/// 注：下拉弹层（WOSelect）在展开容器内不被裁（原型 body.select-open
/// overflow visible 语义）——弹层尺寸设计上落在容器内部（报告登记）。
struct WOCollapsible<Content: View>: View {

    var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: () -> Content

    @State private var naturalHeight: CGFloat = 0

    var body: some View {
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
            .frame(height: open ? naturalHeight : 0, alignment: .top)
            .opacity(open ? 1 : 0)
            .offset(y: open ? 0 : -6) // 收起时内容随手上移（原型 content 态）
            .clipped()
            .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durCollapse),
                       value: open)
            // 高度基准变化（内容增删行）瞬时应答，不叠动画（原型 open 态自然回流）。
            .animation(nil, value: naturalHeight)
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
    @State private var naturalHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // fixedSize：出场地基按理想高度测量（同 WOCollapsible 注）。
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { naturalHeight = geo.size.height }
                        .onChange(of: geo.size.height) { naturalHeight = $0 }
                }
            )
            .frame(height: removing ? 0 : naturalHeight, alignment: .top)
            .opacity(removing ? 0 : 1)
            .scaleEffect(removing ? 0.97 : 1)
            .clipped()
            .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durRowOut),
                       value: removing)
            .animation(nil, value: naturalHeight)
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
struct WOProtoButton: View {

    enum Kind { case primary, ghost }

    let title: String
    var kind: Kind = .ghost
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.22), value: hovering)
        .accessibilityLabel(title)
    }

    private var fill: Color {
        switch kind {
        case .primary:
            return hovering ? Color(red: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x2b / 255.0) : WOMP.text
        case .ghost:
            return hovering ? Color(red: 0xf4, green: 0xf4, blue: 0xf6) : Color.white
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
                .foregroundColor(hovering ? WOMP.text : Color(red: 0x4a, green: 0x4a, blue: 0x55))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? Color.black.opacity(0.022) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? Color.black.opacity(0.34) : Color.black.opacity(0.18),
                                  lineWidth: 1,
                                  dash: [5, 4]))
                .contentShape(Rectangle())
        }
        .buttonStyle(WOProtoPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.25), value: hovering)
        .accessibilityLabel(title)
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
                    .fill(hovering ? Color(red: 0xf4, green: 0xf4, blue: 0xf6) : Color.white))
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
struct WOEmptyBox: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundColor(WOMP.text3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 17)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.17), lineWidth: 1, dash: [5, 4]))
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

    var body: some View {
        Button {
            open.toggle()
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
/// 关闭路径：选项点选 / 按钮重按 / 表单收起（原型 document 级外点关闭监听无
/// SwiftUI 等价——报告登记，触屏路径直达不受影响）。
struct WOSelect: View {

    let options: [String]
    @Binding var selection: String
    var maxHeight: CGFloat = 258

    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            button
            if open {
                popup
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -8)).combined(with: .scale(0.98, anchor: .top)),
                        removal: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durChevSelect), value: open)
        .zIndex(open ? 10 : 0) // 弹层压住后续内容
    }

    private var button: some View {
        Button {
            open.toggle()
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
        .frame(maxHeight: maxHeight)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Color.black.opacity(0.1), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.16), radius: 50, y: 22)
        .shadow(color: Color.black.opacity(0.07), radius: 10, y: 3)
    }

    private func optRow(_ option: String) -> some View {
        let selected = option == selection
        return Button {
            selection = option
            open = false
        } label: {
            Text(option)
                .font(.system(size: 13.5))
                .foregroundColor(selected ? Color.white : WOMP.text)
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
