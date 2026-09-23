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
// 批12 T7：流式 Markdown 渲染（SwiftStreamingMarkdown v0.7.0）——仅本文件
// import（用户气泡/思考正文/工具卡输出不接库，保持 Text）。
import SwiftStreamingMarkdown

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
    /// 批12 T7：流式正文 Markdown 桥接（StreamedMarkdownSource；离开
    /// .streaming 即 finish 并重建，供下一回合——见 phase onChange 链）。
    @State private var streamSource = WOChatStreamSource()

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

    /// 会话是否已有内容（SessionIndexProbe 口径：header 不计入 eventCount，
    /// >0 = 至少一条事件）。同步既有路径（sessionTitle 同款 listSessions）。
    private var hasHistory: Bool {
        guard let summary = environment.sessionStore.listSessions()
            .first(where: { $0.id == sessionId }) else { return false }
        return summary.eventCount > 0
    }

    private var heroMode: Bool {
        // 批12：有历史的会话不进 hero——切对话时 composer 恒在底部、消息
        // 静默呈现（用户令 2026-09-23：切会话不再走"空态 hero→dock 落底"
        // 动画流程；旧记录淡出/新记录直接呈现，dock 原地不动）。
        // 加载期(.loading)的历史会话也锁 dock——hero 闪现病根在此。
        if hasHistory { return false }
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
            // 批13：底部渐变衬罩（用户令 2026-09-23：与顶栏对称、方向相反——
            // 上 100% 透明→下 0% 透明，内容从统计行后面滚过时在底部淡出；
            // 范围=统计行+底部安全区一带全宽，不挡触控）。
            if !heroMode {
                LinearGradient(colors: [.clear, WOAlias.bgBase],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 88)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
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
                // 批13：620 限宽与 composer 卡同轴（原全宽拉通，用户令对齐
                // dock 对称轴——行左缘对齐卡左缘）。
                WOStatsDock(line: viewModel.statsLine)
                    .frame(maxWidth: 620)
                if heroMode {
                    Spacer(minLength: 0)
                }
            }
            // 批C1：顶部对话标题栏（悬浮 ZStack top + 44pt 顶部渐隐罩；
            // heroMode 不渲染——hero 自带品牌头）。
            if !heroMode {
                ZStack(alignment: .top) {
                    // 批12：方向反转（用户令 2026-09-23：上缘 0% 透明→下缘 100%
                    // 透明，越靠上越不透明——内容从栏下滚过时被上缘实色遮住）。
                    LinearGradient(colors: [WOAlias.bgBase, .clear],
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
            // 批15：锚点埋点（App 一进会话必写一条——日志文件必然出现，
            // 用于分辨"日志通道坏了"还是"按钮事件没触发"）。
            RightRailDiag.event("会话视图出现 sessionId=\(sessionId)")
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
        .onChange(of: viewModel.phase) { phase in
            seedEntry()
            // 批12 T7：流式 Markdown 桥接生命周期——离开 .streaming 即终结流并
            // 重建（供下一回合；finish 后 StreamedMarkdownView 以终态收尾）；
            // 进入 .streaming 时正文若已先行到达则补发一次全文快照（AsyncStream
            // unbounded 缓冲，挂载前的 yield 不丢）。
            if phase == .streaming {
                if !viewModel.streamingText.isEmpty {
                    streamSource.emit(viewModel.streamingText)
                }
            } else {
                streamSource.finish()
                streamSource = WOChatStreamSource()
            }
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
    /// 批15c：命中强化——真机证据（批15b 日志：4 条锚点、0 条钮点击）证明
    /// 点击从未到达 Button 的 action；改 gesture 实现绕开 Button 机制，命中
    /// 区扩大到钮外扩 44×44+整行右半段 contentShape，点击必有 toast 直显。
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
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(WOAlias.labelPrimary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(WOAlias.bgLayer3))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
                    .frame(width: 44, height: 44) // 批15c：命中区外扩
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 批15c：gesture 实现绕开 Button 机制（Button action
                        // 在真机上从未触达——批15b 日志 0 条钮点击实证）。
                        onToggle()
                    }
                    .accessibilityLabel("展开或收起工作区侧栏")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        // 批15c：整行右半段也可点（标题之后的所有区域）——命中区最大化。
        .contentShape(Rectangle())
        .onTapGesture { location in
            // 点在标题文字左侧（状态点/空区）不触发；右半段任意位置触发。
            // location.x > 120 粗判：避开标题区误触，右半段全为开关命中区。
            if location.x > 120, let onToggle = onToggleRightSidebar {
                onToggle()
            }
        }
        .onAppear {
            // 批15c：顶栏渲染留痕（配合钮点击日志，分辨"没渲染"vs"没命中"）。
            RightRailDiag.event("顶栏渲染 sessionId=\(sessionId) hasToggle=\(onToggleRightSidebar != nil)")
        }
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
            .onChange(of: viewModel.streamingText) { newValue in
                // 批12 T7：流式正文全文快照喂给 StreamedMarkdownView（每次
                // yield 全文累积快照语义）；空值不 emit——emit 空串会清空渲染。
                if !newValue.isEmpty {
                    streamSource.emit(newValue)
                }
                follow(proxy)
            }
            .onChange(of: viewModel.streamingReasoning) { _ in follow(proxy) }
        }
    }

    /// 批C4：跟随判定——探针可见（用户在底部附近）才随内容变化滚底。
    /// 批12：scrollTo 禁动画（Transaction(animation: nil)）——滚动跟随=dsh
    /// follow-end 即时贴底语义；默认隐式动画在高频流式刷新下呈"滑动感"、
    /// 回合收尾时呈"动一下"（用户 2026-09-23 反馈），全部根治。
    private func follow(_ proxy: ScrollViewProxy) {
        guard autoFollow else { return }
        let transaction = Transaction(animation: nil)
        withTransaction(transaction) {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
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
            // 批12 T7：正文换 MarkdownView（SwiftStreamingMarkdown——标题/
            // 列表/代码块/表格可渲染；字色库默认跟随系统 primary，字号一期
            // default 不折腾）。库自带 textSelection 配置——外层 .textSelection
            // 去掉避免双选区行为。
            HStack(alignment: .top, spacing: 8) {
                WOAssistantAvatar()
                MarkdownView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - 流式块（批12 T5/T7：思考段并入 ReasoningDisclosure running 形态
    // ——图标+扫光+尾行右对齐跟随；正文段=StreamedMarkdownView）

    private var streamingBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.streamingReasoning.isEmpty {
                // 批12 T5：running 态思考行（与 settled 同一行件——summary=尾行
                // 右对齐跟随 + 行上扫光；expanded 初值恒 false 不自动展开）。
                ReasoningDisclosure(text: viewModel.streamingReasoning, running: true)
            }
            if !viewModel.streamingText.isEmpty {
                // 批12 T7：流式正文换 StreamedMarkdownView（库自带流式动画语义；
                // 光标 ▍ 不再手画，保持干净）。
                StreamedMarkdownView(source: streamSource)
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

/// 批12 T7：流式 Markdown 桥接源（SwiftStreamingMarkdown StreamedMarkdownSource
/// 语义——每次 yield 全文累积快照；ObservableObject 供 StreamedMarkdownView
/// 订阅并在内部 .task 消费）。AsyncStream 默认 unbounded 缓冲：视图挂载前的
/// yield 不丢。WOChatView 持 @State 实例；离开 .streaming 即 finish 并重建。
private final class WOChatStreamSource: ObservableObject, StreamedMarkdownSource {
    /// AsyncStream<String>（StreamedMarkdownSource 协议要求——每次产出全文快照）。
    let text: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var c: AsyncStream<String>.Continuation!
        self.text = AsyncStream { c = $0 }
        self.continuation = c!
    }

    /// 追加一次全文累积快照（调用方保证非空——emit 空串会清空渲染）。
    func emit(_ snapshot: String) { continuation.yield(snapshot) }

    /// 本回合结束（StreamedMarkdownView 收尾；之后由宿主重建实例供下回合）。
    func finish() { continuation.finish() }
}

// MARK: - 批12 T5：dsh DisclosureRow 共用行件 + IconThinkOutline14
//
//  规格=ui-chat/ReasoningRow.tsx + module.css + ui-primitives/DisclosureRow
//  （主理人逐文件核证真值）：收起/展开是同一个 24px 行组件——
//    [16×16 leading 盒（内 14px 图标）] gap6 [title 13/24/400] [2×2 分隔点
//    margin 0 8] [summary 13 单行省略]；展开时 leading 换 chevron.down；
//    summary 空时分隔点一起消失；sweepActive 时整行叠 WOSweepModifier（2.6s）。
//  注：为供 WOToolCards.swift（T6 工具行）复用，本件为文件级 internal——
//  简报所写「private」跨文件不可见，按复用语义放宽（登记报告）。

/// dsh DisclosureRow 行件（思考行 settled/running 与工具行共用；展开体由
/// 调用方以 content 闭包给出，展开时渲染于行下）。
/// 扩展（简报 init 签名之外的必有缝，均带默认值不改调用形）：
///   titleColor——T6 工具行 title=labelPrimary（默认 labelSecondary=思考行）；
///   summaryColor——T6 错误摘要=stateErrorPrimary（默认 labelTertiary）。
struct WODisclosureRow<Icon: View, Content: View>: View {
    private let icon: Icon
    private let title: String
    @Binding private var expanded: Bool
    private let summary: String
    private let summaryFollowEnd: Bool
    private let sweepActive: Bool
    private let titleColor: Color
    private let summaryColor: Color
    private let content: Content

    init(icon: Icon,
         title: String,
         expanded: Binding<Bool>,
         summary: String,
         summaryFollowEnd: Bool = false,
         sweepActive: Bool = false,
         titleColor: Color = WOAlias.labelSecondary,
         summaryColor: Color = WOAlias.labelTertiary,
         @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self._expanded = expanded
        self.summary = summary
        self.summaryFollowEnd = summaryFollowEnd
        self.sweepActive = sweepActive
        self.titleColor = titleColor
        self.summaryColor = summaryColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // 批12：披露展开 .32s（dsh grid-template-rows 0fr↔1fr .32s；
                // WOMotion bezier 域，思考披露同族曲线）。
                withAnimation(WOMotion.bezier(duration: 0.32)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    // 16×16 leading 盒：收起=调用方图标（14px），展开=chevron.down。
                    Group {
                        if expanded {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(WOAlias.labelSecondary)
                        } else {
                            icon
                        }
                    }
                    .frame(width: 16, height: 16)
                    Text(title)
                        .font(.system(size: 13)) // weight 400
                        .foregroundColor(titleColor)
                        .lineLimit(1)
                    if !summary.isEmpty {
                        if summaryFollowEnd {
                            // dsh running 态：summary 右对齐 flex-end 跟随。
                            Spacer(minLength: 0)
                        }
                        // 2×2 分隔点（labelCaption；dsh margin: 0 8px——外加
                        // HStack gap6 两侧各 6，间距=14 与 CSS gap+margin 一致）。
                        Circle()
                            .fill(WOAlias.labelCaption)
                            .frame(width: 2, height: 2)
                            .padding(.horizontal, 8)
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundColor(summaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !summaryFollowEnd {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(minHeight: 24) // dsh 行高 24px
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content
                    // 批12：展开体过渡 = opacity + 垂直微量位移 8pt（.32s 同族）。
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WOSweepModifier(active: sweepActive))
    }
}

/// 批12 T5：IconThinkOutline14（dsh 原值 1:1 移植——两段 path，viewBox 14×14；
/// path1 中心点单 fill，path2 四瓣花形自交叠 evenodd fill；渲染走 WOBrand.swift
/// 既有 PathGenerator M/L/C/Z 解析器，坐标已是 viewBox 单位 1:1 不缩放）。
private struct WOThinkIcon: View {
    static let viewBox = CGSize(width: 14, height: 14)
    /// dsh IconThinkOutline14 path1（中心点，单 fill）原值照录。
    static let path1 =
        "M7.06431 5.93342C7.68763 5.93342 8.19307 6.43904 8.19322 7.06233" +
        "C8.19322 7.68573 7.68772 8.19123 7.06431 8.19123C6.44099 8.19113 " +
        "5.9354 7.68567 5.9354 7.06233C5.93555 6.43911 6.44108 5.93353 " +
        "7.06431 5.93342Z"
    /// dsh IconThinkOutline14 path2（四瓣花形，evenodd）原值照录。
    static let path2 =
        "M8.6815 0.963693C10.1169 0.447019 11.6266 0.374829 12.5633 1.31135" +
        "C13.5 2.24805 13.4277 3.75776 12.911 5.19319C12.7126 5.74431 " +
        "12.4386 6.31796 12.0965 6.89729C12.4969 7.54638 12.8141 8.19018 " +
        "13.036 8.80647C13.5527 10.2419 13.6251 11.7516 12.6883 12.6883" +
        "C11.7516 13.625 10.242 13.5527 8.8065 13.036C8.19022 12.8141 " +
        "7.54641 12.4969 6.89732 12.0965C6.31797 12.4386 5.74435 12.7125 " +
        "5.19322 12.911C3.75777 13.4276 2.2481 13.5 1.31138 12.5633" +
        "C0.374859 11.6266 0.447049 10.1168 0.963724 8.68147C1.17185 8.10338 " +
        "1.46321 7.50063 1.82896 6.8924C1.52182 6.35711 1.27235 5.82825 " +
        "1.08872 5.31819C0.572068 3.88278 0.499714 2.37306 1.43638 1.43635" +
        "C2.37308 0.499655 3.8828 0.572044 5.31822 1.08869C5.82828 1.27232 " +
        "6.35715 1.5218 6.89243 1.82893C7.50066 1.46318 8.10341 1.17181 " +
        "8.6815 0.963693ZM11.3573 8.01154C10.9083 8.62253 10.3901 9.22873 " +
        "9.80943 9.8094C9.22877 10.3901 8.62255 10.9083 8.01158 11.3572" +
        "C8.4257 11.5841 8.8287 11.7688 9.21275 11.9071C10.5456 12.3868 " +
        "11.4246 12.2547 11.8397 11.8397C12.2548 11.4246 12.3869 10.5456 " +
        "11.9071 9.21272C11.7688 8.82866 11.5841 8.42568 11.3573 8.01154Z" +
        "M2.56529 8.02912C2.37344 8.39322 2.21495 8.74796 2.09263 9.08772" +
        "C1.61291 10.4204 1.74512 11.2995 2.16001 11.7147C2.57505 12.1297 " +
        "3.45415 12.2618 4.78697 11.7821C5.11057 11.6656 5.44786 11.5164 " +
        "5.7938 11.3367C5.249 10.9223 4.70922 10.4533 4.19029 9.9344" +
        "C3.57578 9.31987 3.03169 8.67633 2.56529 8.02912ZM6.90708 3.2469" +
        "C6.24065 3.70479 5.5646 4.26321 4.91392 4.91389C4.26325 5.56456 " +
        "3.70482 6.24063 3.24693 6.90705C3.72674 7.63325 4.32777 8.37459 " +
        "5.03892 9.08576C5.64943 9.69627 6.28183 10.2265 6.90806 10.6678" +
        "C7.59368 10.2025 8.2908 9.63076 8.96079 8.96076C9.6308 8.29075 " +
        "10.2025 7.59366 10.6678 6.90803C10.2265 6.2818 9.69631 5.6494 " +
        "9.08579 5.03889C8.37462 4.32773 7.63328 3.72672 6.90708 3.2469Z" +
        "M11.7147 2.15998C11.2996 1.74509 10.4204 1.61288 9.08775 2.0926" +
        "C8.74835 2.21479 8.39382 2.37271 8.03013 2.56428C8.67728 3.03065 " +
        "9.31995 3.5758 9.93443 4.19026C10.4534 4.7092 10.9223 5.24896 " +
        "11.3368 5.79377C11.5164 5.44785 11.6656 5.11052 11.7821 4.78694" +
        "C12.2618 3.45416 12.1297 2.57502 11.7147 2.15998ZM4.91197 2.2176" +
        "C3.57922 1.73788 2.70004 1.86995 2.28501 2.28498C1.87001 2.70003 " +
        "1.73791 3.5792 2.21763 4.91194C2.31709 5.18822 2.44112 5.47427 " +
        "2.58677 5.7674C3.01931 5.1887 3.51474 4.6158 4.06529 4.06526" +
        "C4.61584 3.5147 5.18872 3.01928 5.76743 2.58674C5.47431 2.4411 " +
        "5.18824 2.31706 4.91197 2.2176Z"

    var body: some View {
        ZStack {
            Path { p in
                p.addPath(PathGenerator.path(from: Self.path1, scaledTo: Self.viewBox))
            }
            .fill(WOAlias.labelTertiary)
            Path { p in
                p.addPath(PathGenerator.path(from: Self.path2, scaledTo: Self.viewBox))
            }
            // path2 自交叠：奇偶填充（dsh fill-rule 原语义——FillStyle(eoFill: true)）。
            .fill(WOAlias.labelTertiary, style: FillStyle(eoFill: true))
        }
        .frame(width: 14, height: 14)
    }
}

/// 思考披露（批12 T5 dsh ReasoningRow 化——收起/展开同一行件 WODisclosureRow；
/// running 态仅 summary 来源不同 + 行上扫光；expanded 初值恒 false，running
/// 也不自动展开）。settled：summary=首行（firstLine）；running：尾行（latestLine，
/// 右对齐 flex-end 跟随）+ 扫光。展开体=全文（thinkBody 13px labelTertiary）。
private struct ReasoningDisclosure: View {
    let text: String
    /// running：流式在途（summary=尾行跟随 + 扫光）；默认 settled。
    var running: Bool = false

    @State private var expanded = false

    /// settled summary：首行（dsh firstLine 语义）。
    private var firstLine: String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    /// running summary：尾行（dsh latestLine 语义——去首尾空白后取最后一段）。
    private var latestLine: String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
            .split(separator: "\n").last.map(String.init) ?? ""
    }

    var body: some View {
        WODisclosureRow(icon: WOThinkIcon(), title: "思考",
                        expanded: $expanded,
                        summary: expanded ? "" : (running ? latestLine : firstLine),
                        summaryFollowEnd: running,
                        sweepActive: running) {
            // thinkBody：padding 4/0/4/22，13px/20px 行高（lineSpacing 2），
            // labelTertiary，pre-wrap 语义（digest-H .think 正文左缩进 22px）。
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelTertiary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 4)
                .padding(.leading, 22)
        }
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
