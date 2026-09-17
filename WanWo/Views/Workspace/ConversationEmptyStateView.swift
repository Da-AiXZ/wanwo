//
//  ConversationEmptyStateView.swift
//  WanWo
//
//  【UI 对齐批 1 · 工作项 1B：hero 空态主页（照 dsh 源码语义落地）】
//  语义源（dsh 逐条核实）：
//    · EmptyHero.tsx:132-164 HeroShell —— hero 头条行 = 品牌标 leading +
//      headline 文本 + 预览 badge 同排（figma 34:10412：标 34 宽、gap 10）；
//      文案 hero.headline/hero.preview =「探索未至之境」/「预览版」
//      （ui-conversation/locales.ts:66-67 逐字）。
//    · EmptyHero.tsx:38-62 WorkspaceChip —— 工作区胶囊（folder 图标 +
//      项目名/「选择工作区」+ chevron，恒可交互：首条消息前工作区可换）；
//      占位文案 hero.chooseWorkspace =「选择工作区」（locales.ts:68 逐字）。
//    · ConversationRoot.tsx:293-317 heroWorkspaceRow —— hero 空态同屏三件：
//      品牌/标题区 + 工作区胶囊 + composer（同屏，非整页选择卡）。
//    · ConversationRoot.tsx:285-291,318-336（chipTitle 解析 + inert 传参：
//      sessionId===undefined 时恒 inert，须用户显式挑选工作区才激活）+
//      InputBar.tsx:125-131 workspaceTrigger + input/editor/
//      ComposerContentEditable.tsx:42 —— 未选工作区时 composer 同一个框
//      inert（不可输入、占位符 placeholder.workspace =
//      「选择一个工作区开始」locales.ts:20 逐字、点击整框 = 开工作区菜单）；
//      有工作区可输入（占位符 placeholder.hero =
//      「描述你想要构建的内容… / 调用指令 @ 文件或对话」locales.ts:19 逐字）。
//    · WorkspacePicker.tsx:58-217 菜单流 —— 菜单 = 已有项目列表行
//      （folder + title，当前项勾选 menuitemradio 语义）+ 尾部
//      「添加工作区…」（:106,189 底部固定；locales.ts:33 逐字）；
//      :143-157 addIsTheOnlyEntry —— 无项目时点击 = 直接进添加流
//      （单行弹层无可选目标，锚点手势即添加动作）。
//    · WorkspacePicker.tsx:126-134 adoptDirectory —— 添加终点 = 注册工作区
//      后 onPick；失败弹错（WanWo 折算：WorkspaceAdoption.adopt 失败 alert，
//      命名卡保持打开可改名重试）。
//
//  平台折算（iOS 不可抗力映射，非自创）：
//    · dsh 自绘 anchored Menu → SwiftUI Menu 系统弹层（派单拍板；scale 锚定
//      胶囊 + opacity 由系统呈现动画承接，派单动画纪律第 7 条）。
//    · dsh IconFolderOpen16/IconFolderClose16 → SF Symbols 无 open-folder
//      对应物：无项目 = folder（闭合），有项目 = folder.fill（见交付清单）。
//    · 添加工作区唯一路径 = 输入名字 → WorkspaceAdoption.adopt
//      (name:environment:)（iSH fakefs 建项目目录，用户拍板；文件 App 导入
//      已彻底删除）。
//  本批 composer 为简版（inert 语义 + 基本卡形态 + 发送）；全量 composer
//  （工具行 / 权限 chip / QueueDock 等）在批 3——本文件不超前实现。
//  动画纪律：交互变化一律 withAnimation + spring(response: 0.3,
//  dampingFraction: 0.85)；hero ↔ 会话切换 = opacity 渐变（transition 挂
//  本视图根层，切换侧 withAnimation 在 RootView 挂载点）。
//
//  【批 1 返修 R1 · hero 逐值重皮（结构已对，样式值对齐 dsh 原始 CSS）】
//  数值出处（逐值，注释内随点再标）：
//    · InputBar.module.css .card:32-64 —— r22、--dsw-specific-input-major
//      面（--dsw-static-neutral-bluish-00 = 纯白 rgb(255,255,255)，design-
//      platform.css:53）、elevation hairline = --dsw-alias-border-l2
//      （rgba(0,0,0,0.1)）、box-shadow: var(--dsw-elevation-soft)
//      （gradient-shadow-text.css:33-34 = 0 4px 16px rgba(0,0,0,0.03) +
//      0 0 24px rgba(0,0,0,0.03)）、padding-top 10、gap 12、
//      font-size var(--dsh-content-font-size, 14px)。
//    · InputBar.module.css .input:158-164 —— 文本区 padding 4/8/0/16；
//      .hero .input:208-210 —— 最小高 52。
//    · InputBar.module.css .row:214-230 —— padding 2/8/6、space-between。
//    · ConversationRoot.module.css:28-32 —— --dsh-composer-card-max-width
//      = calc(--dsh-chat-content-width + 32px)，其中 content-width =
//      clamp(680px, 64% 列宽, 920px) → 卡上限 = 下限 712 / 上限 952；
//      iPad hero 静态布局（无宽度拖拽偏好）取下限 712。
//    · HeroShell.module.css .root/.stack:5-24 —— 横向 pad 24、纵向 gap 12；
//      .headline:29-39 —— 34px 槽位 + gap 10、26/32 wt500；.previewBadge:
//      46-62 —— mono 12/18 wt500、padding 1px 7px 0、r24、0.5px 描边、
//      顶部随行（align-self start + margin-top 2 / margin-left -3）；
//      .workspaceRow:126-133 —— 行左内边距 8。
//    · HeroShell.module.css .workspace:136-151 —— 胶囊 gap 4、min-height
//      28、padding 0 8、r16、rest 态透明底（hover 才填色——iOS 无 hover
//      折算为恒透明）、13/20 wt500、max-width 360、label 恒全对比度；
//      .folder:164-167 label-primary；.chevron:175-178 label-caption。
//

import SwiftUI

// MARK: - 局部共享件（补-1：inert 触发卡虚线描边按压态）

/// 按压态环境键（iOS 无 hover → 折算按压时虚线变业务蓝；dsh
/// InputBar.module.css .cardWorkspaceTrigger:hover::after:96-98 折算）。
private struct InertTriggerPressedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private extension EnvironmentValues {
    var inertTriggerPressed: Bool {
        get { self[InertTriggerPressedKey.self] }
        set { self[InertTriggerPressedKey.self] = newValue }
    }
}

/// dsh 业务蓝（--dsw-alias-state-business-primary = --dsw-static-deepseek-500
/// = rgb(65,118,230)，design-platform.css:27,222——浅色档）。
private let dshBusinessBlue = Color(red: 65 / 255.0, green: 118 / 255.0, blue: 230 / 255.0)

/// inert 触发卡按钮样式：把 isPressed 经环境键传进卡皮（虚线色切换）。
private struct DashedTriggerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.inertTriggerPressed, configuration.isPressed)
            .animation(Animation.spring(response: 0.3, dampingFraction: 0.85),
                       value: configuration.isPressed)
    }
}

struct ConversationEmptyStateView: View {
    @ObservedObject var environment: AppEnvironment

    /// 交互动画标准（spring 丝滑，response 0.3 / damping 0.85）。
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)

    /// 工作区快照（workspaceController.follow 帧驱动——同侧栏纪律）。
    @State private var workspaces: [WorkspaceRecord] = []
    @State private var followCancel: (() -> Void)?

    /// 「添加工作区…」命名卡开合。
    @State private var showingAddFlow = false
    /// 新工作区名草稿。
    @State private var newWorkspaceName = ""
    /// hero composer 草稿（有工作区时可输入；发送 = 草稿交接 + startSession）。
    @State private var heroDraft = ""
    /// 添加失败的用户可见反馈（alert 呈现后清零）。
    @State private var errorText: String?
    /// hero 进场动画驱动（onAppear 触发一次：三件依次淡入+上移 8pt）。
    @State private var heroAppeared = false

    /// 焦点工作区（胶囊标题）：仅 selectedWorkspaceID 命中时 featured
    /// （adopt / 侧栏 / 菜单显式挑选写入）；否则为 nil = inert 态。
    /// 对应 dsh ConversationRoot.tsx:285-291 chipTitle 解析（sessionId
    /// === undefined 时恒为占位「选择工作区」）+ :324 `inert =
    /// sessionId === undefined || (hero && chipTitle === undefined)`——
    /// 未显式挑选工作区时恒 inert，无「回落快照首项」闸门旁路。
    private var featuredWorkspace: WorkspaceRecord? {
        guard let id = environment.selectedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            heroStack
            // 添加流（模态层：淡遮罩 + 居中命名卡；遮罩 opacity、卡片
            // scale+opacity——两个条件子节点各自带 transition，进出成对）。
            if showingAddFlow {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { cancelAddFlow() }
                    .transition(.opacity)
                    .zIndex(3)
            }
            if showingAddFlow {
                addWorkspaceCard
                    .transition(.scale(scale: 0.96, anchor: .center)
                        .combined(with: .opacity))
                    .zIndex(4)
            }
        }
        // hero ↔ 会话切换 opacity 渐变（挂载点 withAnimation 由 RootView 承接）。
        .transition(.opacity)
        .task {
            subscribeWorkspaces()
        }
        .onDisappear {
            followCancel?()
            followCancel = nil
        }
        .alert("添加工作区失败",
               isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - hero 同屏三件（品牌头条 + 胶囊 + composer）

    /// hero 主体（居中纵列；HeroShell.module.css .root:5-12 横 pad 24 +
    /// .stack:15-24 纵 gap 12、max-width = --dsh-composer-card-max-width）。
    /// 卡宽换算：ConversationRoot.module.css:28-32 content-width =
    /// clamp(680px, 64% 列宽, 920px)，卡 = content + 32 → 下限 712 / 上限
    /// 952；iPad hero 静态布局（无宽度拖拽偏好）取下限 712。
    /// 进场动画：三件依次淡入 + 上移 8pt（每级延迟 0.05s，spring 0.3/0.85，
    /// onAppear 触发一次——headline → 胶囊 → composer）。
    private var heroStack: some View {
        VStack(spacing: 12) {
            heroHeadline
                .heroEntrance(appeared: heroAppeared, stage: 0)
            workspaceControl
                .padding(.leading, 8) // .workspaceRow:126-133 行左内边距 8
                .heroEntrance(appeared: heroAppeared, stage: 1)
            heroComposer
                .heroEntrance(appeared: heroAppeared, stage: 2)
        }
        .padding(.horizontal, 24) // .root:11 padding 0 24px
        .frame(maxWidth: 712)     // --dsh-composer-card-max-width 下限（见上换算）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !heroAppeared else { return }
            heroAppeared = true
        }
    }

    /// hero 头条行（HeroShell.module.css .headline:29-39：34px 槽位 +
    /// headline 文本 + 预览 badge，column-gap 10、26px/32px 行高 wt500、
    /// 居中）。文案 locales.ts:66-67 逐字。
    private var heroHeadline: some View {
        HStack(alignment: .center, spacing: 10) {
            // 品牌标（万我；dsh fish 34px 槽位 .fishHitbox:66-72）。
            Text("万")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text("探索未至之境")
                // .headline:35-37 font-size 26px / line-height 32px / wt500。
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.primary)
            // 预览 badge（.previewBadge:46-62：mono 12/18 wt500、padding
            // 1px 7px 0、r24、0.5px 描边——描边原值 rgba(38,49,72,0.06)
            // （--dsw-alias-interactive-bg-hover 浅色档，QA 实证）、底色
            // --dsw-alias-state-business-tertiary 折算 blue 10%、字色
            // label-primary-bluish 折算 primary；顶部随行 align-self start
            // + margin-top 2 / margin-left -3（HeroShell.module.css:50-51）
            // → 居中 HStack 内 offset(x:-3, y:-5)（行高 32、badge 高 18+1、
            // margin 2 → 顶部 y=2，相对居中位上移 (32-19)/2-2 ≈ 4.5 取 5）。
            // locales.ts:67 逐字。
            Text("预览版")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(EdgeInsets(top: 1, leading: 7, bottom: 0, trailing: 7))
                .background(Capsule().fill(Color.blue.opacity(0.10)))
                .overlay(Capsule().strokeBorder(
                    Color(red: 38 / 255.0, green: 49 / 255.0, blue: 72 / 255.0)
                        .opacity(0.06),
                    lineWidth: 0.5))
                .offset(x: -3, y: -5)
                .accessibilityLabel("预览版")
        }
    }

    // MARK: - 工作区胶囊（WorkspaceChip；SwiftUI Menu 弹层 / addIsTheOnlyEntry）

    /// 工作区控件（EmptyHero.tsx:38-62 WorkspaceChip + WorkspacePicker.tsx
    /// 菜单流）：有项目 = SwiftUI Menu 弹层（列表 + 尾部「添加工作区…」；
    /// 未显式挑选时胶囊渲染占位「选择工作区」——dsh chipTitle :285-291
    /// sessionId===undefined 恒占位语义）；无项目 = 占位胶囊按钮，点击直接
    /// 进添加流（:143-157 addIsTheOnlyEntry 语义——单行弹层无可选目标，
    /// 锚点手势即添加动作）。
    @ViewBuilder
    private var workspaceControl: some View {
        if workspaces.isEmpty {
            Button {
                openAddFlow()
            } label: {
                chipLabel(featured: nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择工作区")
        } else {
            Menu {
                workspaceMenuContent
            } label: {
                chipLabel(featured: featuredWorkspace)
            }
            .accessibilityLabel(featuredWorkspace.map { "当前工作区 \($0.title)，切换工作区" }
                                ?? "选择工作区")
        }
    }

    /// 工作区菜单内容（胶囊与 inert composer 双触发点共用，同一弹层语义）：
    /// 已有项目列表（WorkspacePicker.tsx:107-113 items：folder + title，
    /// 当前项勾选 = menuitemradio selectedId 语义）+ 尾部「添加工作区…」
    /// （:106,189 pinAdd：列表尾固定行；locales.ts:33 menu.addWorkspace 逐字）。
    @ViewBuilder
    private var workspaceMenuContent: some View {
        ForEach(workspaces) { workspace in
            Button {
                pickWorkspace(workspace)
            } label: {
                HStack {
                    Label(workspace.title, systemImage: "folder")
                    if workspace.id == featuredWorkspace?.id {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        Divider()
        Button {
            openAddFlow()
        } label: {
            Label("添加工作区…", systemImage: "plus")
        }
    }

    /// 胶囊外观（HeroShell.module.css .workspace:136-151 逐值：gap 4、
    /// min-height 28、padding 0 8、r16、rest 态透明底（web hover 才填色
    /// ——iOS 无 hover 折算为恒透明）、13px/20px wt500、max-width 360、
    /// label 恒全对比度；.folder:164-167 = label-primary（非 accent）；
    /// .chevron:175-178 = label-caption）。占位 = 闭合文件夹 +「选择工作区」
    /// （EmptyHero.tsx:55-58；locales.ts:68 逐字）；有项目 = 打开文件夹 +
    /// 项目名（iOS 无 open-folder SF Symbol，以 folder.fill 折算）。
    private func chipLabel(featured: WorkspaceRecord?) -> some View {
        HStack(spacing: 4) { // .workspace:139 gap 4px
            Image(systemName: featured == nil ? "folder" : "folder.fill")
                .font(.system(size: 16)) // IconFolderClose/Open16 = 16px
                .foregroundStyle(Color.primary) // .folder:166 label-primary
            Text(featured?.title ?? "选择工作区")
                .font(.system(size: 13, weight: .medium)) // :147-149 13/20 wt500
                .lineLimit(1)
                .foregroundStyle(.primary) // label 恒全对比度（占位同）
            Image(systemName: "chevron.down")
                .font(.system(size: 12)) // IconChevronDownOutline14 @ 12px
                .foregroundStyle(Color.secondary) // .chevron label-caption
        }
        .padding(.horizontal, 8)  // :142 padding 0 8px
        .frame(minHeight: 28)     // :141 min-height 28px
        .background(Color.clear, in: Capsule()) // :145 rest 透明（r16→Capsule）
        .contentShape(Capsule())
        .frame(maxWidth: 360, alignment: .leading) // :140 max-width 360
    }

    /// 选中一个工作区（ConversationRoot.tsx:306-312 onPick 终点语义）：
    /// 草稿迁移（hero 输入文本 = 新会话 composer draft，不丢）→
    /// startSession（WorkspaceNavigator 内 connectWorkspace 复用 blank 或
    /// 新建会话，navigation.ts:114-133 语义）→ 会话打开即 hero 退场。
    private func pickWorkspace(_ workspace: WorkspaceRecord) {
        migrateHeroDraft()
        environment.workspaceNavigator.startSession(workspace.id)
    }

    // MARK: - composer（无工作区 inert / 有工作区可输入；同一 dock 卡形态）

    /// 占位文案（dsh 逐字）：inert = placeholder.workspace
    /// 「选择一个工作区开始」（locales.ts:20）；active = placeholder.hero
    /// 「描述你想要构建的内容… / 调用指令 @ 文件或对话」（locales.ts:19）。
    private var heroPlaceholder: String {
        featuredWorkspace == nil
            ? "选择一个工作区开始"
            : "描述你想要构建的内容… / 调用指令 @ 文件或对话"
    }

    @ViewBuilder
    private var heroComposer: some View {
        if featuredWorkspace == nil {
            // inert 态（ConversationRoot.tsx:324-336 + InputBar.tsx:127-131
            // workspaceTrigger + input/editor/ComposerContentEditable.tsx:42
            // contentEditable 门）：不可输入、不可聚焦；点击整框 = 开工作区
            // 选择流。分两相（WorkspacePicker.tsx:143-157 addIsTheOnlyEntry）：
            //   · 无任何工作区 → 单行弹层无可选目标，点击直接进添加流；
            //   · 有工作区未显式挑选 → 点击 = 开工作区菜单（项目列表 + 尾部
            //     添加；与胶囊共用同一菜单内容，弹层锚定整卡——iOS Menu 锚定
            //     label 的平台折算，dsh 锚定胶囊按钮）。
            if workspaces.isEmpty {
                Button {
                    openAddFlow()
                } label: {
                    inertComposerCard
                }
                // 补-1：DashedTriggerButtonStyle 把 isPressed 经环境键传给
                // 虚线环（按压变业务蓝，:96-98 hover 折算）。
                .buttonStyle(DashedTriggerButtonStyle())
                .accessibilityLabel("选择一个工作区开始")
            } else {
                // Menu 触发态：虚线 rest 色恒定（环境键无 isPressed 注入源
                // ——Menu 展开高亮由系统接管，登记为边界）。
                Menu {
                    workspaceMenuContent
                } label: {
                    inertComposerCard
                }
                .accessibilityLabel("选择一个工作区开始")
            }
        } else {
            // 可输入态（本批简版 composer：文本区 + 发送；工具行 / 权限 chip /
            // QueueDock 等全量 composer 在批 3——不超前实现）。
            // 内容布局照 .card 结构：gap 12（:39）+ 文本区 .input:158-164
            // padding 4/8/0/16 + .hero .input:208-210 最小高 52 + 底行
            // .row:214-230 padding 2/8/6、space-between；正文 14。
            ComposerCard {
                VStack(spacing: 12) { // .card:39 gap 12px
                    TextField(heroPlaceholder, text: $heroDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 14)) // :55 content-font-size 14
                        .padding(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 8))
                        .frame(minHeight: 52, alignment: .topLeading) // :209 min-h 52
                    HStack(spacing: 8) {
                        Spacer(minLength: 0) // .row:218 space-between
                        Button {
                            sendHeroDraft()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        .disabled(heroDraft.trimmingCharacters(in: .whitespaces)
                                      .isEmpty)
                        .accessibilityLabel("开始会话")
                    }
                    .padding(EdgeInsets(top: 2, leading: 8, bottom: 6, trailing: 8))
                }
            }
        }
    }

    /// inert composer 卡（占位文本整卡即触发点；dsh「同一个框 inert」语义——
    /// InputBar.tsx:382-393 触发点击落在卡上、整卡即选择目标）。文本区照
    /// .input:158-164 padding 4/8/0/16 + .hero .input:208-210 最小高 52、
    /// 正文 14；卡皮 = 虚线触发态（补-1，.cardWorkspaceTrigger:72-98）。
    private var inertComposerCard: some View {
        ComposerCard(dashedStroke: true) {
            Text(heroPlaceholder)
                .font(.system(size: 14)) // content-font-size 14
                // iOS 16 兼容：.placeholder ShapeStyle 是 iOS 17+——
                // 系统语义占位色 placeholderText 同观感（dsh .placeholder:189-195
                // caption 灰 #ADB2B8/#81858C 同族）。
                .foregroundStyle(Color(uiColor: .placeholderText))
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 8))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }

    /// hero 进场 modifier（R1 动画补强：淡入 + 上移 8pt 回位，stage 级联
    /// 每级延迟 0.05s，spring(0.3/0.85)——headline → 胶囊 → composer）。
    /// 定义在文件尾的 `extension View`（CI 出包一跑实证：嵌套在本结构体内
    /// 时 `some View` 链上无此成员——成员方法不在 View 协议扩展上）。

    /// dock 卡形态（InputBar.module.css .card:32-64 逐值）：r22；底色纯白
    /// rgb(255,255,255)（--dsw-static-neutral-bluish-00，design-platform.css
    /// :53——static 令牌不随深色模式自适应；**固定浅色拍板 2026-09-18**，
    /// 深色适配不采纳）；描边 1px rgba(0,0,0,0.1)（--dsw-alias-border-l2）；
    /// 双层柔和投影 --dsw-elevation-soft（gradient-shadow-text.css:33-34 =
    /// 0 4px 16px rgba(0,0,0,0.03) + 0 0 24px rgba(0,0,0,0.03) → SwiftUI
    /// blur÷2 映射 radius 8/y4 叠 radius 12）；卡顶 pad 10；正文 14
    /// （--dsh-content-font-size 默认）。
    /// 补-1：dashedStroke = inert 触发态（.cardWorkspaceTrigger:72-98）——
    /// 无实线描边，改 r22 虚线环（dasharray 4/4、可见 1px、色
    /// --dsw-alias-border-l4 = rgba(0,0,0,0.16)，design-platform.css:176），
    /// 按压时虚线变业务蓝（:96-98 hover 折算，iOS 无 hover）；可输入卡
    /// 保持实线不变。
    private struct ComposerCard<Content: View>: View {
        var dashedStroke: Bool = false
        @ViewBuilder var content: () -> Content
        @Environment(\.inertTriggerPressed) private var pressed

        var body: some View {
            content()
                .padding(.top, 10) // .card:42 padding-top 10px
                .background(Color.white) // --dsw-static-neutral-bluish-00 纯白
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) // :48 r22
                .overlay(stroke)
                .shadow(color: .black.opacity(0.03), radius: 8, y: 4) // 0 4px 16px @3%
                .shadow(color: .black.opacity(0.03), radius: 12)      // 0 0 24px @3%
                .animation(Animation.spring(response: 0.3, dampingFraction: 0.85),
                           value: pressed)
        }

        /// 描边：实线态 = .card:47 border-l2 1px rgba(0,0,0,0.1)；虚线态 =
        /// .cardWorkspaceTrigger:72-98（r22 虚线环 1px dash 4/4，rest
        /// rgba(0,0,0,0.16) → pressed 业务蓝 rgb(65,118,230)）。
        @ViewBuilder
        private var stroke: some View {
            if dashedStroke {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(pressed ? dshBusinessBlue : Color.black.opacity(0.16),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            }
        }
    }

    /// 发送（dsh hero onPick 终点语义）：草稿经 pendingFirstDraft 缝交接给
    /// 新会话（ChatView onAppear 消费进会话草稿框后清零——消费点不动），
    /// startSession 开会话（connectWorkspace 复用 blank 或新建）→ hero 随
    /// selection 切换退场。
    private func sendHeroDraft() {
        guard let featured = featuredWorkspace else { return }
        migrateHeroDraft()
        environment.workspaceNavigator.startSession(featured.id)
    }

    /// 草稿交接（dsh「hero 输入文本 = 新会话 composer draft」语义）：
    /// 非空草稿写 AppEnvironment.pendingFirstDraft 缝并清空 hero 草稿；
    /// 空草稿不动缝（避免把 nil 覆盖成空串触发无谓消费）。
    private func migrateHeroDraft() {
        let draft = heroDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        environment.pendingFirstDraft = heroDraft
        heroDraft = ""
    }

    // MARK: - 添加流（命名卡 → adopt → startSession；唯一路径）

    /// 打开添加流（命名卡；菜单行 / 占位胶囊 / inert composer 三入口同动作）。
    private func openAddFlow() {
        withAnimation(Self.spring) {
            showingAddFlow = true
        }
    }

    /// 命名卡（万我现有自绘卡风格沿用）：输入项目名 → 确认即建。
    private var addWorkspaceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加工作区")
                .font(.headline)
            TextField("输入项目名", text: $newWorkspaceName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmAddWorkspace() }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { cancelAddFlow() }
                    .buttonStyle(.bordered)
                Button("确认") { confirmAddWorkspace() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newWorkspaceName.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        // 模态卡居中（根 ZStack 条件子节点挂此 frame）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cancelAddFlow() {
        withAnimation(Self.spring) {
            showingAddFlow = false
            newWorkspaceName = ""
        }
    }

    /// 确认：WorkspaceAdoption.adopt(name:environment:)（iSH fakefs 建项目
    /// 目录 + 注册工作区，唯一路径）→ 草稿迁移 → startSession(新工作区)
    /// （dsh adoptDirectory :126-134 终点语义：adopt 成功即 onPick）。失败
    /// 保持卡片打开（可改名重试），alert 呈现原因（:130-134 错误面对应）。
    private func confirmAddWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let workspace = try WorkspaceAdoption.adopt(
                name: name, environment: environment)
            withAnimation(Self.spring) {
                showingAddFlow = false
                newWorkspaceName = ""
            }
            migrateHeroDraft()
            environment.workspaceNavigator.startSession(workspace.id)
        } catch {
            // AddError 是 LocalizedError（中文 errorDescription）——
            // String(describing:) 只会打印英文 case 名。
            errorText = "添加工作区失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 数据订阅（workspaceController.follow 快照流，同侧栏纪律）

    /// workspaceController.follow 订阅（follow 快照流驱动工作区列表）。
    private func subscribeWorkspaces() {
        guard followCancel == nil else { return }
        let (stream, cancel) = environment.workspaceController.follow()
        followCancel = cancel
        Task { @MainActor in
            for await frame in stream {
                workspaces = frame.workspaces
            }
        }
    }
}

// MARK: - hero 进场动画（文件级：View 协议扩展供任意 some View 链调用）

/// hero 进场 modifier（R1 动画补强：淡入 + 上移 8pt 回位，stage 级联
/// 每级延迟 0.05s，spring(0.3/0.85)——headline → 胶囊 → composer）。
private struct HeroEntrance: ViewModifier {
    let appeared: Bool
    let stage: Int

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(Animation.spring(response: 0.3, dampingFraction: 0.85)
                        .delay(Double(stage) * 0.05),
                       value: appeared)
    }
}

extension View {
    /// 同文件内可见（private 于扩展内=文件内可见性）；出处见 HeroEntrance。
    fileprivate func heroEntrance(appeared: Bool, stage: Int) -> some View {
        modifier(HeroEntrance(appeared: appeared, stage: stage))
    }
}
