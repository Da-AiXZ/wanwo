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
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct WOChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appState: WOAppState
    private let sessionId: String

    /// 批C1：顶栏右栏开关回调（workspaceSidebar 真值在 WORootFrame，闭包下发；
    /// nil = 宿主未接（测试/直注实例）→ 顶栏不出开关钮）。
    var onToggleRightSidebar: (() -> Void)? = nil

    /// 批C4：autoFollow 闸门（digest-K 6.3#1 清偿）——尾部探针可见（用户在
    /// 底部附近）时内容变化才滚底；探针出上缘（用户在历史区）暂停；探针回
    /// 视口（滚回底部）自动恢复。批C5-QA 修正：出下缘保持现态（内容增长推挤
    /// 的瞬间出下缘不构成暂停，跟随中 scrollTo 会拉回）；暂停不再要求拖拽
    /// 活性（惯性段出界也正确暂停）。
    @State private var autoFollow = true
    /// 曾到达底部（批C4-QA 修正：防打开历史会话首帧探针在视口上方被误判暂停
    /// ——未到过底部前不允许"出上缘暂停"分支生效，打开即滚底）。
    @State private var hasReachedTail = false
    @State private var viewportGlobalFrame: CGRect = .zero
    /// 批C4：顶栏丝线判定（原型 .main-head.scrolled：scrollTop>4）。
    @State private var headScrolled = false
    /// 简化自动跟随（批 1）：内容变化即滚底；治理=批C4 autoFollow 闸门。
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
    /// 批A2：会话内 hero 芯片菜单的「添加工作区…」流（与 WOChatHero 共用
    /// 批10：添加工作区统一弹窗（共用件 WOAddWorkspaceModal）呈现位。
    @State private var showAddFlow = false

    /// hero 附件交接消费标记（init 只读判定；消费在 onAppear 安全期执行——
    /// struct init 运行于父 body 求值中，彼时写 ObservableObject 属
    /// "Modifying state during view update" 违例）。
    private let consumesPendingImages: Bool
    /// hero 一步发送旗（onAppear 摘旗；引擎装配完成（.idle）即自动提交首条）。
    @State private var autoSubmitArmed = false

    init(environment: AppEnvironment, sessionId: String,
         onToggleRightSidebar: (() -> Void)? = nil) {
        self.sessionId = sessionId
        self.onToggleRightSidebar = onToggleRightSidebar
        // dsh 草稿跨切换种子（ConversationSession mount 规则，**只读**——
        // pendingFirstDraft 的消费清理由 onAppear 既有块承担）：会话缓存草稿
        // 优先（blank 会话复用时草稿跟回）；否则用 hero 交接文本。
        var seed = ""
        if let cached = environment.appState.cachedDraft(for: sessionId), !cached.isEmpty {
            seed = cached
        } else if let pending = environment.pendingFirstDraft {
            seed = pending
        }
        self.consumesPendingImages = !environment.pendingDraftImages.isEmpty
        _viewModel = StateObject(wrappedValue: ChatViewModel(environment: environment,
                                                             sessionID: sessionId,
                                                             initialDraft: seed))
    }

    /// 直注实例（测试/宿主复用；与 environment 版共一存储）。
    init(viewModel: ChatViewModel) {
        self.sessionId = ""
        self.onToggleRightSidebar = nil
        self.consumesPendingImages = false
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
            // 批C3：对话态消息列表全高（ZStack 底层），composerSeat+StatsDock
            // 悬浮底部——旧 VStack 渐隐带占位条退役（跟随滞后切边病灶根治）。
            if !heroMode {
                messageList
                    .transition(.opacity)
            }
            // 底部座位组（hero 与 dock 共用同一 composerSeat 实例——C2 FLIP
            // 保持：条件块都位于座位之前的独立槽位，座位跨 heroMode 换相不换
            // 身份，.woMotion(0.42) 驱动布局迁移）。
            VStack(spacing: 0) {
                if heroMode {
                    Spacer(minLength: 0)
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
                // 批10：composer 上方悬浮渐隐罩退役（2026-09-22 真机反馈"渐变
                // 太奇怪、就做一小块"——620 宽 36pt 罩在卡上缘呈灰斑；用户令
                // 删除不再做渐变。内容贴卡上缘自然裁切，滚动跟随由 autoFollow
                // 闸门+列表底部 padding 保证）。
                // StatsLine dock 恒渲染（用户既定裁定；hero 相同样在位）。
                WOStatsDock(line: viewModel.statsLine)
                if heroMode {
                    Spacer(minLength: 0)
                }
            }
            // 批C1：顶部对话标题栏（悬浮 ZStack top + 44pt 顶部渐隐罩；
            // heroMode 不渲染——hero 自带品牌头）。
            if !heroMode {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [.clear, WOAlias.bgBase],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                    conversationHead
                        // 批C4：顶栏滚动丝线（原型 .main-head.scrolled，scrollTop>4）。
                        .overlay(alignment: .bottom) {
                            if headScrolled {
                                Rectangle().fill(WOAlias.borderL1).frame(height: 0.5)
                            }
                        }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // slash 命令菜单（锚定 composer 卡上缘向上生长；zIndex 压过 chrome）。
            if slashMenuOpen {
                slashMenu
            }
        }
        // 批10：添加工作区统一弹窗（共用件 WOAddWorkspaceModal，三入口同一
        // 形态——透明蒙层+380 卡+重名门控；adopt 后 startSession 打开新工作区
        // 会话，语义沿原 FlowCard）。
        .fullScreenCover(isPresented: $showAddFlow) {
            WOAddWorkspaceModal(isPresented: $showAddFlow) { workspace in
                environment.workspaceNavigator.startSession(workspace.id)
            }
            .presentationBackground(.clear) // 批10：透出当前页（白卡轻影浮层）
        }
        // digest-H composer hero→dock FLIP 的近似：.42s out 曲线驱动布局迁移；
        // reduceMotion 由 woMotion 降级 0.15s easeOut（R6 拍板）。
        .woMotion(WOMotion.bezier(duration: 0.42), value: heroMode)
        // 草稿缓存（dsh draft 持久跨切换；切走再切回文本跟回）。
        .onChange(of: viewModel.draft) { text in
            appState.updateDraft(text, for: sessionId)
        }
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
            // hero 附件交接缝消费（预会话图片 → VM 草稿图）。
            if consumesPendingImages {
                viewModel.addDraftImages(environment.pendingDraftImages)
                environment.pendingDraftImages = []
            }
            // 一步发送摘旗（引擎就绪时由 phase onChange 触发提交）。
            if environment.pendingAutoSubmit {
                autoSubmitArmed = true
                environment.pendingAutoSubmit = false
            }
        }
        .onDisappear { viewModel.close() }
        .onChange(of: viewModel.phase) { _ in
            seedEntry()
            // hero 一步发送：引擎装配完成即自动提交（draft 已由 init 种子带入；
            // 未就绪/装配失败时旗不消费——草稿保留，用户按指引恢复后手动发）。
            if autoSubmitArmed, viewModel.phase == .idle,
               !viewModel.isDraftEmpty {
                autoSubmitArmed = false
                viewModel.send()
            }
        }
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

    // MARK: - 顶部对话标题栏（批C1；digest-H .main-head 形态）

    /// 当前会话标题（sessionStore 既有路径；blank/空标题 → digest-H 词汇
    /// 「新会话」——原型 convTitle 默认值同文）。
    private var sessionTitle: String {
        let title = environment.sessionStore.listSessions()
            .first { $0.id == sessionId }?.title
        return (title?.isEmpty == false) ? (title ?? "新会话") : "新会话"
    }

    /// 高 44pt：左=状态点 6pt（原型 .head-title .dot：流式 ongoing 蓝 / 其余
    /// done 绿）+ 会话标题 14pt/500；右=右栏开关钮（规格=退役的
    /// reopenSidebarButton：32pt r9 玻璃白 .9+blur；本批两处悬浮双钮已删，
    /// 本钮是唯一入口）。
    private var conversationHead: some View {
        HStack(spacing: 8) {
            WOStateDot(state: viewModel.phase == .streaming ? .ongoing : .done,
                       size: 6)
                .frame(width: 10, height: 10) // ongoing 像素环按 10 网格绘制
            Text(sessionTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(WOAlias.labelPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let onToggle = onToggleRightSidebar {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(WOAlias.labelSecondary)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(WOStatic.neutral00.opacity(0.9)))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开或收起工作区侧栏")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    // MARK: - Hero 头（digest-H：logo 34px + 「万我」26px/500/-.4px）

    /// 当前会话所属工作区（registry 账本反查；blank 会话 hero chip 用）。
    private var sessionWorkspaceID: String? {
        environment.workspaceRegistry.list()
            .first { $0.sessionIds.contains(sessionId) }?.id
    }

    private var sessionWorkspaceTitle: String? {
        environment.workspaceRegistry.list()
            .first { $0.sessionIds.contains(sessionId) }?.title
    }

    /// 全部工作区（chip 菜单数据源）。
    private var sessionWorkspaces: [WorkspaceRecord] {
        environment.workspaceRegistry.list()
    }

    /// chip 选择（dsh navigation：打开所选工作区复用/新建的会话；本会话
    /// 未发消息则留在原地藏于列表，草稿留在本会话缓存不丢）。
    private func pickSessionWorkspace(_ ws: WorkspaceRecord) {
        environment.workspaceNavigator.startSession(ws.id)
    }

    private var heroHeader: some View {
        // digest-H hero：星形 logo 34 + 「万我」26/500/-0.4 同行左对齐
        //（2026-09-21 真机对照原型：竖排居中形态与原型不符）。
        // 批10：logo 换原型四芒星（WOBrandMark，用户令）；芯片行对齐原型
        // .hero-capsules（padding-left 20 / margin-top 4）。
        // 批10 再修：星标 34→40（真机对照原型 2403/2407 观感偏小）。
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                WOBrandMark.mark(size: 40)
                Text("万我")
                    .font(.system(size: 26, weight: .medium))
                    .tracking(-0.4)
                    .foregroundColor(WOAlias.labelPrimary)
            }
            // blank 会话 hero 的工作区 chip = 真·工作区选择器（dsh EmptyHero：
            // 未发消息前项目可换——选择= startSession(所选) 打开那边复用/新建
            // 的会话，本项目 dsh navigation.ts 语义；发过消息 cwd 定格后本
            // header 不再渲染，不存在"锁死"面）。无归属会话（历史孤儿）也走
            // 此选择器补选。批A2：菜单尾部补「添加工作区…」，与 WOChatHero
            // 批10：尾部补「添加工作区…」，呈现走统一弹窗 WOAddWorkspaceModal。
            Menu {
                if sessionWorkspaces.isEmpty {
                    Text("暂无工作区")
                }
                ForEach(sessionWorkspaces) { ws in
                    if ws.id == sessionWorkspaceID {
                        Button { pickSessionWorkspace(ws) } label: {
                            Label(ws.title, systemImage: "checkmark")
                        }
                    } else {
                        Button(ws.title) { pickSessionWorkspace(ws) }
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
                    Text(sessionWorkspaceID != nil
                         ? (sessionWorkspaceTitle ?? "选择工作区")
                         : "选择工作区")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(WOAlias.labelPrimary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 16).fill(WOAlias.bgLayer3))
            }
            // 批10：对齐原型 .hero-capsules（padding-left 20 / margin-top 4，
            // 原值 14 偏大；logo/芯片/卡左缘关系=0/20/0 与原型一致）。
            .padding(.leading, 20)
            .padding(.top, 4)
        }
        .frame(maxWidth: 620, alignment: .leading)
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
            // 批C2：composer hero/dock 统一 620 限宽水平居中（IMG_2386 通栏
            // 扁条根治；发送后同卡随 .woMotion 落底，宽度不变=FLIP 平移）。
            // 批10：dock 态水平外距 14 由宿主补（原在 WOComposer 组件内，
            // 迁出后 hero 态卡背景可与品牌行左缘对齐，见 WOComposer 头注）。
            // digest-H 文案清单：hero「描述你想要构建的内容…」/ 会话「发消息或做任务…」。
            WOComposer(viewModel: viewModel,
                       placeholder: heroMode
                            ? "描述你想要构建的内容… / 调用指令 @ 文件或对话"
                            : "发消息或做任务… / 调用指令 @ 文件或对话",
                       degraded: !viewModel.isModelReady)
                .frame(maxWidth: 620)
                .padding(.horizontal, heroMode ? 0 : 14)
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
                    // 批C4：顶部探针（1pt；global minY 与视口差 >4pt → 顶栏丝线）。
                    Color.clear
                        .frame(height: 1)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: WOChatTopProbeKey.self,
                                                   value: geo.frame(in: .global).minY)
                        })
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
                    // 批C4：尾部探针（1pt；视口内可见性 → autoFollow 闸门）。
                    Color.clear
                        .frame(height: 1)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: WOChatTailProbeKey.self,
                                                   value: geo.frame(in: .global).maxY)
                        })
                }
                // 批C3（原型 .msgs padding:14px 16px 140px 折算）：顶部 14+44
                // （首条消息初始落在顶栏下），底部 140（composer 悬浮区让位）。
                .padding(.horizontal, 16)
                .padding(.top, 58)
                .padding(.bottom, 140)
            }
            // 批C4：视口 global 框（探针可见性判定的同一坐标系基准）。
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: WOChatViewportKey.self,
                                           value: geo.frame(in: .global))
                }
            )
            .onPreferenceChange(WOChatViewportKey.self) { viewportGlobalFrame = $0 }
            .onPreferenceChange(WOChatTailProbeKey.self) { updateAutoFollow($0) }
            .onPreferenceChange(WOChatTopProbeKey.self) { updateHeadScrolled($0) }
            .onChange(of: viewModel.bubbles) { _ in follow(proxy) }
            .onChange(of: viewModel.streamingText) { _ in follow(proxy) }
            .onChange(of: viewModel.streamingReasoning) { _ in follow(proxy) }
        }
    }

    /// 批C4：跟随判定——探针可见（用户在底部附近）才随内容变化滚底。
    private func follow(_ proxy: ScrollViewProxy) {
        guard autoFollow else { return }
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }

    /// 批C4：探针可见性 → autoFollow（批C4-QA 修正三分支）。
    private func updateAutoFollow(_ tailY: CGFloat?) {
        guard let tailY else { return } // LazyVStack 回收探针：保持上次判定
        if tailY <= viewportGlobalFrame.maxY, tailY >= viewportGlobalFrame.minY {
            // 探针在视口内（底部附近）：恢复跟随，并登记"曾到达底部"。
            if !autoFollow { autoFollow = true }
            if !hasReachedTail { hasReachedTail = true }
        } else if tailY < viewportGlobalFrame.minY, hasReachedTail, autoFollow {
            // 探针出上缘（用户在历史区）→ 暂停。不再要求 dragActive——
            // 极小拖距+长惯性（手指抬起后探针才出界）也正确暂停。
            autoFollow = false
        }
        // 探针出下缘：保持现态——跟随中 scrollTo 会拉回（内容增长推挤的
        // 瞬间出下缘不构成暂停）；暂停中随内容增长远去，回视口才恢复。
    }

    /// 批C4：顶部探针 → 顶栏丝线（scrollTop>4；探针初位=视口顶+58 顶部
    /// padding，滚过 4pt 即丝线现形；探针被 LazyVStack 回收后保持现态——
    /// 深滚时丝线恒显=正确语义）。
    private func updateHeadScrolled(_ topY: CGFloat?) {
        guard let topY else { return }
        let scrolled = topY < viewportGlobalFrame.minY + 58 - 4
        if headScrolled != scrolled { headScrolled = scrolled }
    }

    // MARK: - 入场门（mInL/mInR；历史种子不播、滚动重建不重播）

    private func seedEntry() {
        guard !entrySeeded, viewModel.phase != .loading else { return }
        entrySeeded = true
        animatedIDs.formUnion(viewModel.bubbles.map(\.id))
    }

    @ViewBuilder
    private func entryNode(_ node: ConversationProjector.DisplayNode) -> some View {
        // 消息=mInL/mInR（.55s 横移+缩放）；工具卡=fadeUp（.4s 自下 8px，
        // 无缩放——digest-H 工具卡 fadeUp .4s 独立曲线，与消息入场分立）。
        let isTool: Bool = {
            if case .plain(let bubble) = node,
               case .tool = bubble.kind { return true }
            return false
        }()
        let fromRight: Bool = {
            if case .plain(let bubble) = node,
               case .user = bubble.kind { return true }
            return false
        }()
        if animatedIDs.contains(node.id) {
            nodeBody(node)
        } else if isTool {
            nodeBody(node)
                .modifier(WOEntryModifier(
                    offset: CGSize(width: 0, height: 8),
                    scale: 1,
                    duration: 0.4,
                    animate: true,
                    onSeen: { animatedIDs.insert(node.id) }))
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
                        // 批C5（原型 :180 .user-bubble）：去 textSelection 改
                        // contextMenu 拷贝；padding 10/16（宽度随字数，蓝底
                        // 贴字细条根治）；lineSpacing 4（22px 行高目标）；
                        // 圆角 22 + 蓝软底（WOSpecific.bubble）+ max-width 508
                        // （620 列的 82%）保持。
                        Text(text)
                            .font(.system(size: 14))
                            .foregroundColor(WOAlias.labelPrimary)
                            .multilineTextAlignment(.trailing)
                            .lineSpacing(4)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(RoundedRectangle(cornerRadius: 22).fill(WOSpecific.bubble))
                            .frame(maxWidth: 508, alignment: .trailing)
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = text
                                } label: {
                                    Label("拷贝", systemImage: "doc.on.doc")
                                }
                            }
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

/// 批C4 滚动探针 PreferenceKeys（Optional 单值——探针被 LazyVStack 回收时
/// 不再产出，宿主保持上次判定）。
private struct WOChatTailProbeKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

private struct WOChatTopProbeKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

private struct WOChatViewportKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
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
        // 原型思考披露展开 .32s（grid-template-rows 0fr↔1fr .32s；t4 0.5s 退役）。
        withAnimation(WOMotion.bezier(duration: 0.32)) { expanded.toggle() }
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
    /// 批10：呈现位下沉统一弹窗 WOAddWorkspaceModal（与 WOChatHero/侧栏
    /// 三入口共用同一组件）。
    @State private var confirmingFullAccess = false
    /// hero 附件（预会话草稿图；发送/选定工作区时经 pendingDraftImages 缝
    /// 交接进新会话 VM——"hero + 钮承接"补缝，2026-09-21 用户令）。
    @State private var heroPhotoSelection: [PhotosPickerItem] = []
    @State private var heroImages: [ChatViewModel.DraftImageCandidate] = []
    /// 胶囊即时刷新镜像（PermissionDefaultStore/EndpointStore 非本视图
    /// Observed 对象——选中后手动同步，防 label 滞后到下一次 body 求值）。
    @State private var currentPresetID = ""
    @State private var currentModelName = ""

    /// 权限三挡（与旧 EmptyStateView.choosePermission 同源；选中工作区后才显）。
    private let permissionOptions: [(id: String, label: String)] = [
        ("read-only", "仅可查看"),
        ("workspace-write", "工作区内修改"),
        ("danger-full-access", "完全权限"),
    ]

    private var featured: WorkspaceRecord? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    private var currentPermissionLabel: String {
        permissionOptions.first { $0.id == currentPresetID }?.label ?? currentPresetID
    }

    var body: some View {
        ZStack {
            WOAlias.bgBase
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    headerBlock
                    workspaceChipRow
                        .padding(.top, 12)
                    composerCard
                        .padding(.top, 26) // digest-H hero-composer-slot margin-top 26px
                }
                .frame(maxWidth: 620)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        // 批10：添加工作区统一弹窗（共用件，三入口同一形态）；采纳回调=
        // 原宿主侧三步（刷新列表/草稿交接/置选中）+ startSession 打开。
        .fullScreenCover(isPresented: $showAddFlow) {
            WOAddWorkspaceModal(isPresented: $showAddFlow) { workspace in
                handleAdoptedWorkspace(workspace)
                environment.workspaceNavigator.startSession(workspace.id)
            }
            .presentationBackground(.clear) // 批10：透出当前页（白卡轻影浮层）
        }
        .onAppear {
            refreshWorkspaces()
            currentPresetID = environment.permissionDefaults.defaultPreset
            currentModelName = environment.endpointStore.activeEndpoint()?.model ?? "选择模型"
            // 预选最近活动工作区（dsh startSession recent 语义：「项目自动选好
            // 上一个打开的对话所在的项目」——组内最新 updatedAt 者为 featured）。
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = WorkspaceNavigator.recentWorkspace(
                    workspaces,
                    sessions: environment.sessionStore.listSessions())
            }
        }
        .onChange(of: heroPhotoSelection) { items in
            guard !items.isEmpty else { return }
            let picked = items
            heroPhotoSelection = []
            Task {
                var candidates: [ChatViewModel.DraftImageCandidate] = []
                for item in picked {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    candidates.append(.init(data: data,
                                            mediaType: WOComposer.mediaType(of: item.supportedContentTypes),
                                            name: nil))
                }
                heroImages.append(contentsOf: candidates)
            }
        }
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

    // MARK: - 品牌头（digest-H hero：✦ 34 + 「万我」26/500/-0.4 同行左对齐）

    private var headerBlock: some View {
        HStack(spacing: 10) {
            WOBrandMark.mark(size: 40) // 批10：品牌标统一换原型四芒星（40=真机对照放大）
            Text("万我")
                .font(.system(size: 26, weight: .medium))
                .tracking(-0.4)
                .foregroundColor(WOAlias.labelPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 工作区胶囊行（仅 ws-chip；权限挡位在选中后才入 composer 工具组
    // ——2026-09-21 用户令：未选工作区时无权限模式，与 dsh inert 语义一致）

    private var workspaceChipRow: some View {
        HStack(spacing: 8) {
            workspaceChip
            Spacer(minLength: 0)
        }
        // 批10：对齐原型 .hero-capsules padding-left 20（与会话内 heroHeader 同款）
        .padding(.leading, 20)
    }

    /// WorkspaceChip：SwiftUI Menu（旧件 :320 同法）；当前项勾选 + 尾部「添加工作区…」。
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
        }
    }

    // MARK: - composer（dsh EmptyHero inert 语义：未选 = 整卡即工作区 picker，
    // 只读「选择一个工作区开始」+ 发送灰；选中 = 可输入/可发送/可调权限挡位）

    @ViewBuilder
    private var composerCard: some View {
        if featured == nil {
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
                // 整卡=工作区 picker 触发面（dsh workspaceTrigger）。结构对齐
                // 原型：占位输入区（readOnly「选择一个工作区开始」）+ dock 行
                //（.tools=[+] / .trailing=[model-pill, ring, send]；权限挡位
                // 未选工作区时隐藏=permWrap display:none）。
                //（批4 回归修复：曾把占位输入区整块弄丢只剩 dock 行。）
                VStack(spacing: 0) {
                    Text("选择一个工作区开始")
                        .font(.system(size: 14))
                        .foregroundColor(WOAlias.labelTertiary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.leading, 4)
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WOAlias.labelSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(WOAlias.bgModulePlatform))
                            .overlay(Circle().strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
                        Spacer(minLength: 0)
                        Text("选择模型")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WOAlias.labelSecondary)
                        heroRing
                        heroSendIcon(active: false)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgBase))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.03), radius: 16, y: 4)
            }
        } else {
            VStack(spacing: 0) {
                // 已选图片 chip（最小承接 UI；dsh att-row 缩略图形态的极简版）
                if !heroImages.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                        Text("图片 ×\(heroImages.count)")
                            .font(.system(size: 12))
                        Button {
                            heroImages = []
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(WOAlias.labelSecondary)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(WOStatic.neutral00.opacity(0.72)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空已选图片")
                    }
                    .foregroundColor(WOAlias.stateBusinessPrimary)
                    .padding(.leading, 8)
                    .padding(.trailing, 5)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(WOStatic.deepseek100))
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("描述你想要构建的内容… / 调用指令 @ 文件或对话",
                          text: $heroDraft,
                          axis: .vertical)
                    .font(.system(size: 14))
                    .lineSpacing(10)
                    .tint(WOAlias.stateBusinessPrimary)
                    .lineLimit(1...7)
                    .padding(.leading, 14)
                    .padding(.top, heroImages.isEmpty ? 12 : 6)
                    .padding(.bottom, 6)
                // 底行（原型 .tools=[+, perm] 左；.trailing=[model, send] 右）
                HStack(spacing: 8) {
                    PhotosPicker(selection: $heroPhotoSelection, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WOAlias.labelSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(WOAlias.bgModulePlatform))
                            .overlay(Circle().strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
                    }
                    .accessibilityLabel("添加图片")

                    permissionChip

                    Spacer(minLength: 0)

                    heroModelChip

                    Button {
                        sendHeroDraft()
                    } label: {
                        heroSendIcon(active: true)
                    }
                    .buttonStyle(.plain)
                    .woPressable()
                    .accessibilityLabel("开始新会话")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgBase))
            .overlay(RoundedRectangle(cornerRadius: 22)
                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.03), radius: 16, y: 4)
            .shadow(color: .black.opacity(0.03), radius: 24)
        }
    }

    /// 上下文环装饰（inert dock 形态件；0 占用无数字=不造假）。
    private var heroRing: some View {
        Circle()
            .strokeBorder(WOAlias.borderL2, lineWidth: 1.5)
            .frame(width: 14, height: 14)
    }

    private func heroSendIcon(active: Bool) -> some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(active ? WOStatic.neutral00 : WOAlias.labelTertiary)
            .frame(width: 34, height: 34)
            .background(Circle().fill(active ? WOAlias.buttonPrimaryFill
                                             : WOAlias.bgModulePlatform))
            .opacity(active ? 1 : 0.4)
    }

    /// 权限胶囊（选中工作区后出现；默认挡 = permissionDefaults，完全权限走确认缝）。
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
            }
            .foregroundColor(WOAlias.labelSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
    }

    /// 模型胶囊（hero 无会话级选择——选择落在端点默认上，新会话按默认解析；
    /// 真菜单真动作，EndpointStore.setActive 既有缝）。
    private var heroModelChip: some View {
        Menu {
            ForEach(environment.endpointStore.endpoints.filter { $0.isEnabled }) { ep in
                if ep.model == currentModelName {
                    Button {
                        environment.endpointStore.setActive(ep)
                        currentModelName = ep.model
                    } label: {
                        Label(ep.model, systemImage: "checkmark")
                    }
                } else {
                    Button(ep.model) {
                        environment.endpointStore.setActive(ep)
                        currentModelName = ep.model
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentModelName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(WOAlias.labelSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
    }

    /// 权限选择（同挡 no-op；完全权限先确认——PermissionDefaultsView.choose 同语义）。
    private func choosePermission(_ id: String) {
        if id == currentPresetID { return }
        if id == "danger-full-access" {
            confirmingFullAccess = true
            return
        }
        if environment.permissionDefaults.setDefault(named: id) {
            currentPresetID = id
        }
    }

    // MARK: - 动作（pick = 选定即建/复用会话入组；send = 草稿交接 + 建会话）

    private func pickWorkspace(_ ws: WorkspaceRecord) {
        migrateHeroDraft()
        selectedWorkspaceID = ws.id
        environment.workspaceNavigator.startSession(ws.id)
    }

    private func sendHeroDraft() {
        guard let featured else { return }
        migrateHeroDraft()
        // 一步发送（原型 hero 发送=建会话并立即提交首条消息）：
        // 草稿/图片已交接，会话打开后由 WOChatView 在引擎就绪时自动提交。
        environment.pendingAutoSubmit = true
        environment.workspaceNavigator.startSession(featured.id)
    }

    /// 草稿交接（dsh「hero 输入文本 = 新会话 composer draft」）：非空草稿写
    /// pendingFirstDraft 缝并清空；会话缓存草稿优先于 hero 文本（WOChatView
    /// init 种子规则——已有输入的 blank 会话不被覆盖）。
    private func migrateHeroDraft() {
        // 图片先行（pendingDraftImages 缝；WORootFrame startSession → 新会话
        // WOChatView.onAppear 消费 → VM.addDraftImages）。
        if !heroImages.isEmpty {
            environment.pendingDraftImages = heroImages
            heroImages = []
        }
        let draft = heroDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        environment.pendingFirstDraft = heroDraft
        heroDraft = ""
    }

    // MARK: - 添加流（命名卡 → adopt → startSession；唯一路径，旧件 :505 同语义）
    //
    //  批10：卡片与确认逻辑下沉统一弹窗 WOAddWorkspaceModal（本文件，
    //  会话内 hero 芯片菜单同用）。宿主侧仅保留采纳成功后的三步同步——
    //  时序保持原 confirmAddWorkspace：刷新列表 → 草稿交接（先于
    //  startSession，新会话 onAppear 才消费得到）→ 置选中。

    private func handleAdoptedWorkspace(_ workspace: WorkspaceRecord) {
        refreshWorkspaces()
        migrateHeroDraft()
        selectedWorkspaceID = workspace.id
    }

    private func refreshWorkspaces() {
        workspaces = environment.workspaceRegistry.list()
    }
}
