//
//  WOChatView.swift
//  WanWo
//
//  R2c 对话区全量批（digest-H 原型逐值对齐；引擎 = 既有 ChatViewModel，零引擎改动）：
//  - hero 空态：logo + 「万我」+ 居中 composer（digest-H hero 节；工作区胶囊/
//    建议 chips 引擎无数据源 → 缺席，登记报告）。首条消息发送后 composer 从
//    hero 位置落到底部 dock——原型 FLIP 的透明度+位移近似：持久 composer 座位
//    随布局动画迁移，.42s out 曲线（digest-H composer hero→dock FLIP .42s），
//    reduceMotion 由 woMotion 降级 0.15s easeOut。
//  - 气泡保真：用户气泡 r22 + 蓝软底右对齐（82% 帽）；助手行渐变头像
//    （22px 135deg）；入场 mInL/mInR .55s（一次性门防滚动重建重播；历史投影
//    种子不播）；消息间距 16（digest-H .msgs gap）。
//  - 思考披露：settled = 折叠头「思考」+ 首行预览 + chevron（展开体左缩进 22）；
//    流式 = sweep 扫光头 + 尾行跟随（ReasoningRow summary follow-end 语义）。
//  - 回合尾：turnUsage pill（引擎 TurnUsageSummary 在场）；「深度求索中...」
//    1.8s shimmer 行（phase == .streaming 锚点）。
//  - 附件：+ 钮/chip 条在 WOComposer；消息内图片复用 MessageImagesView
//    （单图 80pt = 用户既定裁定）；lightbox 上提本层。
//  - slash 命令菜单：draft 以 "/" 开头即浮出（引擎 slashCommandList；锚定
//    composer 卡上缘向上生长，chrome 高度 PreferenceKey 度量——旧 ChatView 同法）。
//  - StatsLine dock 恒渲染（用户既定裁定）；审批/提问接管语义不动（视觉精修
//    在 WOInteractionCards）。
//  触屏纪律：无 hover 依赖；全部交互真响应。
//

import SwiftUI

struct WOChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @EnvironmentObject private var environment: AppEnvironment
    private let sessionId: String

    /// 简化自动跟随（批 1）：内容变化即滚底；治理=后续批（autoFollow 闸门按 digest-K 6.3#1）。
    @State private var bottomAnchor = "wo-chat-bottom"
    /// 已播过入场动画的节点 id（一次性门；防 LazyVStack 滚动重建重播）。
    @State private var animatedIDs: Set<String> = []
    /// 历史种子位：open 完成后的首投影不播入场（历史/恢复静默呈现）。
    @State private var entrySeeded = false
    /// slash 菜单关闭位（选中写回 claim token 后不再被 "/" 前缀拉起）。
    @State private var slashDismissed = false
    /// composer chrome 高度（座位 + dock；slash 菜单锚定用）。
    @State private var composerChromeHeight: CGFloat = 0
    /// 消息气泡图片原图预览（lightbox 状态上提本层——组件内 cover 在流式重建
    /// 场景 present 静默失败，旧 ChatView T2.8 件2 同源教训）。
    @State private var messagePreview: ImageAttachmentRef?

    init(environment: AppEnvironment, sessionId: String) {
        self.sessionId = sessionId
        _viewModel = StateObject(wrappedValue: ChatViewModel(environment: environment,
                                                             sessionID: sessionId))
    }

    /// 直注实例（测试/宿主复用；与 environment 版共一存储）。
    init(viewModel: ChatViewModel) {
        self.sessionId = ""
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    // MARK: - Hero 相位（digest-H：无消息会话 = hero；首条消息发送即落底）

    private var heroMode: Bool {
        switch viewModel.phase {
        case .idle, .loading: break
        default: return false
        }
        return viewModel.bubbles.isEmpty
            && viewModel.streamingText.isEmpty
            && viewModel.pendingApprovals.isEmpty
            && viewModel.pendingQuestions.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if heroMode {
                    Spacer(minLength: 0)
                } else {
                    messageList
                        .transition(.opacity)
                }
                if heroMode {
                    heroHeader
                        .transition(.opacity)
                }
                // 降级横幅恒可见（hero 也显）——VM 装配失败（无端点/Key 不可读）
                // 时 loop=nil、send 静默 no-op，横幅是唯一解释（2026-09-20 真机
                // 反馈"发不了消息"根因：横幅原来在消息列表里，hero 态被整块隐藏）。
                if viewModel.phase == .loading {
                    // 装配期可见态（内核冷启动可达数十秒）——否则发送钮灰着
                    // 像坏了一样（真机反馈"点了没反应"的等待期形态）。
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在准备模型…")
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.labelTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                }
                if let banner = viewModel.resumeBanner {
                    degradationBanner(banner)
                }
                composerSeat
                    .background(composerChromeMeter)
                // StatsLine dock 恒渲染（用户既定裁定；hero 相同样在位）。
                WOStatsDock(line: viewModel.statsLine)
                if heroMode {
                    Spacer(minLength: 0)
                }
            }
            // slash 命令菜单（锚定 composer 卡上缘向上生长；zIndex 压过 chrome）。
            if slashMenuOpen {
                slashMenu
            }
        }
        // digest-H composer hero→dock FLIP 的近似：.42s out 曲线驱动布局迁移；
        // reduceMotion 由 woMotion 降级 0.15s easeOut（R6 拍板）。
        .woMotion(WOMotion.bezier(duration: 0.42), value: heroMode)
        .background(WOAlias.bgBase)
        .onAppear {
            viewModel.open()
            seedEntry()
            // dsh「hero 输入文本 = 新会话 composer draft」交接缝消费（旧
            // ChatView 同语义）：文本不丢，用户在会话内点发送才真正提交。
            if let firstDraft = environment.pendingFirstDraft {
                if viewModel.draft.isEmpty { viewModel.draft = firstDraft }
                environment.pendingFirstDraft = nil
            }
        }
        .onDisappear { viewModel.close() }
        .onChange(of: viewModel.phase) { _ in seedEntry() }
        .onChange(of: viewModel.draft) { newValue in
            // 选中写回后不再被 "/" 前缀拉起；清空草稿即复位（可再次唤起）。
            if newValue.isEmpty || !newValue.hasPrefix("/") {
                slashDismissed = false
            }
        }
        // 消息气泡图片原图预览（复用 MessageLightboxView；item 绑定 =
        // ImageAttachmentRef content-addressed 身份）。
        .fullScreenCover(item: $messagePreview) { ref in
            MessageLightboxView(ref: ref, store: viewModel.attachmentStore)
        }
        // A4：/permission danger-full-access 手输命令的前置风险确认
        // （GUI 入口的确认缝在 PermissionSelectView 内建；此 cover 接手输路径）。
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.pendingPermissionConfirmation != nil },
            set: { if !$0 { viewModel.cancelPendingPermission() } })) {
            ZStack {
                PermissionConfirmationGate(
                    onConfirm: { viewModel.confirmPendingPermission() },
                    onCancel: { viewModel.cancelPendingPermission() })
            }
            .presentationBackground(.clear)
        }
    }

    // MARK: - Hero 头（digest-H：logo 34px + 「万我」26px/500/-.4px）

    private var heroHeader: some View {
        VStack(spacing: 16) {
            WOFishLogo.logo(size: 34)
            Text("万我")
                .font(.system(size: 26, weight: .medium))
                .tracking(-0.4)
                .foregroundColor(WOAlias.labelPrimary)
        }
        .padding(.bottom, 26) // digest-H hero-composer-slot margin-top 26px
    }

    /// 降级横幅（装配失败=无 loop；琥珀条 + 恢复指引）。
    private func degradationBanner(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(WOAlias.stateWarnLabel)
            if !viewModel.isModelReady {
                Text("配置好 Providers 后，退出本会话再重新进入即可恢复发送。")
                    .font(.system(size: 11))
                    .foregroundColor(WOAlias.labelTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(WOAlias.stateWarnTertiary))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Composer 座位（接管语义：提问 > 审批 > 常规输入；
    // ComposerSeatRoute 纯函数序在 VM 层已保证 pendingApprovals/pendingQuestions 序）

    @ViewBuilder
    private var composerSeat: some View {
        if let approval = viewModel.pendingApprovals.first {
            WOApprovalCard(viewModel: viewModel, pending: approval)
        } else if let question = viewModel.pendingQuestions.first {
            WOQuestionCard(viewModel: viewModel, pending: question)
        } else {
            // digest-H 文案清单：hero「描述你想要构建的内容…」/ 会话「发消息或做任务…」。
            WOComposer(viewModel: viewModel,
                       placeholder: heroMode
                            ? "描述你想要构建的内容… / 调用指令 @ 文件或对话"
                            : "发消息或做任务… / 调用指令 @ 文件或对话",
                       degraded: !viewModel.isModelReady)
        }
    }

    // MARK: - Slash 命令菜单（引擎命令面在场：VM.slashCommandList）

    private var slashMenuOpen: Bool {
        guard !slashDismissed else { return false }
        guard viewModel.pendingApprovals.isEmpty,
              viewModel.pendingQuestions.isEmpty else { return false }
        switch viewModel.phase {
        case .idle, .failed: break
        default: return false
        }
        return viewModel.draft.hasPrefix("/")
    }

    private var slashMenu: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            WOSlashMenu(
                query: viewModel.draft,
                commands: viewModel.slashCommandList,
                onPick: { command in
                    // claim token 写回（dsh "/name " 带尾随空格）；先关菜单
                    // 防前缀条件又把它拉起。
                    slashDismissed = true
                    viewModel.draft = "/\(command.name) "
                })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, composerChromeHeight + 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .zIndex(2)
    }

    /// composer chrome 高度度量（座位 + dock；旧 ChatView 同法）。
    private var composerChromeMeter: some View {
        GeometryReader { geo in
            Color.clear.preference(key: WOComposerChromeHeightKey.self,
                                   value: geo.size.height)
        }
        .onPreferenceChange(WOComposerChromeHeightKey.self) { composerChromeHeight = $0 }
    }

    // MARK: - 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) { // digest-H .msgs gap 16
                    if viewModel.phase == .loading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 48)
                    }
                    let nodes = ConversationProjector.foldTurnProcess(viewModel.bubbles)
                    ForEach(nodes) { node in
                        entryNode(node)
                            .onTapGesture {
                                // 菜单开着时点消息区 = 区外关闭（dsh MenuView
                                // outside-click 语义的触屏形）。
                                if slashMenuOpen { slashDismissed = true }
                            }
                    }
                    if viewModel.phase == .streaming {
                        streamingBlock
                        // 深度求索中（digest-H turn-status；phase 锚点）。
                        WOShimmerText(text: "深度求索中...",
                                      font: .system(size: 14, weight: .medium))
                            .padding(.top, 2)
                    }
                    if case .failed(let message) = viewModel.phase {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(WOAlias.stateErrorPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(WOAlias.stateErrorSecondary))
                    }
                    Color.clear.frame(height: 8).id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .onChange(of: viewModel.bubbles) { _ in follow(proxy) }
            .onChange(of: viewModel.streamingText) { _ in follow(proxy) }
            .onChange(of: viewModel.streamingReasoning) { _ in follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    // MARK: - 入场门（mInL/mInR；历史种子不播、滚动重建不重播）

    private func seedEntry() {
        guard !entrySeeded, viewModel.phase != .loading else { return }
        entrySeeded = true
        animatedIDs.formUnion(viewModel.bubbles.map(\.id))
    }

    @ViewBuilder
    private func entryNode(_ node: ConversationProjector.DisplayNode) -> some View {
        let fromRight: Bool = {
            if case .plain(let bubble) = node,
               case .user = bubble.kind { return true }
            return false
        }()
        if animatedIDs.contains(node.id) {
            nodeBody(node)
        } else {
            nodeBody(node)
                .modifier(WOEntryModifier(
                    offset: CGSize(width: fromRight ? 16 : -16, height: 0),
                    duration: 0.55,
                    animate: true,
                    onSeen: { animatedIDs.insert(node.id) }))
        }
    }

    // MARK: - 展示节点渲染

    @ViewBuilder
    private func nodeBody(_ node: ConversationProjector.DisplayNode) -> some View {
        switch node {
        case .plain(let bubble):
            bubbleView(bubble)
        case .process(let group):
            // 过程组平铺渲染（不折叠）——思考与工具全可见；组折叠行=后续批。
            ForEach(group.bubbles) { inner in
                bubbleView(inner)
            }
        }
    }

    // MARK: - 单气泡渲染（全事件类型可见）

    @ViewBuilder
    private func bubbleView(_ bubble: ConversationProjector.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text, let images):
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    if !images.isEmpty {
                        // 消息内图片（复用 MessageImagesView；单图 80pt=
                        // 用户既定裁定 T2.6 件7，不改）。
                        MessageImagesView(images: images,
                                          store: viewModel.attachmentStore,
                                          onPreview: { messagePreview = $0 })
                    }
                    if !text.isEmpty {
                        // 纯图片消息不画气泡（dsh MessageItem 语义）。
                        Text(text)
                            .font(.system(size: 14))
                            .foregroundColor(WOStatic.neutral00)
                            .multilineTextAlignment(.trailing)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            // 原型规格：圆角 22 + 蓝软底（WOSpecific.bubble =
                            // deepseek-50）；82% 帽=用户气泡 max-width 上限近似。
                            .frame(maxWidth: 520, alignment: .trailing)
                            .background(RoundedRectangle(cornerRadius: 22).fill(WOSpecific.bubble))
                    }
                }
                .frame(maxWidth: 620, alignment: .trailing)
            }

        case .assistant(let text):
            // 助手行：渐变头像 + 正文（digest-H Bot 行形态；13px 时间戳因
            // 引擎气泡无墙钟字段缺席，登记报告）。
            HStack(alignment: .top, spacing: 8) {
                WOAssistantAvatar()
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(WOAlias.labelPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.top, 1)

        case .reasoning(let text):
            // 思考披露：标题 + 首行预览 + chevron；展开体左缩进 22（digest-H .think）。
            ReasoningDisclosure(text: text)

        case .tool(let card):
            // R2a：工具卡全型（digest-F §41；D6 清偿）。
            WOToolCard(card: card, sessionID: sessionId.isEmpty ? nil : sessionId)

        case .command(let kind, let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(kind)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgModulePlatform))

        case .note(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .turnUsage(let summary):
            // 轮次尾用量/用时 pill（引擎 TurnUsageSummary 在场 → 做）。
            HStack {
                WOTurnUsagePill(summary: summary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)

        default:
            // 其余次要事件：视觉回合分隔（无假文案）。
            VStack(spacing: 0) {
                Divider().opacity(0.5)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - 流式块（sweep 头 + 尾行跟随；ReasoningRow running 语义）

    private var streamingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.streamingReasoning.isEmpty {
                // 运行中思考头：module 底 + 白色扫光（digest-H .think running 2.6s）。
                HStack(spacing: 6) {
                    Text("思考")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WOAlias.labelTertiary)
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 48, minHeight: 24, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(WOAlias.bgModulePlatform))
                .modifier(WOSweepModifier(active: true))
                // 尾行跟随流式（ReasoningRow latestLine 语义）。
                Text(viewModel.streamingReasoning
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
                    .split(separator: "\n").last.map(String.init) ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineSpacing(2)
                    .lineLimit(2)
            }
            if !viewModel.streamingText.isEmpty {
                Text(viewModel.streamingText + " ▍")
                    .font(.system(size: 14))
                    .foregroundColor(WOAlias.labelPrimary)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// composer chrome 高度 PreferenceKey（slash 菜单锚定；旧 ChatView 同法）。
private struct WOComposerChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 思考披露（ReasoningRowView 语义简化版——旧件 98 行的折叠交互+WO 壳；
/// running 态扫光/尾行跟随的完整版随流式块呈现，此处为 settled 全文折叠）。
private struct ReasoningDisclosure: View {
    let text: String

    @State private var expanded = false

    private var preview: String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { toggle() } label: {
                HStack(spacing: 6) {
                    Text("思考")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WOAlias.labelTertiary)
                    if !expanded {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.labelSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WOAlias.labelTertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineSpacing(2)
                    .padding(.leading, 22) // digest-H .think 正文左缩进 22px
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        withAnimation(WOMotion.bezier(duration: WOMotion.t4)) { expanded.toggle() }
    }
}

// MARK: - Hero 空态（无当前会话：品牌+新会话引导；按钮真建会话）

//
//  WOChatHero —— 无会话空态（dsh EmptyHero.tsx 1:1 语义，ConversationEmptyStateView
//  旧件语义源 + digest-H hero 视觉；2026-09-20 用户指令"第二个做好，按 dsh 源码补"）：
//    · 工作区胶囊（WorkspaceChip）：folder 图标 + 项目名/「选择工作区」+ chevron，
//      SwiftUI Menu 弹层（列表勾选当前项 + 尾部「添加工作区…」）；选中即建会话入组
//      （workspaceNavigator.startSession —— 引擎既有缝，新会话不再落未分组）。
//    · 权限胶囊：三挡预设（与 dock 新会话默认同源 = permissionDefaults）；完全权限
//      走 PermissionConfirmationGate 确认缝（choosePermission :448 语义）。
//    · composer inert 语义（ConversationRoot.tsx:324-336）：未选工作区 = 同框 inert
//      （占位「选择一个工作区开始」，点击整框 = 开工作区菜单）；选中 = 可输入，
//      发送 = 草稿交接 pendingFirstDraft + startSession（dsh「hero 输入文本 =
//      新会话 composer draft」，文本不丢、会话内点发送才真正提交）。
//

import SwiftUI

struct WOChatHero: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var workspaces: [WorkspaceRecord] = []
    @State private var selectedWorkspaceID: String?
    @State private var heroDraft = ""
    @State private var showAddFlow = false
    @State private var newWorkspaceName = ""
    @State private var addFlowError: String?
    @State private var confirmingFullAccess = false

    private let permissionOptions: [(id: String, label: String)] = [
        ("read-only", "仅可查看"),
        ("workspace-write", "工作区内修改"),
        ("danger-full-access", "完全权限"),
    ]

    private var featured: WorkspaceRecord? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var currentPermissionLabel: String {
        permissionOptions.first { $0.id == environment.permissionDefaults.defaultPreset }?.label
            ?? environment.permissionDefaults.defaultPreset
    }

    var body: some View {
        ZStack {
            WOAlias.bgBase
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                headerBlock
                chipsRow
                    .padding(.top, 22)
                composerCard
                    .padding(.top, 14)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            if showAddFlow {
                addFlowCard
            }
        }
        .onAppear { refreshWorkspaces() }
        .fullScreenCover(isPresented: $confirmingFullAccess) {
            ZStack {
                PermissionConfirmationGate(
                    onConfirm: {
                        _ = environment.permissionDefaults.setDefault(named: "danger-full-access")
                        confirmingFullAccess = false
                    },
                    onCancel: { confirmingFullAccess = false })
            }
            .presentationBackground(.clear)
        }
    }

    // MARK: - 品牌头（digest-H hero：logo 40 + 「万我」26）

    private var headerBlock: some View {
        // digest-H hero：星形 logo 34px + 「万我」26px/500/tracking -0.4（无副标题——
        // 原型无此行，自创件撤除）
        VStack(spacing: 14) {
            WOFishLogo.logo(size: 34)
            Text("万我")
                .font(.system(size: 26, weight: .medium))
                .tracking(-0.4)
                .foregroundColor(WOAlias.labelPrimary)
        }
    }

    // MARK: - 胶囊行（workspace chip + 权限 chip；leading 对齐卡缘——EmptyHero :82）

    private var chipsRow: some View {
        HStack(spacing: 8) {
            workspaceChip
            permissionChip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 620)
    }

    /// WorkspaceChip：SwiftUI Menu 弹层（旧件 :320 同法）；当前项勾选 + 尾部「添加工作区…」。
    private var workspaceChip: some View {
        Menu {
            ForEach(workspaces) { ws in
                if ws.id == selectedWorkspaceID {
                    Button { pickWorkspace(ws) } label: {
                        Label(ws.title, systemImage: "checkmark")
                    }
                } else {
                    Button(ws.title) { pickWorkspace(ws) }
                }
            }
            Divider()
            Button {
                showAddFlow = true
            } label: {
                Label("添加工作区…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                Text(featured?.title ?? "选择工作区")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(featured == nil ? WOAlias.labelSecondary : WOAlias.labelPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28) // ws-chip：28px 高 / r16 / 13px/500（digest-H）
            .background(RoundedRectangle(cornerRadius: 16).fill(WOAlias.bgLayer3))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        }
    }

    /// 权限胶囊（三挡预设；与 dock 新会话默认同源 = permissionDefaults）。
    private var permissionChip: some View {
        Menu {
            ForEach(permissionOptions, id: \.id) { option in
                if option.id == environment.permissionDefaults.defaultPreset {
                    Button { choosePermission(option.id) } label: {
                        Label(option.label, systemImage: "checkmark")
                    }
                } else {
                    Button(option.label) { choosePermission(option.id) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12))
                Text(currentPermissionLabel)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(WOAlias.labelSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 16).fill(WOAlias.bgLayer3))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        }
    }

    /// 选择（PermissionDefaultsView.choose 同语义：同挡 no-op、完全权限先确认）。
    private func choosePermission(_ id: String) {
        if id == environment.permissionDefaults.defaultPreset { return }
        if id == "danger-full-access" {
            confirmingFullAccess = true
            return
        }
        _ = environment.permissionDefaults.setDefault(named: id)
    }

    // MARK: - composer（无工作区 inert / 有工作区可输入；同一卡形态）

    @ViewBuilder
    private var composerCard: some View {
        if featured == nil {
            // inert 态：整卡 = 工作区菜单的 label（dsh「点击整框 = 开工作区菜单」；
            // 虚线描边 + 静态底行——ConversationEmptyStateView 简版形态）。
            Menu {
                ForEach(workspaces) { ws in
                    Button(ws.title) { pickWorkspace(ws) }
                }
                Divider()
                Button {
                    showAddFlow = true
                } label: {
                    Label("添加工作区…", systemImage: "plus")
                }
            } label: {
                HStack(alignment: .bottom, spacing: 10) {
                    Text("选择一个工作区开始")
                        .font(.system(size: 14))
                        .foregroundColor(WOAlias.labelTertiary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WOAlias.labelTertiary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WOAlias.bgLayer3))
                        .opacity(0.5)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgLayer2))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(WOAlias.borderL2, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .frame(maxWidth: 620)
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("描述你想要构建的内容… / 调用指令 @ 文件或对话",
                          text: $heroDraft,
                          axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .padding(.leading, 8)
                    .padding(.vertical, 12)
                Button {
                    sendHeroDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WOAlias.buttonPrimaryFill))
                }
                .buttonStyle(.plain)
                .woPressable()
                .accessibilityLabel("开始新会话")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgLayer2))
            .overlay(RoundedRectangle(cornerRadius: 22)
                .strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
            .frame(maxWidth: 620)
        }
    }

    // MARK: - 动作（pick = 即建会话入组；send = 草稿交接 + 建会话）

    private func pickWorkspace(_ ws: WorkspaceRecord) {
        migrateHeroDraft()
        environment.workspaceNavigator.startSession(ws.id)
    }

    private func sendHeroDraft() {
        guard let featured else { return }
        migrateHeroDraft()
        environment.workspaceNavigator.startSession(featured.id)
    }

    /// 草稿交接（dsh「hero 输入文本 = 新会话 composer draft」）：
    /// 非空草稿写 pendingFirstDraft 缝并清空；空草稿不动缝。
    private func migrateHeroDraft() {
        let draft = heroDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        environment.pendingFirstDraft = heroDraft
        heroDraft = ""
    }

    // MARK: - 添加流（命名卡 → adopt → startSession；唯一路径，旧件 :505 同语义）

    private var addFlowCard: some View {
        ZStack {
            WOAlias.bgMask1
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showAddFlow = false }
            VStack(alignment: .leading, spacing: 14) {
                Text("添加工作区")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                TextField("输入项目名", text: $newWorkspaceName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                    .onSubmit { confirmAddWorkspace() }
                if let error = addFlowError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(WOAlias.stateErrorPrimary)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button {
                        showAddFlow = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WOAlias.labelPrimary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgLayer3))
                    }
                    .buttonStyle(.plain)
                    Button {
                        confirmAddWorkspace()
                    } label: {
                        Text("确认")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WOStatic.neutral00)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? WOAlias.buttonPrimaryDimmed
                                      : WOAlias.buttonPrimaryFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(18)
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 16).fill(WOAlias.bgLayer2))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        }
    }

    private func confirmAddWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let workspace = try WorkspaceAdoption.adopt(name: name, environment: environment)
            showAddFlow = false
            newWorkspaceName = ""
            addFlowError = nil
            refreshWorkspaces()
            migrateHeroDraft()
            environment.workspaceNavigator.startSession(workspace.id)
        } catch {
            addFlowError = (error as? LocalizedError)?.errorDescription ?? "创建失败，请重试"
        }
    }

    private func refreshWorkspaces() {
        workspaces = environment.workspaceRegistry.list()
    }
}
