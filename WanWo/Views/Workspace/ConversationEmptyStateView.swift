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

import SwiftUI

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

    /// hero 主体（居中纵列；ConversationRoot.tsx:346-353 composerStack 顺序：
    /// HeroShell → heroWorkspaceRow → inputBar）。
    private var heroStack: some View {
        VStack(spacing: 0) {
            heroHeadline
            workspaceControl
                .padding(.top, 28)
            heroComposer
                .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// hero 头条行（EmptyHero.tsx:137-156：品牌标 leading + headline 文本 +
    /// 预览 badge 同排，标 34 宽、gap 10）。文案 locales.ts:66-67 逐字。
    private var heroHeadline: some View {
        HStack(alignment: .center, spacing: 10) {
            // 品牌标（万我；dsh fish 34 宽位）。
            Text("万")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            Text("探索未至之境")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
            // 预览 badge（EmptyHero.tsx:155 previewBadge 位；locales.ts:67 逐字）。
            Text("预览版")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                )
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

    /// 胶囊外观（EmptyHero.tsx:45-61：folder + label + chevron，恒可交互）。
    /// 无项目 = 闭合文件夹 +「选择工作区」占位（:55-58；locales.ts:68 逐字）；
    /// 有项目 = 打开文件夹 + 项目名（iOS 无 open-folder SF Symbol，以
    /// folder.fill 折算——见交付清单不可抗力条目）。
    private func chipLabel(featured: WorkspaceRecord?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: featured == nil ? "folder" : "folder.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(featured == nil
                                 ? Color.secondary : Color.accentColor)
            Text(featured?.title ?? "选择工作区")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemFill), in: Capsule())
        .contentShape(Capsule())
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
                .buttonStyle(.plain)
                .accessibilityLabel("选择一个工作区开始")
            } else {
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
            composerCard {
                TextField(heroPlaceholder, text: $heroDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
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
                .padding(.top, 12)
            }
        }
    }

    /// inert composer 卡（占位文本整卡即触发点；dsh「同一个框 inert」语义——
    /// InputBar.tsx:382-393 触发点击落在卡上、整卡即选择目标）。
    private var inertComposerCard: some View {
        composerCard {
            Text(heroPlaceholder)
                .font(.body)
                // iOS 16 兼容：.placeholder ShapeStyle 是 iOS 17+——
                // 系统语义占位色 placeholderText 同观感（dsh caption 灰）。
                .foregroundStyle(Color(uiColor: .placeholderText))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    /// dock 卡形态（InputBar.module.css .card 语义：大圆角、上 pad、文本区与
    /// 底行间距 12——ChatView inputBar 同一形态，双处一致）。
    private func composerCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 12))
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
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
