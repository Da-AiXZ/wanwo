//
//  ChatViewModel.swift
//  WanWo
//
//  【按设计新写 · M2 重写】出处：10-design §2.1（UI 不持业务状态，只消费投影）、
//  §7.3 交互流 1（发送→流式→工具卡流式输出→完成态卡片收敛→下一轮，顶部状态条
//  实时显示 token 压力 F041）、§5.2（SessionLifecycle resume）。
//  M1 → M2 变化：
//    · 回合驱动从 ChatTurnRunner 切到 AgentLoop（submit/cancel/回调三缝）
//    · 工具卡：tool/call → running 卡（presentCall 意图 + onShellLine 流式）→
//      tool/result 收敛（presentResult 意图 + 结果文本）
//    · 斜杠命令（/compact /new /model /help）：command/run + command/done 落盘
//    · 标记消息过滤：<runtime-context> / <agents-md-update> / <compaction-summary>
//      / <file> 开头的 user 消息不渲染气泡（注入通道，F038/F039/F040）
//    · token 压力三档显示（F041 素净版）
//  UI 投影 = 会话事件流的只读视图；0.2s 节流 flush 沿用 M1 模式。
//  M3 E2（live/replay 统一投影）：
//    · 气泡/工具卡类型与事件→气泡折叠下沉到 ConversationProjector（唯一规则；
//      dsh assembler 语义：live append 与 replay replaceWindow 同一 matchInput，
//      节点位置=起始事件 seq），live 不再按到达序自行追加工具卡
//    · toolCallStarted 即重投影（此刻 assistant/message + tool/call 已落盘），
//      流式缓冲=刚提交消息 → 由事件流渲染并清空（思考/回复按块分立）
//    · shell 行进 0.2s 节流缓冲（§7.3 shell 卡 0.2s 节流；与文本 chunk 同钟）
//    · 工具卡 id 锚定 callId、气泡 id 锚定 seq+块下标——重投影身份稳定
//    · live 流式输出环形窗口封顶（长文本渲染优化）
//

import Foundation
import SwiftUI
import UIKit
import Collections

@MainActor
final class ChatViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case idle
        case streaming
        case failed(String)
    }

    // MARK: E2：气泡/工具卡类型下沉到 ConversationProjector（live/replay 共用
    // 折叠的产物类型）；旧嵌套名以 typealias 保稳（ChatView 等引用不变）。
    typealias ToolCard = ConversationProjector.ToolCard
    typealias Bubble = ConversationProjector.Bubble

    @Published private(set) var bubbles: [Bubble] = []
    /// 当前计划卡数据源（dsh todo/write "Log-only UI state" 的 dock 常驻
    /// 语义——整表替换，非历史消息；空=不渲染。件 I 宿主接线补挂载）。
    @Published private(set) var todoItems: [TodoItem] = []
    /// 【批3 A2】GoalBar 数据源（GoalFold.foldGoal 事件流快照；goal/change
    /// 落盘即失效、随 reproject/onToolCallFinished 重 fold——与 todoItems
    /// 同一 log-only 独立槽纪律，不进 Bubble 流）。nil = 无 goal（条消失）。
    @Published private(set) var goalView: GoalView?
    @Published private(set) var streamingText = ""
    @Published private(set) var streamingReasoning = ""
    @Published private(set) var phase: Phase = .loading
    /// 批12+回归九校-B：回合刚从流式态结束（onTurnEnd 置位 1.5s 后自清）——
    /// onTurnEnd 里 reproject 与 phase=.idle 同帧，视图渲染时 phase 已非
    /// .streaming，"刚在直播看过不重播动画"（instantLive）判定失效=收尾帧
    /// 落盘思考节点多播一次 fadeUp（用户实测）；此旗让视图跨帧拿到该语义。
    @Published private(set) var justEndedStreaming = false
    // MARK: 流式渲染官方化（2026-10-04）：dsh assistant-step 零换手语义的万我形态
    //  语义源 repos/deepseek-harness-master packages/client/ui-chat
    //  conversation-nodes/assistant.ts:377-410——流式 chunk 与落盘 message 折叠进
    //  同一节点（step/start 建节点 → assistant/chunk update → assistant/message
    //  换最终 blocks 收敛），无"换手"概念。万我形态：直播槽（liveReasoning/
    //  liveText）以正式 Bubble 身份经 displayNodes 进入统一节点流，与落盘节点
    //  同构渲染；reproject 的落盘收敛走 settle 决策（打字机积压未清 → 补打期
    //  过滤落盘正文节点；否则同帧直接呈现）。
    /// 直播思考槽（nil = 无在途思考；镜像 streamingReasoning 缓冲——思考无打
    /// 字机，LED 尾行跟随即模型出字节奏）。
    @Published private(set) var liveReasoning: String?
    /// 直播正文槽（nil = 无在途正文；打字机演示值 = typeTarget.prefix(typeCursor)）。
    @Published private(set) var liveText: String?
    /// 落盘补打期（打字机积压未清；displayNodes 过滤补打目标落盘节点，live 槽
    /// 把剩余字打完后同帧结算——原 View 层 isSettling 迁入）。
    @Published private(set) var isSettling = false
    /// 结算帧落盘节点预登记（内容用户刚在直播看过 → 落盘节点即时呈现不播入场
    /// 动画；View 以 seen = animatedIDs ∪ settledBubbleIDs 消费——对应原
    /// :967/:1011/:1373 的 animatedIDs.insert 三处）。
    @Published private(set) var settledBubbleIDs: Set<String> = []
    /// live id 代际 ×2（review P1-1 修复：思考/正文**分立**——共享代际时，
    /// 正文开槽的 nil→非空 bump 会波及思考槽 id（live-r-N 整体换 id），
    /// ForEach diff 删旧插新 → WOEntryModifier @State 重置 → 思考行 fadeUp
    /// 重播。各自只在**本槽** nil→非空时推进（新段落/新 step = 新 id = 入场
    /// 动画天然一次，对应 dsh 每步新 turn:step 节点）。
    private var liveReasoningGeneration = 0
    private var liveTextGeneration = 0
    /// 打字机数据侧全文（当前段落累积快照；flushTextNow 同步，settle 后重置）。
    private var typeTarget = ""
    /// 打字机显示侧游标（33Hz 步进；段间不重置，仅新目标短于游标时归零）。
    private var typeCursor = 0
    /// 33Hz 节奏器（open 启动 / close 取消；仅在有打字目标时产生写面）。
    private var typewriterTask: Task<Void, Never>?
    @Published private(set) var resumeBanner: String?
    @Published private(set) var pressure: Compactor.PressureInfo?
    @Published var draft = ""
    // MARK: F042 附件（composer 输入侧；dsh ComposerAttachments/InputBar intake 语义）
    /// 待发送图片（本地 Data；发送时统一准入发布——dsh draftImages rail）。
    struct DraftImage: Identifiable, Equatable {
        let id: UUID
        var data: Data
        var mediaType: ImageMediaType
        var name: String?
    }
    /// intake 候选（选择器/拖放/粘贴共用入口的数据形态）。
    struct DraftImageCandidate {
        var data: Data
        var mediaType: ImageMediaType?
        var name: String?
    }
    @Published private(set) var draftImages: [DraftImage] = []
    /// 附件拒绝横幅（intake 预检/提交失败文案——dsh showToast → 横幅）。
    @Published var attachmentBanner: String?
    /// 附件存储缝（open() 时装配；nil = 会话未打开——intake fail closed）。
    @Published private(set) var attachmentStore: AttachmentStore?
    // MARK: T2.4 P1-3 会话级模型选择（dsh ModelSelect per-session
    // ModelSelection：选择随会话，不落盘、不落事件；App 级缺省=活动端点）。
    // T2.6 件2：宿主从本类实例属性升格 App 级 per-session 字典——ChatView
    // StateObject 随 RootSelection 切页销毁重建曾致 holder 归零丢选择（用户 #9）；
    // 现经 environment.modelSelection(for:) 取会话绑定宿主，会话存续期保持。
    /// 会话级选择值宿主（makeAgentStack @Sendable 缝消费）。
    private let modelSelection: SessionModelSelection
    /// 当前生效端点镜像（触发器与勾选显示；会话选择优先）。
    @Published private(set) var currentModelEndpoint: EndpointConfig?
    /// 会话级 effort（nil = provider default）。
    @Published private(set) var sessionEffort: String?
    // MARK: M3 T1 待决交互（composer 接管数据源；dsh 2026-07-23/07-29 笔记）
    /// 待决审批队列（composer 接管显示队首；first answer wins 由协调器保证）。
    @Published private(set) var pendingApprovals: [PendingApprovalPresentation] = []
    /// 待决提问队列（composer 接管显示队首）。
    @Published private(set) var pendingQuestions: [PendingQuestionPresentation] = []
    /// 审批按钮防双击（dsh：answered 后本地禁用，失败 re-arm）。
    @Published private(set) var approvalAnswering = false
    /// 提问提交防双击。
    @Published private(set) var questionBusy = false
    // MARK: M3 T2.2 派生状态
    /// 计划模式生效（Plan chip 显示位；PlanModeController.isActive 折叠镜像）。
    @Published private(set) var planActive = false
    /// 状态条整行（SessionStatsFold；composer dock）。
    @Published private(set) var statsLine: String?
    /// /permission danger-full-access 前置确认（A4；非 nil = 待确认命令行原文）。
    @Published var pendingPermissionConfirmation: String?
    /// 当前权限预设名（P2-⑪ 即时刷新：由计算属性改存储镜像——命令路径外的
    /// @Published 变化不触发重算，改镜像于 reproject 统一落位，保证
    /// composer 权限挡位标签即时跟随；nil = 权限系统未装配）。
    @Published private(set) var currentPermissionPreset: String?

    private let environment: AppEnvironment
    private let sessionID: String
    private var writer: SessionWriter?
    private var agentLoop: AgentLoop?
    /// 模型面就绪判定（UI 诚实呈现用：open 装配失败 = loop nil →
    /// send() 静默 no-op，UI 必须显式呈现降级横幅并禁用发送钮，
    /// 不得让用户对死按钮困惑——2026-09-20 真机反馈修复）。
    var isModelReady: Bool { agentLoop != nil }
    private var registry: ToolRegistry?
    /// replay 投影用的调用参数缓存（callId → name/args，presentResult 复现用）。
    private var callArgs: [String: (name: String, args: JSONValue)] = [:]
    private var runningTask: Task<Void, Never>?
    private var slashCommands: SlashCommandRegistry?
    // MARK: M3 T1 审批/提问装配引用（answer 路径回传宿主裁决登记处）
    private var approvalCoordinator: ApprovalCoordinator?
    private var questionService: UserQuestionService?
    /// M3 T2 权限协调器（/permission 命令装配输入）。
    private var permission: PermissionCoordinator?
    /// M3 T3 计划模式协调器（/plan 命令装配输入）。
    private var plan: PlanModeController?

    // 0.2s 节流（§5.4 OutputSanitizer 节流语义；M1 flush 模式复用）
    private var pendingTextChunks: Deque<String> = []
    private var pendingReasoningChunks: Deque<String> = []
    /// shell 行节流缓冲（E2：§7.3 shell 卡 0.2s 节流——原逐行直改 bubbles，
    /// 高频 bash 输出每行一次全表差分；现与文本 chunk 同一 flush 时钟）。
    private var pendingShellLines: [String: [String]] = [:]
    private var flushTimer: Timer?
    /// 批12+回归三校②（2026-09-24 用户实测"直接一张块"）：流式文本/思考
    /// 快车道时钟（0.04s=25Hz，对齐官方 Demo 30ms 微批次节奏）——0.2s 大批次
    /// 下段落视图逐词淡入的重启瞬间会整段瞬现（批12 库 setParagraphContents
    /// 先整段置串再起动画，批次越大"拍上"感越强）。shell 行保持 0.2s E2 不动。
    private var textFlushTimer: Timer?

    init(environment: AppEnvironment, sessionID: String, initialDraft: String = "") {
        self.environment = environment
        self.sessionID = sessionID
        // dsh 会话绑定选择宿主（App 级字典惰性建；切页销毁重建后仍
        // 取到同一 holder——选择跨 ChatView 生命周期保持）。
        self.modelSelection = environment.modelSelection(for: sessionID)
        // 草稿种子（dsh mount 种子草稿语义：缓存草稿跨切换跟回；
        // hero 交接文本经宿主以 initialDraft 注入）。
        if !initialDraft.isEmpty { self.draft = initialDraft }
    }

    // MARK: - 打开（resume + AgentLoop 装配）

    func open() {
        // 33Hz 节奏器生命周期（close 取消；重开恢复——open 的 phase 守卫针对
        // 装配流程，节奏器必须无条件就位，否则二次 onAppear 后补打停摆）。
        startTypewriterIfNeeded()
        guard phase == .loading else { return }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let (writer, repaired) = try await self.environment.sessionStore.openWriter(id: self.sessionID)
                self.writer = writer
                if repaired > 0 {
                    self.resumeBanner = "已恢复：\(repaired) 个中断收尾已修复"
                }
                // T2.4 P1-3：新会话按 dsh 语义初始化会话级选择（App 级缺省 =
                // 活动端点，effort = provider default；端点级旧 reasoningEffort
                // 字段废弃不读）。
                if self.modelSelection.get() == nil,
                   let active = self.environment.endpointStore.activeEndpoint() {
                    self.modelSelection.set(
                        .init(endpointID: active.id, reasoningEffort: nil))
                }
                self.currentModelEndpoint =
                    self.environment.endpointStore.resolve(selection: self.modelSelection.get())
                self.sessionEffort = self.modelSelection.get()?.reasoningEffort
                let stack = await self.environment.makeAgentStack(
                    sessionId: self.sessionID,
                    writer: writer,
                    callbacks: self.makeCallbacks(),
                    interactionPresenter: self,
                    modelSelection: self.modelSelection)
                self.agentLoop = stack.loop
                self.approvalCoordinator = stack.approvalCoordinator
                self.questionService = stack.questionService
                self.permission = stack.permission
                self.plan = stack.plan
                // F042：附件存储缝（本会话 bucket；intake/请求变体共用）。
                self.attachmentStore = stack.attachmentStore
                if let loop = stack.loop {
                    self.registry = loop.deps.registry
                    self.slashCommands = SlashCommandRegistry.makeDefault(
                        loop: loop, environment: self.environment,
                        permission: self.permission, plan: self.plan)
                } else {
                    // ERR-015/016：装配失败按「未配置模型」降级（原 agentLoop! 强解闪退）；
                    // 横幅带具体失败原因（无端点 / Key 不可读等），不再只有泛化提示。
                    self.registry = nil
                    self.slashCommands = nil
                    self.resumeBanner = "未配置模型：\(stack.failureReason ?? "未知原因") 请到「设置 · Providers」检查"
                }
                self.reproject()
                self.phase = .idle
            } catch {
                self.phase = .failed("打开会话失败：\(String(describing: error))")
            }
        }
    }

    // MARK: - 关闭（会话切换 / 视图离场）

    func close() {
        // 流式官方化：直播槽收摊（节奏器停摆 + 槽清退——live 槽只承载在途
        // 内容，不持历史；重开落盘内容由事件流重投影呈现）。
        typewriterTask?.cancel()
        typewriterTask = nil
        isSettling = false
        liveReasoning = nil
        liveText = nil
        Task { [weak agentLoop] in await agentLoop?.cancel(cause: .disposed) }
        let task = runningTask
        runningTask = nil
        task?.cancel()
        // M3 T1：桥关闭——在途待决一律 fail closed（审批 .unavailable /
        // 提问 ASK_ABORTED；m3-scope-brief §二.5「桥关闭在途待决一律 unavailable」）。
        approvalCoordinator?.bridgeClosed()
        questionService?.bridgeClosed()
        guard let writer = writer else { return }
        let store = environment.sessionStore
        Task {
            _ = await task?.value
            await store.closeWriter(writer)
        }
    }

    // MARK: - 发送 / 取消

    /// .failed(String) 带关联值不能直接 == 比较（隐式成员查找会落到系统类型）。
    private var canSendFromPhase: Bool {
        switch phase {
        case .idle, .failed: return true
        default: return false
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // .failed 也允许重发（错误状态条不是死锁——用户改完可直接重试）。
        // F042：带图时允许空文本（image-only 消息）。
        guard canSendFromPhase, let loop = agentLoop else { return }
        let images = draftImages
        guard !text.isEmpty || !images.isEmpty else { return }
        draft = ""
        draftImages = []

        if images.isEmpty, SlashCommandRegistry.isCommand(text) {
            runningTask = Task { [weak self] in
                await self?.runSlashCommand(text)
                self?.runningTask = nil
            }
            return
        }
        phase = .streaming
        // F042：先准入发布（AttachmentStore，CompressionLimiter 并发限界内
        // 归一化）→ 引用随 submit 通道进 loop（userMessage 后 E1 落盘）。
        // 准入失败整批拒绝：横幅 + 恢复 idle（fail closed，不半提交）。
        let store = attachmentStore
        // 验收修复 C（2026-09-27）注入缝取值（Task 外定格）：@ 图片按发送时
        // 的会话 cwd 解析（deps.sessionCwd 单一事实源——与 C-1 的 loop 侧
        // workspaceAccess 同源）。
        let sid = sessionID
        let sessionCwd = loop.deps.sessionCwd
        Task { [weak self] in
            var refs: [ImageAttachmentRef] = []
            if !images.isEmpty {
                guard let store else {
                    await MainActor.run { [weak self] in
                        self?.attachmentBanner =
                            "附件功能未就绪，请重新打开会话后再试"
                        self?.phase = .idle
                    }
                    return
                }
                do {
                    refs = try store.saveImages(images.map {
                        SaveImageAttachment(data: $0.data, mediaType: $0.mediaType,
                                            name: $0.name)
                    })
                } catch let error as AttachmentError {
                    await MainActor.run { [weak self] in
                        self?.attachmentBanner = ChatViewModel.attachmentErrorText(
                            code: error.code, limits: store.imageLimits)
                        self?.phase = .idle
                    }
                    return
                }
            }
            // 验收修复 C（2026-09-27）：@ 图片引用 → 附件通道。用户在右栏引用
            // workspace 内图片（@IMG_x.png）时文本通道收不到像素——
            // ContextInjection.expandFileReferences 二进制跳过（:199 UTF8 解码
            // 失败 continue），read_image 只回元数据 → AI 只能瞎猜。修法：
            // 图片引用按 F042 附件语义入库（saveImage 归一化/content-addressed）
            // 随 InboxEntry.images 进请求（index==0 归属照旧——injectContexts
            // 既有守卫）。降级纪律：解析失败/超限/坏图一律静默跳过（文本引用
            // 保留，AI 仍可 read_image 看元数据自救），不整批拒绝打断发送——
            // 引用是消息正文的一部分，与 draftImages 显式附件的 fail-closed
            // 语义分立。逐张 saveImage：单张坏图不拖垮同批好图。
            if let store {
                let limits = store.imageLimits
                let quota = max(0, limits.maxImagesPerMessage - refs.count)
                if quota > 0 {
                    let workspace = AgentLoop.workspaceAccess(
                        sessionId: sid, cwd: sessionCwd)
                    let candidates = Self.workspaceImageCandidates(
                        in: text, workspace: workspace, quota: quota,
                        maxImageBytes: limits.maxImageBytes,
                        aggregateBytes: limits.maxMessageImageBytes)
                    for candidate in candidates {
                        // DraftImageCandidate.mediaType 类型上为 Optional
                        //（intake 候选形态）；扫描器只产白名单命中（构造时
                        // 已保证非 nil），此处 guard 兑现类型承诺。
                        guard let mediaType = candidate.mediaType else { continue }
                        if let stored = try? store.saveImage(SaveImageAttachment(
                            data: candidate.data, mediaType: mediaType,
                            name: candidate.name)) {
                            refs.append(stored)
                        }
                    }
                }
            }
            // M7 件 G 触发器（codex turn_processor.rs:658-671 1:1——拍板
            // 2026-10-04 恢复）：用户新回合启动即尝试记忆管线（总开关/单飞/
            // 领取闸在触发器内部，空轮近零成本）。
            environment.memoryTrigger.onUserTurnStarted()
            await loop.submit(text, images: refs)
        }
    }

    // MARK: - F042 附件 intake（dsh InputBar.tsx:220-245 整批拒绝语义）

    /// intake 预检（InputBar.tsx:220-245 1:1：格式先行——含非白名单类型的批
    /// 先报格式问题；再数量/单图字节/聚合字节；整批拒绝、立即横幅、不入
    /// rail。nonisolated 纯函数——单测直呼）。
    nonisolated static func intakeRejection(existingCount: Int,
                                            newCandidates: [DraftImageCandidate],
                                            existingBytes: Int,
                                            limits: ImageAttachmentLimits) -> String? {
        // 格式先行（InputBar.tsx:224-229 注释原文语义：含非图片的批报格式
        // 问题，而非它永远过不了的 count/size）。dsh net 语义：委托权威
        // addImages 拒绝 → apply.ts:315 UnsupportedImageMediaTypeError →
        // t('image.unsupportedType')（locales.ts:41）——直返等价文案；不走
        // attachmentErrorText（UNSUPPORTED_IMAGE_TYPE 在 dsh image-labels.ts
        // switch 无 case，会误落 sendFailed 折入分支）。
        if newCandidates.contains(where: { $0.mediaType == nil }) {
            return "仅支持 PNG、JPG、WebP、GIF 格式的图片"
        }
        if existingCount + newCandidates.count > limits.maxImagesPerMessage {
            return attachmentErrorText(code: "TOO_MANY_IMAGES", limits: limits)
        }
        if newCandidates.contains(where: { $0.data.count > limits.maxImageBytes }) {
            return attachmentErrorText(code: "IMAGE_TOO_LARGE", limits: limits)
        }
        let incomingBytes = newCandidates.reduce(0) { $0 + $1.data.count }
        if existingBytes + incomingBytes > limits.maxMessageImageBytes {
            return attachmentErrorText(code: "IMAGES_TOO_LARGE", limits: limits)
        }
        return nil
    }

    // MARK: 验收修复 C（2026-09-27）：@ 图片引用扫描（发送层附件注入的取数面）

    /// 扫描文本中的 @ 图片引用为附件入库候选。语法与
    /// ContextInjection.expandFileReferences 同源（@ 后非空白串；不处理
    /// @"..." 引号形态——与现状一致，不扩范围）。白名单扩展名 → mediaType；
    /// 解析失败/读取失败/超单图字节帽/重复引用跳过，聚合字节帽触顶即停，
    /// quota 封顶（并入显式附件已占位数）。静默降级语义：跳过不报错——
    /// 文本引用保留，AI 仍可 read_image 看元数据。纯函数，单测直呼。
    nonisolated static func workspaceImageCandidates(
        in text: String, workspace: WorkspaceFileAccess, quota: Int,
        maxImageBytes: Int, aggregateBytes: Int) -> [DraftImageCandidate] {
        guard quota > 0, text.contains("@") else { return [] }
        var seen = Set<String>()
        var out: [DraftImageCandidate] = []
        var usedBytes = 0
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            guard out.count < quota else { break }
            let word = String(token)
            guard word.hasPrefix("@"), word.count > 1 else { continue }
            let path = String(word.dropFirst())
            guard seen.insert(path).inserted else { continue }
            let ext = (path as NSString).pathExtension
            guard let mediaType = Self.imageMediaType(forExtension: ext) else { continue }
            guard let url = workspace.resolve(path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty else { continue }
            guard data.count <= maxImageBytes else { continue }
            guard usedBytes + data.count <= aggregateBytes else { break }
            usedBytes += data.count
            out.append(DraftImageCandidate(data: data, mediaType: mediaType,
                                           name: url.lastPathComponent))
        }
        return out
    }

    /// 扩展名 → 附件媒体类型（白名单四类；大小写不敏感）。纯函数。
    nonisolated static func imageMediaType(forExtension ext: String) -> ImageMediaType? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "webp": return .webp
        case "gif": return .gif
        default: return nil
        }
    }

    /// intake 入口（选择器/拖放/粘贴共用一径——one path）。
    func addDraftImages(_ candidates: [DraftImageCandidate]) {
        guard !candidates.isEmpty else { return }
        guard let limits = attachmentStore?.imageLimits else {
            attachmentBanner = "附件功能未就绪，请重新打开会话后再试"
            return
        }
        if let rejected = Self.intakeRejection(
                existingCount: draftImages.count,
                newCandidates: candidates,
                existingBytes: draftImages.reduce(0) { $0 + $1.data.count },
                limits: limits) {
            attachmentBanner = rejected
            return
        }
        draftImages.append(contentsOf: candidates.map {
            DraftImage(id: UUID(), data: $0.data,
                       mediaType: $0.mediaType ?? .png, name: $0.name)
        })
        attachmentBanner = nil
    }

    /// 移除待发送图（dsh onRemoveImage；rail 移除钮）。
    func removeDraftImage(id: UUID) {
        draftImages.removeAll { $0.id == id }
    }

    /// 附件拒绝文案（dsh ui-conversation image-labels.ts:28-56
    /// attachmentErrorText 1:1；zh 逐字——用户可解的报限额与出路，其余折入
    /// sendFailed 带 reason code）。
    nonisolated static func attachmentErrorText(code: String,
                                                limits: ImageAttachmentLimits) -> String {
        switch code {
        case "MODEL_DOES_NOT_SUPPORT_IMAGES":
            return "当前模型不支持图片，请切换支持图片的模型"
        case "IMAGE_TOO_MANY_PIXELS":
            return "图片分辨率过大，请压缩后重试"
        case "IMAGE_DIMENSION_TOO_LARGE":
            return "图片宽高不能超过 \(limits.maxImageDimension)px，请缩小后重试"
        // Undecodable bytes 或声明与字节不符：可解 = 换文件/重新导出，读作
        // 格式问题（image-labels.ts:39-43 注释原文语义）。
        case "INVALID_IMAGE", "IMAGE_TYPE_MISMATCH":
            return "仅支持 PNG、JPG、WebP、GIF 格式的图片"
        case "TOO_MANY_IMAGES":
            return "一条消息最多添加 \(limits.maxImagesPerMessage) 张图片"
        case "IMAGE_TOO_LARGE":
            return "单张图片不能超过 \(imageSizeText(limits.maxImageBytes))"
        case "IMAGES_TOO_LARGE":
            return "图片总大小超过 \(imageSizeText(limits.maxMessageImageBytes))，请移除部分图片"
        default:
            return "图片发送失败（\(code)），请重新添加图片后再试"
        }
    }

    /// 字节 → 用户面 MB（image-labels.ts:12-15 imageSizeText 1:1：整数不带
    /// 小数「10MB」、其余一位小数「2.5MB」）。
    nonisolated static func imageSizeText(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(mb))MB"
        }
        return String(format: "%.1fMB", mb)
    }

    func cancel() {
        Task { await agentLoop?.cancel(cause: .user) }
    }

    // MARK: - M3 T2.2 GUI 命令通道（与手输同路）

    /// GUI 通道的命令提交（dsh「both surfaces write through one path」——
    /// composer 权限挡位下拉 / Plan chip 与手输命令同一 command/run → run →
    /// command/done 落盘路径）。phase 纪律与 send() 一致。
    /// confirmed = 入口自带的确认已通过（P2-⑪ 双弹修复：dsh 确认缝归入口所有
    /// ——PermissionSelect.tsx:129-133 下拉内 RiskConfirmation 确认后直达提交；
    /// 手输 /permission danger-full-access 仍走命令门控确认）。
    func runCommandLine(_ line: String, confirmed: Bool = false) {
        guard SlashCommandRegistry.isCommand(line), canSendFromPhase else { return }
        runningTask = Task { [weak self] in
            await self?.runSlashCommand(line, confirmed: confirmed)
            self?.runningTask = nil
        }
    }

    /// Full access 前置确认（A4）：仅 /permission danger-full-access 需门控
    /// （dsh popupSelect confirming gate + PermissionSelect.tsx:129-133 特判）；
    /// 带参直达语义对其他预设保留。nonisolated 纯函数（单测直呼）。
    nonisolated static func isFullAccessCommand(name: String, args: String?) -> Bool {
        name == "permission"
            && args?.trimmingCharacters(in: .whitespacesAndNewlines) == "danger-full-access"
    }

    /// 确认执行待确认的 Full access 命令（绕过门控直达执行器——确认即放行，
    /// 否则门控会再次拦截形成回环）。
    func confirmPendingPermission() {
        guard let line = pendingPermissionConfirmation else { return }
        pendingPermissionConfirmation = nil
        runningTask = Task { [weak self] in
            await self?.executeSlashCommand(line)
            self?.runningTask = nil
        }
    }

    /// 取消 Full access 确认（fail closed：不执行、不留痕迹）。
    func cancelPendingPermission() {
        pendingPermissionConfirmation = nil
    }

    /// 模型选择提交（T2.4 P1-3：dsh choose() 语义——per-session 选择，
    /// 不写全局 activeEndpoint；选择模型时 effort 回 provider default
    /// （dsh :171-178 selection 不带旧 effort，WanWo 无 defaultEffort
    /// 元数据 → nil））。下一请求即生效（makeAdapter 按调用时选择取用）。
    /// M8 批1 件A4：两级选择（endpoint → 模型；modelID = 会话级覆盖，
    /// EndpointStore.resolve 应用——目录为空传 endpoint.model 即现状行为）。
    func selectModel(_ endpoint: EndpointConfig, modelID: String) {
        modelSelection.set(.init(endpointID: endpoint.id, reasoningEffort: nil,
                                 modelID: modelID))
        currentModelEndpoint = environment.endpointStore.resolve(selection: modelSelection.get())
        sessionEffort = nil
    }

    /// 推理等级提交（T2.4 P1-3：会话级内存态——dsh chooseEffort() 语义，
    /// nil = provider default 不透传；写入活动端点的 reasoningEffort 的旧
    /// 行为随端点级字段废弃而移除）。下一请求即生效。
    func selectEffort(_ effort: String?) {
        var value = modelSelection.get()
        if value == nil, let resolved = environment.endpointStore.resolve(selection: nil) {
            value = .init(endpointID: resolved.id, reasoningEffort: nil)
        }
        guard value != nil else { return }
        value?.reasoningEffort = effort
        modelSelection.set(value)
        currentModelEndpoint = environment.endpointStore.resolve(selection: value)
        sessionEffort = effort
    }

    /// 模型挡位数据源（ModelSelectView @ObservedObject 接线）。
    var endpointStore: EndpointStore { environment.endpointStore }

    /// 命令列表（slash 菜单数据源；按名称排序——dsh helpText 同序）。
    var slashCommandList: [SlashCommandRegistry.Command] {
        (slashCommands?.commands.values.sorted { $0.name < $1.name }) ?? []
    }

    // MARK: - F075 @ 引用菜单数据源（cc-haha ComposerReferenceMenu 语义）

    /// @ 引用候选：guest 工作区相对路径（文件+目录），query 双模——
    /// `src/` 结尾=浏览 src 子层；`src/ma`=src 下前缀过滤；空=根层。
    /// 与 cc-haha filesystemApi「搜索/目录浏览」同构；上限 40 条防弹层溢出。
    /// 【批2 F075 2026-09-27】注入端=F040 expandFileReferences（既有）。
    func mentionCandidates(query: String) -> [String] {
        let wsPath = environment.guestWorkspacePath(for: sessionID)
        guard let hostRoot = WanWoPaths.projectsHostRoot(forGuestPath: wsPath) else {
            return []
        }
        let trimmed = query.hasPrefix("@") ? String(query.dropFirst()) : query
        // 目录段 / 尾段拆分（"src/ma" → browse "src"，filter "ma"）。
        let browsing = trimmed.hasSuffix("/")
        let parts = trimmed.split(separator: "/").map(String.init)
        let filter = browsing ? "" : (parts.last ?? "")
        let dirRel = browsing ? trimmed : parts.dropLast().joined(separator: "/")
        let baseDir = dirRel.isEmpty
            ? hostRoot
            : hostRoot.appendingPathComponent(dirRel, isDirectory: true)
        guard FileManager.default.fileExists(atPath: baseDir.path) else { return [] }
        let rows = WorkspaceFileTreeModel.enumerate(hostDir: baseDir, relativeBase: dirRel.isEmpty ? "" : dirRel)
        let labels: [String] = rows.map { node in
            node.isDirectory ? "\(node.id)/" : node.id
        }
        guard !filter.isEmpty else { return Array(labels.prefix(40)) }
        return Array(labels.filter { $0.lowercased().contains(filter.lowercased()) }.prefix(40))
    }

    /// 幽灵提示（dsh InputBar.tsx:335-353 claim hint：args 为空时显示命令
    /// hint；dsh 词典仅 hint.plan/goal，WanWo 无 goal → 仅 /plan）。
    var commandHint: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed == "/plan" || trimmed.hasPrefix("/plan "),
              trimmed.dropFirst("/plan".count).trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        // hint.plan zh 原文（ui-conversation locales.ts:7 = placeholder.plan 同值）。
        return "描述你的任务以生成计划"
    }

    /// 草稿是否为空（主按钮状态机入参）。
    var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发送就绪（idle/failed 可发——.failed 重试口径不变）。
    var canSend: Bool { canSendFromPhase }

    /// 命令任务在途（GUI 命令通道 busy；PermissionSelectView 禁用入参）。
    var isCommandRunning: Bool { runningTask != nil }

    /// 主按钮状态机（dsh InputBar.tsx:313-326 primaryStops：运行中且无草稿 →
    /// 主按钮同位变停止；有草稿 → 发送（Queue 语义随 M7，本构建禁用）。
    /// nonisolated 纯函数（单测不经 MainActor 直呼）。
    nonisolated static func primaryStops(running: Bool, draftEmpty: Bool) -> Bool {
        running && draftEmpty
    }

    // MARK: - 斜杠命令（command/run → 执行 → command/done）

    /// 门控入口：未经入口确认的 Full access 命令先行拦截（确认前零副作用——
    /// 不落 command/run、不执行），其余直入执行器。
    private func runSlashCommand(_ text: String, confirmed: Bool = false) async {
        let name = SlashCommandRegistry.commandName(text)
        let rawArgs = text.count > name.count + 1
            ? String(text.dropFirst(name.count + 2)) : nil
        if !confirmed, Self.isFullAccessCommand(name: name, args: rawArgs) {
            pendingPermissionConfirmation = text
            return
        }
        await executeSlashCommand(text)
    }

    /// 执行器（command/run → run → command/done → 重投影；无门控——确认
    /// 放行路径与普通命令共用）。
    private func executeSlashCommand(_ text: String) async {
        guard let writer = writer else { return }
        let name = SlashCommandRegistry.commandName(text)
        let rawArgs = text.count > name.count + 1
            ? String(text.dropFirst(name.count + 2)) : nil
        guard let command = slashCommands?.command(named: name) else {
            let help = slashCommands?.helpText ?? "Unknown command."
            try? await writer.append(.commandRun(commandId: UUID().uuidString,
                                                 name: name, args: nil))
            try? await writer.append(.commandDone(commandId: "", kind: "error",
                                                  text: "Unknown command \"\(name)\".\n\n\(help)"))
            reproject()
            return
        }
        let commandId = UUID().uuidString
        let args = rawArgs
        try? await writer.append(.commandRun(commandId: commandId, name: name, args: args))
        let result = await command.run(args)
        try? await writer.append(.commandDone(commandId: commandId, kind: "success", text: result))
        reproject()
    }

    // MARK: - AgentLoop 回调（后台线程 → MainActor）

    private func makeCallbacks() -> AgentLoop.Callbacks {
        AgentLoop.Callbacks(
            onLiveChunk: { [weak self] chunk in
                Task { @MainActor [weak self] in self?.handleLiveChunk(chunk) }
            },
            onShellLine: { [weak self] callId, line in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // E2：shell 行进节流缓冲（§7.3 shell 卡 0.2s 节流），
                    // flushNow 统一落卡。
                    self.pendingShellLines[callId, default: []].append(line)
                    self.flushIfIdle()
                }
            },
            onTokenPressure: { [weak self] info in
                Task { @MainActor [weak self] in self?.pressure = info }
            },
            onTurnEnd: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 批12+回归九校-B：换手帧"刚结束直播"旗先于 reproject
                    // 置位（视图渲染帧即可见；1.5s 后自清）——instantLive
                    // 跨 phase 翻转保持语义，收尾帧落盘节点不多播动画。
                    self.justEndedStreaming = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        self?.justEndedStreaming = false
                    }
                    self.flushNow()
                    self.reproject()
                    // M6.6（B4）：运行态镜像清退（侧聊父会话状态行数据源）。
                    self.environment.noteRunState(sessionId: self.sessionID,
                                                  running: false)
                    // 【批2 变更卡 2026-09-27】回合结束对比快照（cc-haha
                    // CurrentTurnChangeCard 语义）→ 有变更：①系统纸条列清单
                    // （复用批2 .system→note 投影分支，零新投影面；文件行可点
                    // 性/diff 统计=M9.6 范围已拍板剔除）②文件页签刷新信号
                    // （高亮承接"去看文件"动线）。diff 为 nil（无快照/超护栏/
                    // 无变更）不落纸条。
                    let wsPath = self.environment.guestWorkspacePath(for: self.sessionID)
                    if let changes = WorkspaceChangeMonitor.shared.consumeChanges(
                        sessionID: self.sessionID, workspacePath: wsPath) {
                        let note = Self.turnChangeNote(changes)
                        let writer = self.writer
                        Task {
                            try? await writer?.append(.system(note: note))
                        }
                        // 页签高亮数据源（新增/修改/删除合集）。
                        WOWorkspaceStore.shared.noteFileChanges(
                            sessionID: self.sessionID,
                            paths: Set(changes.added + changes.modified + changes.removed))
                    }
                    WOWorkspaceStore.shared.noteFileActivity(sessionID: self.sessionID)
                    // F060 可观测性最小纪律：错误必须自解释——turn/end error
                    // 把 failure.message 原文（DeepSeek providerMessage）带进
                    // 状态条（截 200 防撑爆），不能只给 code。
                    if case .error(let failure) = reason {
                        self.phase = .failed(Self.failureBanner(failure))
                    } else {
                        self.phase = .idle
                    }
                    self.maybeGenerateTitle()
                }
            },
            onPhaseChange: { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .running = phase {
                        self.phase = .streaming
                        // M6.6（B4）：运行态镜像登记（侧聊父会话状态行）。
                        self.environment.noteRunState(sessionId: self.sessionID,
                                                      running: true)
                    }
                }
            },
            onToolCallStarted: { [weak self] _, _, _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // E2 统一投影：tool/call 已落盘（ToolCallScheduler 契约：
                    // started 在落盘后发射），卡片位置由事件流折叠给出（dsh
                    // assembler：append 与 replaceWindow 同一 matchInput，节点
                    // 位置=起始事件 seq）。此刻本步 assistant/message 亦已落盘
                    // （AgentLoop runStep：先 append 消息再调度工具）——重投影
                    // 自事件流渲染思考/回复块并清空流式缓冲（按块分立），live
                    // 不再按到达序自行 append 卡片（原 live/replay 分叉点）。
                    self.reproject()
                }
            },
            onToolCallFinished: { [weak self] callId, output, isError in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let index = self.bubbles.lastIndex(where: {
                        if case .tool(let card) = $0.kind { return card.callId == callId }
                        return false
                    }), case .tool(var card) = self.bubbles[index].kind {
                        // presentResult 纯函数复现（live 与 replay 同形；M3 T1：
                        // ask_user_question 的 N/M answered 等结算标题由此更新）。
                        let args = self.callArgs[callId]?.args ?? .null
                        let toolOutput = ToolOutput(text: output, isError: isError,
                                                    errorName: nil, errorCode: nil,
                                                    meta: nil)
                        if let name = self.callArgs[callId]?.name,
                           let intent = self.registry?.get(name)?.presentResult(args, toolOutput) {
                            card.title = intent.title
                            card.detail = intent.detail
                        }
                        card.resultText = output
                        card.isError = isError
                        card.isRunning = false
                        self.bubbles[index].kind = .tool(card)
                        // 【批2 文件页签自动刷新】工具结果=文件活动信号（store
                        // 侧 0.8s 节流合并——cc-haha 120ms 合并窗口的万我等价）。
                        WOWorkspaceStore.shared.noteFileActivity(
                            sessionID: self.sessionID)
                        // 件 I 宿主接线：工具结果落定后 todo/write 的
                        // extensionEvent 已落盘（execute 内 append 先于
                        // finished 发射）——重 fold 刷新状态卡（todo/write=
                        // 整表替换语义，fold 幂等便宜）。
                        self.todoItems = TodoProjection.fold(
                            events: self.writer?.events ?? []) ?? []
                        // 【批3 A2】goal 快照同位刷新（goal/change 落盘先于
                        // finished 发射——与 todoItems 同一刷新时钟）。
                        // 【CI修39】foldGoal 无外部标签（`_ events:`），原
                        // `events:` 标签无匹配重载=整链歧义；且 FoldedGoal.goal
                        // 是 GoalSnapshot?，直接 `?.goal` 得双可选且类型不符
                        // （GoalView≠GoalSnapshot）——统一走 foldGoalView 重建。
                        // 【批4 G3】赋值点 1/5：动画化（GoalBar 淡入）。
                        self.setGoalView(Self.foldGoalView(self.writer?.events ?? []))
                    } else {
                        // 卡不在场兜底（理论不发生：started 已重投影；防御
                        // 回调乱序/漏发——直接按事件流重建）。
                        self.reproject()
                    }
                }
            },
            onUserMessageAppended: { [weak self] text, images in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // P2-⑪ 消息即时上屏：user/message 落盘即入流（乐观气泡），
                    // 不等首个工具卡/回合尾重投影。标记消息（runtime snapshot
                    // 等）与投影层同一过滤纪律，不渲染；下一轮 reproject 以
                    // 事件流折叠产物整体替换（身份/文本同源收敛）。
                    // T2.6 件6（用户 #22 前半）：乐观气泡带图——回调第二参 =
                    // 随行图片引用（E1 attachment/images 已落盘后发射），重投影
                    // 前图片即时可见。
                    // 【批3 复审修 P1-1】goal_round 注入的即时上屏补触发：双卡
                    // 根因修复拆掉乐观哨兵（正确），但 marker 拦截 return 之后
                    // 到下一投影触发点（turn 尾/工具卡 reproject）之间无投影
                    // 时钟——goal 收尾轮（模型纯文本回复，goal_drive 常态）gr
                    // 卡整轮缺席；onTurnEnd 与注入落盘（seq1967-1969 在 turn/
                    // end 后 ~7ms 落盘，test_core 实证）同帧竞态下还可能再延
                    // 一轮。此刻 goal_round userMessage 已落盘（AgentLoop 注入
                    // 先 append 后发射本回调，见回调契约头注），直接重投影：
                    // 恒产一张 gr(seq) 专卡、无乐观哨兵、无竞态窗口（紧随的
                    // goal/round、system 纸条经 onToolCallStarted/onTurnEnd
                    // 常规时钟收敛）。<attachment-refs> 无卡面（UI 隐藏），不
                    // 需触发。侧聊（SideChatViewModel）同 guard 不修：gr 卡
                    // 渲染面=EmptyView（批3 A1 拍板），无用户可见缺陷。
                    guard !ConversationProjector.isMarkerMessage(text) else {
                        if text.hasPrefix("<goal_round>") {
                            self.reproject()
                        }
                        return
                    }
                    // 【批2 变更检测 2026-09-27】真实用户消息=回合开始 → 拍工作区
                    // 快照（cc-haha turn checkpoint 语义；平台适配=回合边界宿主
                    // 快照对比，见 WorkspaceChangeMonitor 头注）。此刻 AI 尚未
                    // 开始本回合写盘，基线正确。marker（注入纸条）不算回合开始。
                    WorkspaceChangeMonitor.shared.takeSnapshot(
                        sessionID: sessionID,
                        workspacePath: environment.guestWorkspacePath(for: sessionID))
                    // 批12+回归八校（用户日志 entry-diag.log L1/L2 实证）：乐观
                    // 气泡 id 改固定哨兵"u-pending"——原 live-user-UUID 与落盘
                    // 投影 id "u(seq)" 双身份，落盘替换=删掉重插=入场动画重播
                    // （"我发的消息被跟着一起动画"）。哨兵 + 视图侧 pendingUserSeen
                    // 交接（WOChatView）=单次动画无缝换 id。
                    self.bubbles.append(ChatViewModel.Bubble(
                        id: "u-pending",
                        kind: .user(text, images)))
                }
            })
    }

    private func appendToCard(callId: String, line: String) {
        for index in bubbles.indices {
            if case .tool(var card) = bubbles[index].kind, card.callId == callId {
                card.liveOutput = Self.appendingLiveLine(card.liveOutput, line)
                bubbles[index].kind = .tool(card)
                return
            }
        }
    }

    // MARK: - 长文本渲染优化（E2）

    /// live 流式输出环形窗口封顶：卡片只保留尾部 N 字符（完整原文在事件流，
    /// 卡片只为可读性——dsh toolview 为虚拟化列表，WanWo M9 前以窗口兜底，
    /// 防 bash 高频输出的无界 Text 布局）。
    static let maxLiveOutputCharacters = 3_000
    static let liveOutputTruncationMarker = "…（前文已截断）"

    static func appendingLiveLine(_ current: String, _ line: String) -> String {
        var updated = current.isEmpty ? line : current + "\n" + line
        if updated.count > maxLiveOutputCharacters {
            let body = String(updated.suffix(maxLiveOutputCharacters))
            updated = body.hasPrefix(liveOutputTruncationMarker)
                ? body
                : liveOutputTruncationMarker + "\n" + body
        }
        return updated
    }

    /// 状态条错误文案（F060）：code + message 原文（DeepSeek providerMessage，
    /// 400 场景即其原始抱怨）；换行拍平，截 200 防撑爆状态条。
    private static func failureBanner(_ failure: LlmFailure) -> String {
        let flattened = failure.message.replacingOccurrences(of: "\n", with: " ")
        let body = flattened.count > 200
            ? String(flattened.prefix(200)) + "…"
            : flattened
        return "模型错误 [\(failure.code)] \(body)"
    }

    /// 【批2 变更卡】回合文件变更纸条文本（cc-haha CurrentTurnChangeCard 文案
    /// 语义的中文对齐：清单+状态标签；折叠阈值 5 与 COLLAPSED_COUNT 同值——
    /// 纸条形态下列全量但每组截断展示，防超长回合刷屏）。
    static func turnChangeNote(_ changes: WorkspaceChangeMonitor.ChangeSet) -> String {
        var lines: [String] = []
        func section(_ title: String, _ paths: [String], _ tag: String, into out: inout [String]) {
            guard !paths.isEmpty else { return }
            out.append("\(title) \(paths.count) 个：")
            for path in paths.prefix(5) {
                out.append("· [\(tag)] \(path)")
            }
            if paths.count > 5 {
                out.append("· …等共 \(paths.count) 个")
            }
        }
        section("新增", changes.added, "新增", into: &lines)
        section("修改", changes.modified, "修改", into: &lines)
        section("删除", changes.removed, "删除", into: &lines)
        return "本回合工作区文件变更：\n" + lines.joined(separator: "\n")
    }

    private func maybeGenerateTitle() {
        guard let writer = writer else { return }
        let firstTurnOfSession = writer.nextTurn <= 2
        guard firstTurnOfSession,
              let adapter = try? environment.makeAdapter().0 else { return }
        let database = environment.database
        let environment = self.environment
        Task { [weak self] in
            await TitleGenerator.generateAndStore(writer: writer, database: database,
                                                  adapter: adapter)
            await MainActor.run { self?.environment.sessionsRevision += 1 }
            _ = environment
        }
    }

    // MARK: - 投影（UI = 事件流的只读视图；E2 起折叠在 ConversationProjector）

    private func reproject() {
        guard let writer = writer else { return }
        // 瞬态续接（dsh current map 语义）：在途卡片的 liveOutput（含尚未
        // flush 的 shell 行）与 statusNote 按 callId 带入新投影——只重建
        // 「dirty」内容，未变节点保状态。
        var carried = Self.toolCards(in: bubbles)
        for (callId, lines) in pendingShellLines {
            guard var card = carried[callId] else { continue }
            for line in lines {
                card.liveOutput = Self.appendingLiveLine(card.liveOutput, line)
            }
            carried[callId] = card
        }
        pendingShellLines.removeAll()
        var callArgsSnapshot = callArgs
        let projected = ConversationProjector.project(
            events: writer.events, registry: registry,
            callArgs: &callArgsSnapshot, previousCards: carried)
        callArgs = callArgsSnapshot
        bubbles = projected
        // 件 I 宿主接线：todo 投影随重投影全量 fold（todo/write log-only
        // 不进 Bubble 流——dsh "never derived history" 语义，状态卡独立槽）。
        todoItems = TodoProjection.fold(events: writer.events) ?? []
        // 【批3 A2】goal 快照同位重 fold（goal/* extensionEvent log-only，
        // 除 goalRound 专卡外不进 Bubble 流；dsh 'goal' projection
        // whole-value 语义——快照整体替换）。【批4 G3】赋值点 2/5：单语句
        // 动画事务——只让 goal 快照变化进事务，bubbles/todoItems 等其余
        // 重投影赋值保持原时钟不动。
        setGoalView(Self.foldGoalView(writer.events))
        // 流式官方化（2026-10-04）：streamingText/streamingReasoning 降级为
        // 数据侧缓冲——清空不再充当"换手信号"（原 :949-950 清空 = View 层
        // onChange(streamingText) 换手状态机触发点，已拆除）。live 槽结算改走
        // 本函数末尾 settleLiveSlots()（打字机积压决策），防双产。
        streamingText = ""
        streamingReasoning = ""
        // 幽灵回合修复（根因终判+lead 批准）：pending 流式缓冲一并清空。
        // 不清则迟到的 0.2s flushTimer 在清面之后把最后一个 flush 窗口压着
        // 的本 step 尾部 delta 倒回 streaming 行——工具等待期（多秒 bash/
        // ask_user_question/审批）流式行持续显示 step-1 思考+回复尾部=
        // 「幽灵回合」，新 step 流式追加其上=「被新内容覆盖」观感。安全性：
        // ①reproject 全部调用点执行时本 step delta 已落盘（assistant/message
        // 先于 tool/call 的落盘契约），pending 是持久化内容的纯重复，投影自
        // 事件流渲染已含全文，丢弃无损；②delta 与 reproject 全经 Task
        // @MainActor 按发射序 FIFO，同 step 内无后到污染。pendingShellLines
        // 已有续接面（上方 carried 带入卡片），text/reasoning 无续接面——
        // 对称补齐。
        pendingTextChunks.removeAll()
        pendingReasoningChunks.removeAll()
        // T2.2 派生状态刷新（plan chip 镜像 + 状态条折叠 + 权限挡位镜像）。
        planActive = plan?.isActive ?? false
        currentPermissionPreset = permission?.knobs.currentPresetName()
        statsLine = SessionStatsFold.line(for: SessionStatsFold.fold(events: writer.events))
        // live 琥珀状态行不在事件流中——重投影后按在途队列重放（M3 T1）。
        if let first = pendingApprovals.first, let callId = first.callId {
            setCardStatus(callId: callId, note: "等待审批")
        }
        // 流式官方化：live 槽结算（dsh assistant/message 落盘收敛语义——同一
        // 节点换最终 blocks，无换手）。须在 bubbles 更新后执行（steppedForward
        // 判定读 bubbles；打字机积压读 typeTarget/typeTarget 已由 flush 同步）。
        settleLiveSlots()
    }

    /// 现存工具卡快照（callId → 卡），供投影续接瞬态字段。
    private static func toolCards(in bubbles: [Bubble]) -> [String: ToolCard] {
        var cards: [String: ToolCard] = [:]
        for bubble in bubbles {
            if case .tool(let card) = bubble.kind { cards[card.callId] = card }
        }
        return cards
    }

    // MARK: - GoalBar 动作（批3 A2；dsh slots.ts GoalBarActions CAS 语义对拍）

    // 【批4 G3】GoalBar 淡入淡出时钟（用户复测 A2①）：goalView 的全部赋值
    // 点原为裸赋值——WOGoalBar 内部 `.animation(value: goal)` 管不住
    // EmptyView↔横条的结构性插入/移除（transition 需要祖先链上有动画时钟）。
    // 统一经 setGoalViewAnimated 包 withAnimation；曲线与 WOGoalBar.motionCurve
    // 同参数（timingCurve(0.22,1,0.36,1, 0.35s)——本文件侧独立常量，WOGoalBar
    // 不在本批白名单，参数对齐以注释互证）；reduceMotion 时静态直出
    // （WOGoalBar/WOAgentHintPill 同款先例）。挂载点结构（WOChatView:347-355）
    // 不动。
    /// goal 条入/退场曲线（与 WOGoalBar.motionCurve 同参数：cubic-bezier(.22,1,.36,1)）。
    private static let goalMotionCurve = Animation.timingCurve(0.22, 1, 0.36, 1,
                                                               duration: 0.35)

    /// goalView 唯一动画化赋值缝（五个原赋值点统一收口；单语句事务——
    /// reproject 等批量刷新面内不得整包动画，只让 goal 快照变化进事务）。
    private func setGoalView(_ newValue: GoalView?) {
        if UIAccessibility.isReduceMotionEnabled {
            goalView = newValue
        } else {
            withAnimation(Self.goalMotionCurve) { goalView = newValue }
        }
    }

    /// 暂停目标（GoalService.pause：expectCurrent CAS——revision 不匹配 =
    /// GOAL_STALE_REVISION，UI 侧回读收敛）。
    func pauseGoal() async -> String? {
        await goalMutation { try await $0.pause(ref: $1) }
    }

    /// 恢复目标（服务侧拒绝 active+armed 与 roundsStarted≥max——错误如实
    /// 透出给 GoalBar error 槽）。
    func resumeGoal() async -> String? {
        await goalMutation { try await $0.resume(ref: $1) }
    }

    /// 编辑目标内容（dsh onEdit(trimmed)：仅 objective，maxGoalRounds 不动）。
    func editGoalObjective(_ objective: String) async -> String? {
        await goalMutation { try await $0.edit(ref: $1, objective: objective,
                                               maxGoalRounds: nil) }
    }

    /// 清除目标（dsh onClear；成功后快照置 nil → GoalBar 消失条件命中）。
    func clearGoal() async -> String? {
        guard let service = agentLoop?.deps.goalService,
              let ref = goalRef() else { return nil }
        do {
            _ = try await service.clear(ref: ref)
            // 【批4 G3】赋值点 3/5：清除 → 横条淡出（动画化 nil）。
            setGoalView(nil)
            return nil
        } catch {
            refreshGoalSnapshot()
            return Self.goalActionMessage(error)
        }
    }

    /// 统一变更通道：以当前快照 revision 提交 CAS → 成功采纳服务端返回的
    /// 权威快照（revision 已自增）；失败回读事件流收敛 UI（服务端权威，
    /// stale 双写不可达——dsh GoalActionResult{ok,error} 语义，错误文案
    /// 交 GoalBar actionError 槽呈现）。
    private func goalMutation(
        _ body: (GoalService, GoalRef) async throws -> GoalView
    ) async -> String? {
        guard let service = agentLoop?.deps.goalService,
              let ref = goalRef() else { return nil }
        do {
            // 【批4 G3】赋值点 4/5：CAS 成功采纳权威快照（动画化——active↔
            // paused 翻转不闪，同曲线跨状态过渡）。
            let adopted = try await body(service, ref)
            setGoalView(adopted)
            return nil
        } catch {
            refreshGoalSnapshot()
            return Self.goalActionMessage(error)
        }
    }

    /// CAS 提交用的当前引用（id + revision——快照捕获时刻的乐观锁）。
    private func goalRef() -> GoalRef? {
        goalView.map { GoalRef(id: $0.id, revision: $0.revision) }
    }

    /// 失效回读（事件流 = 权威日志；fold 幂等便宜——todoItems 同款纪律）。
    /// 【批4 G3】赋值点 5/5：CAS 失败回读路径同走动画时钟（视觉收敛一致）。
    private func refreshGoalSnapshot() {
        guard let writer else { return }
        setGoalView(Self.foldGoalView(writer.events))
    }

    /// 事件流 → GoalView 重建（GoalService.view(:109-119) 同构映射；【CI修39】
    /// activation 是进程本地面、事件流无载——恒 .disarmed 初值，权威激活态随
    /// GoalService 动作回调刷新；WOGoalBar 不消费 activation，UI 零影响）。
    private static func foldGoalView(_ events: [SessionEvent]) -> GoalView? {
        guard let folded = try? GoalFold.foldGoal(events), let snap = folded.goal else {
            return nil
        }
        return GoalView(id: snap.id, revision: snap.revision, objective: snap.objective,
                        phase: snap.phase, blockedReason: snap.blockedReason,
                        maxGoalRounds: snap.maxGoalRounds,
                        roundsStarted: folded.roundsStarted,
                        createdAt: folded.createdAt ?? 0,
                        updatedAt: folded.updatedAt ?? 0,
                        activation: .disarmed)
    }

    /// 错误文案（dsh GoalBar.tsx:61 `message (code)` 形态；错误码透出，
    /// F060 自解释纪律）。
    private static func goalActionMessage(_ error: Error) -> String {
        "\(error.localizedDescription)"
    }

    // MARK: - 流式直通车（批12+回归三校：文本/思考 0.04s 快车道 + shell 行 0.2s E2 节流）

    private func handleLiveChunk(_ chunk: StreamChunk) {
        switch chunk {
        case .textDelta(_, let text):
            pendingTextChunks.append(text)
        case .reasoningDelta(_, let text):
            pendingReasoningChunks.append(text)
        default:
            break
        }
        flushTextIfIdle()
    }

    /// 流式文本/思考快车道（0.04s 单发定时，与 flushIfIdle 同模式）。
    private func flushTextIfIdle() {
        guard textFlushTimer == nil else { return }
        textFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.textFlushTimer = nil
                self?.flushTextNow()
            }
        }
    }

    /// 只冲文本/思考两路（shell 行归 0.2s 慢车道；turn 收尾的 flushNow 仍全量）。
    private func flushTextNow() {
        if !pendingTextChunks.isEmpty {
            while let chunk = pendingTextChunks.popFirst() {
                streamingText += chunk
            }
        }
        if !pendingReasoningChunks.isEmpty {
            while let chunk = pendingReasoningChunks.popFirst() {
                streamingReasoning += chunk
            }
        }
        // 流式官方化：缓冲更新后同步直播槽（思考镜像 + 打字机目标）。
        syncLiveSlots()
    }

    private func flushIfIdle() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushTimer = nil
                self?.flushNow()
            }
        }
    }

    private func flushNow() {
        if !pendingTextChunks.isEmpty {
            while let chunk = pendingTextChunks.popFirst() {
                streamingText += chunk
            }
        }
        if !pendingReasoningChunks.isEmpty {
            while let chunk = pendingReasoningChunks.popFirst() {
                streamingReasoning += chunk
            }
        }
        // E2：缓冲的 shell 行统一落卡（0.2s 节流；§7.3）。
        if !pendingShellLines.isEmpty {
            let buffered = pendingShellLines
            pendingShellLines.removeAll()
            for (callId, lines) in buffered {
                for line in lines {
                    appendToCard(callId: callId, line: line)
                }
            }
        }
        // 流式官方化：回合尾/慢车道最终 flush 也同步直播槽——打字机目标必须
        // 在 reproject 的 settle 决策前拿到全文（否则补打目标缺尾部 delta，
        // 结算帧内容跳变）。原 View 层 onChange(streamingText) 同语义迁入。
        syncLiveSlots()
    }

    // MARK: - 流式官方化：直播槽 / 打字机 / settle（原 View 层换手状态机迁入）

    /// flush 后同步直播槽（快车道/慢车道/回合尾统一入口）：
    /// ①思考槽直接镜像缓冲（nil→非空时代际 +1，新 id = 入场动画天然一次）；
    /// ②正文槽由打字机驱动，本函数只更新数据侧全文 typeTarget（段间游标连续，
    /// 仅新目标短于游标时归零——九校④语义）并在补打中遇新 delta 时立即结算
    /// 上段（立即结算+新段开槽）。
    private func syncLiveSlots() {
        if !streamingReasoning.isEmpty {
            // 思考代际只随思考槽自身开合推进（P1-1：与正文槽分立，正文开槽
            // 不换思考 id——否则思考行 fadeUp 重播）。
            if liveReasoning == nil { liveReasoningGeneration += 1 }
            liveReasoning = streamingReasoning
        }
        // 空缓冲不清目标：reproject 清缓冲后的迟到 flush 定时器（textFlushTimer
        // 0.04s 单发可能落在 reproject 之后）不得打断补打（幽灵回合同源防护
        // ——空 flush 面对补打目标必须 no-op）。
        guard !streamingText.isEmpty, streamingText != typeTarget else { return }
        if isSettling { finishSettling() }
        typeTarget = streamingText
        typeCursor = Self.cursorAfterTargetChange(
            oldCursor: typeCursor, newTargetCount: typeTarget.count)
    }

    /// 节奏器启动（幂等；open 启动 / close 取消。Task 继承 @MainActor）。
    private func startTypewriterIfNeeded() {
        if let task = typewriterTask, !task.isCancelled { return }
        typewriterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard let self else { return }
                self.typewriterStep()
            }
        }
    }

    /// 打字机单步（原 View 层 typewriterLoop 循环体 1:1 迁移）：步长 =
    /// max(1, min(4, backlog/3))；全新长积压（>140 字）快进只打尾部。
    /// 补打打完即结算（finishSettling：落盘节点同帧显现，视觉无缝）。
    private func typewriterStep() {
        if typeCursor == 0, typeTarget.count > 140 {
            typeCursor = typeTarget.count - 140
        }
        guard typeCursor < typeTarget.count else {
            if isSettling { finishSettling() }
            return
        }
        let backlog = typeTarget.count - typeCursor
        let step = Self.typewriterStepLength(backlog: backlog)
        typeCursor = min(typeTarget.count, typeCursor + step)
        let prefix = String(typeTarget.prefix(typeCursor))
        if !prefix.isEmpty {
            // 正文代际只随正文槽自身开合推进（P1-1：与思考槽分立）。
            if liveText == nil { liveTextGeneration += 1 }
            liveText = prefix
        }
    }

    /// live 槽结算（reproject 末尾调用；替代原"清空 streamingText = 换手"）：
    /// 两槽均空 no-op；打字机有积压且回合未步进 → 补打期（displayNodes 过滤
    /// 补打目标落盘节点，live 槽继续打完）；否则槽直接置 nil（同帧落盘节点
    /// 显现）。批3 复审修 P1-2 语义保留（steppedForward）。
    private func settleLiveSlots() {
        let liveActive = liveReasoning != nil || liveText != nil || isSettling
        switch Self.settleDecision(
            liveActive: liveActive,
            cursorBacklog: typeCursor < typeTarget.count,
            steppedForward: Self.hasPostSettlingStepNode(in: bubbles)) {
        case .none:
            return
        case .finish:
            finishSettling()
        case .keepSettling:
            isSettling = true
            // review P1-2 修复：思考无打字积压概念——keepSettling（补打期）
            // 思考槽必须同步清退，否则落盘 reasoning 节点（补打过滤只滤
            // .assistant，reasoning 不过滤）与 live-r 槽（保持旧内容）同帧
            // 在场 = 同内容思考显示两遍（旧版 liveTailNode 思考部分挂载条件
            // `!streamingReasoning.isEmpty`，reproject 清空后即消失）。落盘
            // 思考即时呈现（同位同内容无缝，instantLive 覆盖动画面）；正文
            // 槽继续补打。finishSettling 另已清 reasoning（终态路径）。
            liveReasoning = nil
        }
    }

    /// 结算帧预登记集合（纯函数，单测直呼；review P2 补齐：最后落盘正文 +
    /// 同帧落盘思考——长积压补打超过 justEndedStreaming 1.5s 窗口时，思考
    /// 节点否则会播 fadeUp 重播）。
    nonisolated static func settledRegistrationIDs(
        in bubbles: [Bubble]) -> Set<String> {
        var ids = Set<String>()
        if let textID = bubbles.last(where: {
            if case .assistant = $0.kind { return true }
            return false
        })?.id {
            ids.insert(textID)
        }
        if let reasoningID = bubbles.last(where: {
            if case .reasoning = $0.kind { return true }
            return false
        })?.id {
            ids.insert(reasoningID)
        }
        return ids
    }

    /// 结算收口：落盘节点预登记（正文 + 同帧思考，不播入场动画——内容用户
    /// 刚在直播看过）+ 槽清退 + 打字机数据面重置。
    private func finishSettling() {
        settledBubbleIDs.formUnion(Self.settledRegistrationIDs(in: bubbles))
        isSettling = false
        liveReasoning = nil
        liveText = nil
        typeTarget = ""
        typeCursor = 0
    }

    /// View 渲染单一数据源（dsh conversation-nodes：流式 live 槽与落盘节点
    /// 同处一条节点流）。合成 = foldTurnProcess(bubbles) → 补打期过滤补打目标
    /// 落盘正文节点 → 尾部追加 live 槽（正式 Bubble 身份，id 双代际化）。
    var displayNodes: [ConversationProjector.DisplayNode] {
        Self.composeDisplayNodes(bubbles: bubbles, isSettling: isSettling,
                                 liveReasoning: liveReasoning, liveText: liveText,
                                 liveReasoningGeneration: liveReasoningGeneration,
                                 liveTextGeneration: liveTextGeneration)
    }

    /// settle 决策纯函数（单测直呼）：补打 = 有在途内容 + 打字机有积压 +
    /// 回合未步进。
    nonisolated static func settleDecision(liveActive: Bool, cursorBacklog: Bool,
                                           steppedForward: Bool) -> SettleDecision {
        guard liveActive else { return .none }
        if cursorBacklog, !steppedForward { return .keepSettling }
        return .finish
    }

    /// settle 决策产物（单测断言位）。
    enum SettleDecision: Equatable {
        /// 两槽均空：no-op（不打扰落盘面）。
        case none
        /// 直接结算（无积压或回合已步进）：槽置 nil，落盘节点同帧显现。
        case finish
        /// 进入/保持补打期：过滤补打目标落盘节点，live 槽继续打。
        case keepSettling
    }

    /// 打字机步长（纯函数，单测直呼；原 View 层 typewriterLoop 参数 1:1：
    /// 步长封顶 4 字——/3 指数收敛在大积压时唰完全文="整块"观感的第二机制，
    /// 恒速小步让长总结也有持续流式感）。
    nonisolated static func typewriterStepLength(backlog: Int) -> Int {
        max(1, min(4, backlog / 3))
    }

    /// 段间游标连续（纯函数，单测直呼；九校④：typeTarget 换源时 cursor 不
    /// 重置，仅新目标短于游标时归零）。
    nonisolated static func cursorAfterTargetChange(oldCursor: Int,
                                                    newTargetCount: Int) -> Int {
        newTargetCount < oldCursor ? 0 : oldCursor
    }

    /// displayNodes 合成（纯函数，单测直呼；双代际——P1-1：思考/正文 id
    /// 各自独立推进，互不波及）。
    nonisolated static func composeDisplayNodes(
        bubbles: [Bubble], isSettling: Bool, liveReasoning: String?,
        liveText: String?, liveReasoningGeneration: Int,
        liveTextGeneration: Int) -> [ConversationProjector.DisplayNode] {
        var nodes = ConversationProjector.foldTurnProcess(bubbles)
        if isSettling {
            // 补打目标 = 最后一条 .assistant 落盘正文（内容正由 live 槽补打，
            // 从渲染列表过滤，打完同帧结算——原 View 层 isSettlingAssistant 同语义）。
            let targetID = bubbles.last(where: {
                if case .assistant = $0.kind { return true }
                return false
            })?.id
            nodes = nodes.filter { node in
                if case .plain(let bubble) = node, case .assistant = bubble.kind {
                    return bubble.id != targetID
                }
                return true
            }
        }
        if let reasoning = liveReasoning {
            nodes.append(.plain(Bubble(id: "live-r-\(liveReasoningGeneration)",
                                       kind: .reasoning(reasoning))))
        }
        if let text = liveText, !text.isEmpty {
            nodes.append(.plain(Bubble(id: "live-t-\(liveTextGeneration)",
                                       kind: .assistant(text))))
        }
        return nodes
    }

    /// 【批3 复审修 P1-2】settling 期「回合已步进」判定（纯函数，单测直呼）：
    /// 最后一条 .assistant 落盘气泡之后是否已出现 goal_round 专卡或工具卡——
    /// 两者都是引擎下一步/续轮的落盘证据（出现在补打正文之后 = 卡片将悬在
    /// 直播正文上方）。turnUsage/note/user 不算步进（回合尾自身产物，不构成
    /// 插卡跳位形态；user 消息由乐观哨兵先上屏、投影替换同位，无跳变）。
    nonisolated static func hasPostSettlingStepNode(in bubbles: [Bubble]) -> Bool {
        guard let lastIndex = bubbles.lastIndex(where: { bubble in
            if case .assistant = bubble.kind { return true }
            return false
        }) else { return false }
        return bubbles.dropFirst(lastIndex + 1).contains { bubble in
            switch bubble.kind {
            case .goalRound, .tool:
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - M3 T1 交互呈现缝（SessionInteractionPresenter；dsh composer 接管 +
// 流内 toolview 行 + 侧栏琥珀点镜像，2026-07-23 / 2026-07-29 笔记）

extension ChatViewModel: SessionInteractionPresenter {
    func presentApproval(_ pending: PendingApprovalPresentation) {
        // 配对命令（dsh conversation.approval.detail 槽语义：按 callId 关联
        // 已流式呈现的工具卡，presentCall 复现命令文本，不重复 args JSON）。
        var commandDetail: String?
        if let callId = pending.callId, let entry = callArgs[callId],
           let intent = registry?.get(entry.name)?.presentCall(entry.args) {
            commandDetail = intent.detail
        }
        let enriched = PendingApprovalPresentation(
            id: pending.id, toolName: pending.toolName, callId: pending.callId,
            reason: pending.reason, commandDetail: commandDetail)
        pendingApprovals.append(enriched)
        if let callId = pending.callId {
            setCardStatus(callId: callId, note: "等待审批")
        }
        environment.notePendingInteraction(sessionId: sessionID, active: true)
    }

    func settleApproval(id: String, outcome: ApprovalOutcome) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let presentation = pendingApprovals.remove(at: index)
        approvalAnswering = false
        // 工具卡结算态（琥珀行；allowed-once 后工具继续执行，无琥珀行——
        // dsh：批准后工具卡回到 running 语义）。
        if let callId = presentation.callId {
            let note: String?
            switch outcome {
            case .allowedOnce: note = nil
            case .rejected: note = "未获批准"
            case .cancelled: note = "审批已取消"
            case .unavailable: note = "审批不可用（fail closed）"
            }
            setCardStatus(callId: callId, note: note)
        }
        refreshPendingInteractionMirror()
    }

    func presentQuestion(_ pending: PendingQuestionPresentation) {
        // T2.3 P0 第二道防线：同 id 重放副本替换不叠加（dsh 笔记 :19
        // "replaces replay duplicates"；根因修复在 UserQuestionService.ask
        // 的双重呈现——本防线防未来调用方回归）。
        pendingQuestions = PendingQuestionMirror.upsert(pendingQuestions, pending)
        environment.notePendingInteraction(sessionId: sessionID, active: true)
    }

    func settleQuestion(id: String, settlement: QuestionSettlement) {
        guard let index = pendingQuestions.firstIndex(where: { $0.id == id }) else { return }
        let presentation = pendingQuestions.remove(at: index)
        questionBusy = false
        // 工具卡结算态（与 AskUserTool.presentResult 的 N/M answered / cancelled /
        // interrupted 判定同规则——live 与 replay 同形）。
        if let callId = presentation.callId {
            let note: String?
            switch settlement {
            case .answered(let answer):
                let answeredIDs = Set(answer.answers.filter { item in
                    !item.selected.isEmpty || !(item.custom ?? "").isEmpty
                }.map(\.id))
                let answered = presentation.questions.filter { answeredIDs.contains($0.id) }.count
                note = "\(answered)/\(presentation.questions.count) 已回答"
            case .cancelled: note = "已取消"
            case .aborted: note = "已中断"
            }
            setCardStatus(callId: callId, note: note)
        }
        refreshPendingInteractionMirror()
    }

    /// 侧栏琥珀点镜像清退（最后一个待决交互结算时）。
    private func refreshPendingInteractionMirror() {
        if pendingApprovals.isEmpty && pendingQuestions.isEmpty {
            environment.notePendingInteraction(sessionId: sessionID, active: false)
        }
    }

    /// 工具卡琥珀状态行更新。
    private func setCardStatus(callId: String, note: String?) {
        for index in bubbles.indices {
            if case .tool(var card) = bubbles[index].kind, card.callId == callId {
                card.statusNote = note
                bubbles[index].kind = .tool(card)
                return
            }
        }
    }
}

// MARK: - M3 T1 用户裁决入口（composer 接管 → 宿主裁决登记处）

extension ChatViewModel {
    /// 审批裁决（允许一次 / 拒绝）。first answer wins 由协调器保证；本地防
    /// 双击，被拒（已结算/不存在）即 re-arm——dsh 笔记「disable locally,
    /// re-arm on failure」。P1-4：remember 沉淀出口随 F022 砍除。
    func answerApproval(_ pending: PendingApprovalPresentation, allow: Bool) {
        guard !approvalAnswering else { return }
        approvalAnswering = true
        let outcome: ApprovalOutcome = allow ? .allowedOnce : .rejected
        let coordinator = approvalCoordinator
        Task { [weak self] in
            let accepted = coordinator?.answer(requestId: pending.id,
                                               outcome: outcome) ?? false
            if !accepted {
                self?.approvalAnswering = false
            }
        }
    }

    /// 提交整组回答（draft 组装在视图层按 dsh submitDrafts 语义完成后回传）。
    func submitQuestionAnswer(_ pending: PendingQuestionPresentation,
                              answer: AskUserQuestionAnswer) {
        guard !questionBusy else { return }
        questionBusy = true
        let service = questionService
        Task { [weak self] in
            let accepted = service?.answer(requestId: pending.id, answer) ?? false
            if !accepted {
                self?.questionBusy = false
            }
        }
    }

    /// 关闭整组提问（dsh composer cancel → ASK_CANCELLED，中性结算态）。
    func cancelQuestion(_ pending: PendingQuestionPresentation) {
        guard !questionBusy else { return }
        questionBusy = true
        let service = questionService
        Task { [weak self] in
            let accepted = service?.dismiss(requestId: pending.id) ?? false
            if !accepted {
                self?.questionBusy = false
            }
        }
    }
}

// MARK: - M3 T2.2 A1 composer 路由（提问先于审批）

/// composer 座位路由（纯函数，单测断言位）。
enum ComposerSeatRoute: Equatable {
    case question
    case approval
    case input

    /// dsh 笔记 2026-07-23-web-permission-and-approval.md:19 原文
    /// 「presents the first pending question ahead of concurrent approvals to
    /// match composer routing」：提问（ui-user-questions）先于审批（
    /// ApprovalPanel）接管 composer——T2.2 A1（原 WanWo 审批优先为反序）。
    static func route(hasPendingQuestion: Bool,
                      hasPendingApproval: Bool) -> ComposerSeatRoute {
        if hasPendingQuestion { return .question }
        if hasPendingApproval { return .approval }
        return .input
    }
}
