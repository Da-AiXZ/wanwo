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
                       placeholder: heroMode ? "描述你想要构建的内容…" : "发消息或做任务…")
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
                    if let banner = viewModel.resumeBanner {
                        Text(banner)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.stateWarnLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
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

struct WOChatHero: View {
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            WOFishLogo.logo(size: 40)
            Text("万我")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(WOAlias.labelPrimary)
            Text("告诉我要做什么，我来在你的 iPad 上完成")
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelTertiary)
            Button(action: onNewSession) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                    Text("新会话")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(WOStatic.neutral00)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(Capsule().fill(WOAlias.buttonPrimaryFill))
            }
            .buttonStyle(.plain)
            .woPressable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WOAlias.bgBase)
    }
}
