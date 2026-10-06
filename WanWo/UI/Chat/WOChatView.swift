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
// 流式渲染官方化（2026-10-04）：Markdown 渲染（SwiftStreamingMarkdown v0.7.0）
// 落盘正文与直播正文（live 槽）用**同一个** MarkdownView(text:)（换手帧前后
// 同一组件类型；库内 .task(id: text) 块级 diff 原地更新，33Hz text 变化不重建
// 视图）。原 StreamedMarkdownView 流桥退役。
// 【重做批 2】渲染链（MarkdownView/chatMarkdownConfig/autolink 等）已迁至
// WanWo/UI/Chat/List/WONodeContent.swift——本文件不再直接使用该库，import
// 随迁（同 target 库面不变）。

struct WOChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var appState: WOAppState
    /// 批12+归挡（2026-09-27）：offload askOnce 审批卡（composer 座位接管
    /// 第三顺位；App 级单例呈现宿主——offload 审批可来自任意会话内核分发点）。
    @ObservedObject private var offloadPresenter = OffloadApprovalPresenter.shared
    /// 批12+右栏批2（2026-09-27）：下载确认呈现宿主（BrowserDownloadAsker
    /// 单例缝不动；呈现端从浏览器页签 sheet 迁移至 composer 座位第四顺位）。
    @ObservedObject private var downloadAsker = BrowserDownloadAsker.shared
    /// 批12+联动B：轻提示状态（AI 自主干活时 dock 位胶囊；openSidebar 场景
    /// 不进此态——直接展开右栏落点）。
    @State private var agentHint: AgentHint?
    /// 同域 10s 节流（AI 连续多页不刷屏）。
    @State private var lastHintTimes: [String: Date] = [:]
    struct AgentHint: Equatable { let url: URL; let domain: String }
    private let sessionId: String

    /// 批C1：顶栏右栏开关回调（workspaceSidebar 真值在 WORootFrame，闭包下发；
    /// nil = 宿主未接（测试/直注实例）→ 顶栏不出开关钮）。
    var onToggleRightSidebar: (() -> Void)? = nil
    /// 批12+联动B：轻提示点击回调（展开右栏+AI 页签落点；真值在 WORootFrame）。
    var onOpenAgentBrowser: ((URL) -> Void)? = nil

    /// 批C4：顶栏丝线判定（原型 .main-head.scrolled：scrollTop>4）。
    /// 【重做批4】丝线真值源迁引擎 core（scrollViewDidScroll 判定经
    /// onHeadScrolled 回调直写；autoFollow/hasReachedTail/viewportGlobalFrame/
    /// bottomAnchor/animatedIDs/entrySeeded/pendingUserSeen 等旧列表状态随
    /// ScrollView+LazyVStack 容器退役——等价机制见 messageList 头注）。
    @State private var headScrolled = false
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
    // 【重做批4】用户消息哨兵交接旗（pendingUserSeen）随旧列表退役——
    // 引擎 ledger.pendingUserSeen 接管（WONodeBubbleView.onSeen → markSeen）。
    // 流式渲染官方化（2026-10-04）：原 View 层流式状态（streamSource 流桥 /
    // isSettling 补打期 / liveTailSeen 动画门 / typeTarget+typeCursor 打字机）
    // 全部迁入 ChatViewModel 数据面（liveReasoning/liveText/isSettling/
    // settledBubbleIDs/typeTarget/typeCursor/typewriterTask）——dsh assistant
    // -step 零换手语义：直播槽与落盘节点同处一条节点流（viewModel.displayNodes），
    // View 层不再持有换手状态机。

    /// hero 附件交接消费标记（init 只读判定；消费在 onAppear 安全期执行——
    /// struct init 运行于父 body 求值中，彼时写 ObservableObject 属
    /// "Modifying state during view update" 违例）。
    private let consumesPendingImages: Bool
    /// hero 一步发送旗（onAppear 摘旗；引擎装配完成（.idle）即自动提交首条）。
    @State private var autoSubmitArmed = false

    init(environment: AppEnvironment, sessionId: String,
         onToggleRightSidebar: (() -> Void)? = nil,
         onOpenAgentBrowser: ((URL) -> Void)? = nil) {
        self.sessionId = sessionId
        self.onToggleRightSidebar = onToggleRightSidebar
        self.onOpenAgentBrowser = onOpenAgentBrowser
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
        self.onOpenAgentBrowser = nil
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
            && viewModel.liveText == nil
            && viewModel.liveReasoning == nil
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
            // 批12+回归二校（2026-09-24 用户令）：dock 下方底部渐变衬罩——
            // 范围 = dock 卡底缘 → 屏幕物理底边；上缘透明度 100%（全透）→
            // 下缘 0%（实色 bgBase），与标题栏镜像同款（内容滚到屏幕底缘处
            // 被淡出遮住）。首版方向做反（上实下透）已按用户截图判废。
            // ignoresSafeArea 保证贴到物理底边；命中关闭；hero 态不渲染。
            if !heroMode {
                LinearGradient(colors: [.clear, WOAlias.bgBase],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .bottom)
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
                // 批12+联动B（2026-09-27 用户令+参考件动画）：轻提示胶囊——
                // AI 自主干活时 dock 上方一行（不展开不弹卡不打断输入）；
                // 点击=展开右栏+AI 页签落点。回调真值在 WORootFrame。
                // 件 I 宿主接线：todo 状态卡（dsh TodoPanel dock 常驻语义
                // "empty renders nothing"——当前计划非历史消息，座位组最上；
                // goal 卡挂载另行评估，本件只挂 todo）。
                // 【M7-Fix2 批2 B2 2026-09-29】挂载条件内收：出现/消失动画
                // 按原型逐值重做后需要「数据已清空仍在树」的退场缓冲帧——
                // 卡片自管 presented 生命周期（空态自渲染，见 WOStateCards）。
                // 【批3 A2】GoalBar 挂载（dsh GoalDock composer dock 语义，
                // 快照=viewModel.goalView，动作接 GoalService CAS——见
                // WOGoalBar 头注逐项对拍）。淡入淡出 cubic-bezier(.22,1,.36,1)；
                // reduceMotion 静态直出。
                // 【M7-Fix2 批6 F1 2026-10-02 用户令（IMG_2545 实证）】todo 卡
                // 与 GoalBar 挂载顺序对调：todo 在上、GoalBar 在下（紧邻
                // composerSeat）。底部锚定堆栈中 GoalBar 位置恒定不随 todo
                // 出现/展开/消失上下漂移（原序 todo 卡把 GoalBar 顶上去）；
                // todo 生命周期向上生长。GoalBar 淡入淡出（批4 setGoalView
                // withAnimation）与 todo presented 生命周期（WOStateCards）互
                // 不受位置影响——二者各自独立条件挂载，修饰符跟各自行走。
                WOTodoChecklistCard(todos: viewModel.todoItems)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, heroMode ? 0 : 14)
                WOGoalBar(
                    goal: viewModel.goalView,
                    onPause: { await viewModel.pauseGoal() },
                    onResume: { await viewModel.resumeGoal() },
                    onEdit: { await viewModel.editGoalObjective($0) },
                    onClear: { await viewModel.clearGoal() })
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, heroMode ? 0 : 14)
                if let hint = agentHint {
                    WOAgentHintPill(title: "AI 正在浏览", domain: hint.domain)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenAgentBrowser?(hint.url) }
                        .transition(.opacity)
                }
                composerSeat
                    .background(composerChromeMeter)
                    // 批12+右栏重构批1：轻提示数据源换 store.agentNavigation
                    //（通知旁路退役；AI 自主干活不展开右栏时此处呈现，同域
                    // 10s 节流；openSidebar=true 由 store 直接展开右栏落点，
                    // 不进此态——openSidebar 时 agentBrowserTab 语义已激活，
                    // 节流字段仍记录防双显）。
                    .onReceive(WOWorkspaceStore.shared.$agentNavigation) { navigation in
                        guard let navigation else { return }
                        let domain = navigation.domain
                        let now = Date()
                        if let last = lastHintTimes[domain],
                           now.timeIntervalSince(last) < 10 { return }
                        lastHintTimes[domain] = now
                        withAnimation(.easeInOut(duration: 0.2)) {
                            agentHint = AgentHint(url: navigation.url, domain: domain)
                        }
                    }
                // 批10：composer 上方悬浮渐隐罩退役（2026-09-22 真机反馈"渐变
                // 太奇怪、就做一小块"——620 宽 36pt 罩在卡上缘呈灰斑；用户令
                // 删除不再做渐变。内容贴卡上缘自然裁切，滚动跟随由 autoFollow
                // 闸门+列表底部 padding 保证）。
                // StatsLine dock 恒渲染（用户既定裁定；hero 相同样在位）。
                // 批12+回归（2026-09-24 用户令，批13 T3② 同款复刻）：统计行限宽
                // 620 与 composer 卡同轴——对称轴同一条竖线（文字居中见
                // WOStatsDock 二校；渐变衬罩已迁至 ZStack 底层，见 messageList 后）。
                WOStatsDock(line: viewModel.statsLine)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
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
            } else if mentionMenuOpen {
                // 【批2 F075】@ 引用菜单（同锚位；与 slash 行首 `/` 天然互斥）。
                mentionMenu
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
            // 【批2 F075】@ token 变化 → 刷新候选（cc-haha session 搜索 150ms
            // 防抖同义；此处同步算，枚举为一层目录、开销可控）。
            if mentionMenuOpen, let range = mentionTokenRange {
                mentionCandidates = viewModel.mentionCandidates(
                    query: String(text[range]))
            }
        }
        // 【批3 右栏→AI 引用挂载】文件页签/树行「引用」→ composer 追加 @path
        // （store 通道；消费后清位，at 防同 token 重复）。
        .onReceive(WOWorkspaceStore.shared.$pendingComposerInsert) { insert in
            guard let insert, insert.sessionID == sessionId,
                  insert.at != lastConsumedInsert else { return }
            lastConsumedInsert = insert.at
            WOWorkspaceStore.shared.pendingComposerInsert = nil
            var draft = viewModel.draft
            if !draft.isEmpty && !draft.hasSuffix("\n") && !draft.hasSuffix(" ") {
                draft += " "
            }
            viewModel.draft = draft + insert.token + " "
            slashDismissed = true
        }
        .background(WOAlias.bgBase)
        .onAppear {
            viewModel.open()
            // 【重做批4】seedEntry() 随旧列表退役——入场种子由引擎
            // seedLedgerIfNeeded 接管（sync 相位边界补种，语义等价）。
            // F075：切回会话恢复草稿若带 @ token，菜单候选立即就位。
            if mentionMenuOpen, let range = mentionTokenRange {
                mentionCandidates = viewModel.mentionCandidates(
                    query: String(viewModel.draft[range]))
            }
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
            // 【重做批4】seedEntry()/回合边界补种随旧列表退役——引擎
            // seedLedgerIfNeeded 接管（相位变化落到非 .streaming 时
            // seedAll，turnUsage/纸条等回合尾新增节点即时呈现语义等价）。
            // 批12+联动B：回合结束 → 轻提示胶囊淡出（浏览过程结束即消失）。
            if phase != .streaming { agentHint = nil }
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
    /// done 绿）+ 会话标题 14pt/500；标题右侧=子代理 count 徽章（【M7-Fix2
    /// 批2 B1】dsh SubagentHeaderLineage variant 'count'——有子女证据才渲染，
    /// 空目录零占位；点开=目录树下拉，行点击→子会话只读回放 sheet）；
    /// 右=右栏开关钮（规格=退役的 reopenSidebarButton：32pt r9 玻璃白
    /// .9+blur；本批两处悬浮双钮已删，本钮是唯一入口）。
    private var conversationHead: some View {
        HStack(spacing: 8) {
            WOStateDot(state: viewModel.phase == .streaming ? .ongoing : .done,
                       size: 6)
                .frame(width: 10, height: 10) // ongoing 像素环按 10 网格绘制
            Text(sessionTitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(WOAlias.labelPrimary)
                .lineLimit(1)
            // 【M7-Fix2 批2 B1】子代理徽章挂标题右侧（用户截图 IMG_2515
            // 对位：标题左，右侧现有按钮组不动）。hero 态不渲染本头。
            WOSubagentLineageBadge(environment: environment, sessionId: sessionId)
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
        } else if let offloadRequest = offloadPresenter.pendingRequest {
            // 批12+归挡：offload askOnce 卡（composer 座位接管第三顺位，
            // WOApprovalCard 同款骨架——用户指名对齐现有"盖在 dock 上层"样式）。
            WOOffloadPermissionCard(request: offloadRequest)
        } else if let downloadRequest = downloadAsker.frontmost {
            // 批12+右栏批2（2026-09-27 用户令）：下载确认卡 = composer 座位
            // 接管第四顺位（原浏览器页签 sheet 半屏形态退役；BrowserDownload
            // Asker 单例缝/队列/fail closed 语义不动，只挪呈现端）。
            WODownloadAskCard(asker: downloadAsker, request: downloadRequest)
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

    /// 【批2 F075】@ 引用菜单开启判定：draft 尾部存在 `@` 起始 token（@ 后
    /// 允许部分路径）；与 slash（行首 `/`）天然互斥。cc-haha ComposerReference
    /// 触发语义。
    private var mentionMenuOpen: Bool {
        guard !slashDismissed else { return false }
        guard viewModel.pendingApprovals.isEmpty,
              viewModel.pendingQuestions.isEmpty else { return false }
        switch viewModel.phase {
        case .idle, .failed: break
        default: return false
        }
        return mentionTokenRange != nil
    }

    /// draft 尾部 @ token 范围（`@` 起、至尾/首个空白止——F040 令牌语法同款）。
    private var mentionTokenRange: Range<String.Index>? {
        let draft = viewModel.draft
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let after = draft.index(after: at)
        // @ 后首个字符若为空白 → 仅 @ 触发（列根层），token 到此为止。
        if after < draft.endIndex,
           draft[after].isWhitespace || draft[after].isNewline { return nil }
        // token 内不得含空白（空白=token 已结束，不再拉菜单）。
        for ch in draft[after...] where ch.isWhitespace || ch.isNewline { return nil }
        return at..<draft.endIndex
    }

    private var mentionQuery: String {
        guard let range = mentionTokenRange else { return "@" }
        return String(viewModel.draft[range])
    }

    @State private var mentionCandidates: [String] = []
    /// 已消费的 composer 插入请求时间戳（防同 token 重复追加）。
    @State private var lastConsumedInsert: Date?

    private var mentionMenu: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            WOMentionMenu(
                candidates: mentionCandidates,
                onPick: { path in
                    // 选中：@token 替换为完整 `@path`（带尾随空格封 token；
                    // 目录选择=继续浏览——不带空格，菜单跟随下一段）。
                    guard let range = mentionTokenRange else { return }
                    slashDismissed = true
                    let isDirectory = path.hasSuffix("/")
                    viewModel.draft.replaceSubrange(
                        range, with: isDirectory ? path : "@\(path) ")
                })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, composerChromeHeight + 6)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .zIndex(2)
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

    /// 【重做批4 · 容器切换】消息列表 = UIKit 引擎（WOMessageListView，
    /// UIViewControllerRepresentable 承载 WOMessageListCore）。旧
    /// ScrollView+LazyVStack 全家退役（探针/跟随闸门/滚动锚点/入场门/
    /// onChange 跟随链），等价机制由引擎内建承接：
    ///   · 跟随 = followsBottom 状态机（拖拽即断/距底 1pt 恢复/回底钮）
    ///     + CADisplayLink 指数收敛贴底（lody advanceMotion 同构）；
    ///   · 顶栏丝线 = onHeadScrolled(Bool)（core scrollViewDidScroll
    ///     scrollTop>4 判定，原探针链迁引擎）；
    ///   · 历史分页 = 顶部预取 offset<240 + 4ms 预算切片 + 锚定恢复
    ///     + 滚动停止门（重做批 3 R1）；
    ///   · loading/beam/failed 元条目 = 引擎 flatten 合成（Support 件 1）；
    ///   · 入场动画 = 引擎 ledger 账本驱动（WONodeBubbleView.entryBubble，
    ///     fadeUp/mInL/mInR/instantLive/哨兵交接全套语义保真）。
    /// 四老 bug 复测点（收尾白屏/上滑拽回/dock 跳动/空白重渲染）见
    /// analysis/chat-rework-plan-20261006.md 批 4。
    private var messageList: some View {
        WOMessageListView(
            viewModel: viewModel,
            nodes: viewModel.displayNodes,
            phase: viewModel.phase,
            sessionId: sessionId,
            // 批 2 件 3：composer 座位组超出旧链基准（137）的动态让位增量
            // （旧链静态 189 由 sectionInset 承担，两者分立）。
            bottomAllowance: max(0, composerChromeHeight
                - WOMessageListSupport.dockBaselineHeight),
            onBackgroundTap: {
                // 菜单开着时点消息区 = 区外关闭（dsh MenuView
                // outside-click 语义的触屏形；原 messageList 内
                // onTapGesture 迁出）。
                if slashMenuOpen || mentionMenuOpen { slashDismissed = true }
            },
            onHeadScrolled: { scrolled in
                // 批C4 顶栏丝线（原探针链迁 core scrollViewDidScroll）。
                if headScrolled != scrolled { headScrolled = scrolled }
            },
            onImagePreview: { messagePreview = $0 })
    }

    // 流式渲染官方化（2026-10-04）：原 liveTail 占位节点 / typewriterLoop
    // 打字机节奏器 / lastAssistantBubbleID / isSettlingAssistant /
    // hasPostSettlingStepNode 全部拆除——
    //  · 直播段落以正式 Bubble（live-r-N / live-t-N 代际 id）经
    //    viewModel.displayNodes 进统一 ForEach，与落盘节点同构渲染；
    //  · 打字机节奏器（33Hz，步长 max(1,min(4,backlog/3))，长积压快进）迁
    //    ChatViewModel.typewriterStep（open 启动 / close 取消）；
    //  · 补打目标过滤 / settle 决策 / 回合步进判定（P1-2）迁 VM 数据面纯函数。
    // 【重做批4 · 容器切换】旧 ScrollView+LazyVStack 机制全家（探针键×3/
    // follow/updateAutoFollow/updateHeadScrolled/seedEntry/entryNode/
    // entryBubble/nodeContext/autoFollow 等状态）随容器退役——等价机制由
    // 引擎内建承接（见 messageList 头注清单）；入场动画迁 WONodeBubbleView
    // （ledger 驱动，WOEntryModifier 语义零位移）。

}

/// composer chrome 高度 PreferenceKey（slash 菜单锚定；旧 ChatView 同法）。
private struct WOComposerChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// 【重做批4】批C4 滚动探针键三件（WOChatTailProbeKey/WOChatTopProbeKey/
// WOChatViewportKey）随 ScrollView+LazyVStack 容器退役——丝线/跟随判定
// 迁引擎 core（scrollViewDidScroll 内建）。

// 流式渲染官方化（2026-10-04）：原 WOChatStreamSource 流桥（批12 T7 可重启
// 管道 + 批12+回归九校-B/C 终身单例修复链）整体退役——直播正文改用与落盘正文
// 同一个 MarkdownView(text:)（库内 .task(id: text) 块级 diff 原地更新），VM 层
// liveText 槽 33Hz 直供文本，不再需要 AsyncStream 桥接与控制器生命周期管理。

/// 批12+回归七校：入场决策诊断（首次工具调用双重动画/消息连带动画定位）。
/// 仅未 seen 节点落一行（转拆级频率，非 body 热路径——已 seen 节点静默）；
/// 1s 同文节流 + 512KB 截半守护；文件 Documents/entry-diag.log（文件 App
/// 直接可见可分享），AppLogger 同步一份。internal=WOEntryModifier 亦调用。
enum WOEntryDiag {
    static let logger = AppLogger(category: "EntryDiag")
    private static let queue = DispatchQueue(label: "com.wanwo.entry-diag")
    private static var lastMessage = ""
    private static var lastTime = Date.distantPast

    static func event(_ message: String) {
        let now = Date()
        if message == lastMessage, now.timeIntervalSince(lastTime) < 1.0 { return }
        lastMessage = message
        lastTime = now
        logger.info(message)
        let line = "\(ISO8601DateFormatter().string(from: now)) | \(message)\n"
        queue.async {
            let url = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent("entry-diag.log")
            let fm = FileManager.default
            guard let data = line.data(using: .utf8) else { return }
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > 256 * 1024 {
                    try? handle.truncate(atOffset: size / 2)
                    _ = try? handle.seek(toOffset: size / 2)
                }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - 批12 T5：dsh DisclosureRow 行件族（重做批 2 迁至
// WanWo/UI/Chat/List/WONodeContent.swift——渲染链随装配缝搬家，引用面不变；
// WOToolCards.swift 跨文件引用语义不变）。

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
                    // 批12+回归九校-C：单行行高规格 24（同 WOComposer——空态
                    // placeholder 与单行输入等高，iOS16 lineSpacing 只作用
                    // placeholder 的实测差根治）。
                    .frame(minHeight: 24, alignment: .topLeading)
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
