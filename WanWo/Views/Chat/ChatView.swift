//
//  ChatView.swift
//  WanWo
//
//  【按设计新写 · M2 扩展】出处：10-design §7.1/§7.2（聊天流视图：消息卡片流 +
//  底部输入区 + 顶部状态条）、§7.3 交互流 1（工具卡展开流式输出（shell 卡 0.2s
//  节流）→ 完成态卡片收敛）、§7.6（token 压力状态条三档着色，F041 素净版）、
//  §7.4（视觉素净占位——正式卡片族 M9 对照 dsh Web UI）。
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel

    /// 命令菜单开合（C7；+ 按钮与 "/" 触发共用一菜单）。
    @State private var commandMenuOpen = false
    /// 本轮菜单是否由 "/" 触发（决定草稿离开 "/" 形态时是否收起）。
    @State private var slashTriggeredMenu = false
    /// composer 座位 + 状态条 dock 的合计高度（P1-5：菜单锚定与捕获层开洞
    /// 的度量——「composer chrome」区段）。
    @State private var composerChromeHeight: CGFloat = 0
    // MARK: F042 附件（composer 输入侧三入口）
    /// 相册选取器选集（PhotosPicker）。
    @State private var photoSelection: [PhotosPickerItem] = []
    /// 剪贴板 changeCount 基线（粘贴检测——不自动读取，用户点按「粘贴图片」
    /// 才触发系统粘贴确认，隐私模型最稳路径）。
    @State private var pasteboardBaseline = UIPasteboard.general.changeCount
    /// 待发送图原图预览（dsh ImageLightbox；rail 点击打开）。
    @State private var draftPreview: UIImage?

    init(environment: AppEnvironment, sessionID: String) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(environment: environment,
                                                             sessionID: sessionID))
    }

    var body: some View {
        // P1-5：菜单与捕获层上移根层全屏坐标系（原挂 composer 卡 .overlay
        // ——卡片 clipShape 连 hit-testing 一起裁，点卡外碰不到捕获层 =
        // 「点外关不掉」的根因）。
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // P2-⑩ 撤顶部旧 UI：原 statusBar（模型名 + 上下文 X/Y + 三档压力
                // 细条 + 阶段 ProgressView）整段移除——模型名归 composer 模型挡位
                // （ModelSelect.tsx 命名座位）、占用归 ContextMeter 环（one home
                // per fact）、发送/停止已随 T2.2 A5 移交主按钮同位状态机。
                content
                Divider()
                // M3 T1：composer 座位（审批/提问接管输入框，dsh composer 接管形态；
                // 高度上限共用 336px，座位高度稳定不跳动——2026-07-30 笔记）。
                // 状态条 dock（C8；StatsLine.tsx:1-3——挂 composer 之下不随流滚动；
                // P2-⑬ 单行呈现=StatsLineView lineLimit(1) 既有语义）。
                // P1-5：座位+dock 作为一个「chrome 块」度量（菜单锚定其上缘、
                // 捕获层在其区段开洞）。
                VStack(spacing: 0) {
                    composerSeat
                    if let line = viewModel.statsLine {
                        StatsLineView(line: line)
                    }
                }
                .background(composerChromeMeter)
            }
            // 捕获层（dsh MenuView.tsx:59-72 outside click）：全屏拦截、
            // composer chrome 区段开洞——卡内点击穿透到 composer（菜单保持，
            // dsh closest('[data-composer-card]') 内不关语义）。
            if commandMenuOpen {
                composerHoleCatcher
                    .transition(.opacity)
                    .zIndex(1)
            }
            // 菜单（dsh MenuView.tsx:25/:50/:77 MAX_HEIGHT 320 anchored popup）：
            // 锚定 composer 卡上缘向上生长、高度=min(内容,320)。
            if commandMenuOpen {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SlashMenuView(
                        query: commandMenuQuery,
                        commands: viewModel.slashCommandList,
                        onPick: { command in
                            // claim token 写回（dsh "/name " 带尾随空格）；先清 "/"
                            // 触发标记，防 onChange 又把菜单拉起。
                            slashTriggeredMenu = false
                            viewModel.draft = "/\(command.name) "
                            closeCommandMenu()
                        },
                        onDismiss: { closeCommandMenu() })
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, composerChromeHeight)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(2)
            }
        }
        .onPreferenceChange(ComposerChromeHeightKey.self) { composerChromeHeight = $0 }
        // 待发送图原图预览（F042；dsh ImageLightbox 形态）。
        .fullScreenCover(isPresented: Binding(get: { draftPreview != nil },
                                             set: { if !$0 { draftPreview = nil } })) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let draftPreview {
                    Image(uiImage: draftPreview)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                }
                Button {
                    draftPreview = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .padding(14)
                .accessibilityLabel("关闭原图预览")
            }
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.open() }
        // 会话切换/离场即释放写柄 + 取消在途回合（dsh SessionLifecycle open/dispose 配对）。
        .onDisappear { viewModel.close() }
        // A4：/permission danger-full-access 前置风险确认（dsh popupSelect
        // confirming gate；与入口①③共文案——当前会话挡 accessZh 变体）。
        // P2-⑫：呈现由 sheet 改居中模态（dsh RiskConfirmation 对话框形态）。
        // P1-6.1：去全屏遮罩——与 P1-6 两处同族（dsh RiskConfirmation 挂
        // PopupSelectView 无全屏遮罩，仅呈现居中确认卡）。
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

    // MARK: - P1-5 命令菜单锚定与捕获（dsh MenuView.tsx 语义）

    /// composer chrome 高度度量（座位 + dock）。
    private var composerChromeMeter: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ComposerChromeHeightKey.self,
                                   value: geo.size.height)
        }
    }

    private struct ComposerChromeHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// 全屏捕获层，底部 chrome 区段开洞（洞内点击穿透到 composer——菜单保持）。
    private var composerHoleCatcher: some View {
        GeometryReader { geo in
            let holeHeight = min(composerChromeHeight, geo.size.height)
            VStack(spacing: 0) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { closeCommandMenu() }
                Color.clear
                    .frame(height: holeHeight)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
    }

    private func closeCommandMenu() {
        withAnimation(.easeOut(duration: 0.12)) {
            commandMenuOpen = false
        }
        slashTriggeredMenu = false
    }

    // MARK: - 消息流

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let banner = viewModel.resumeBanner {
                        Text(banner)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(6)
                            .background(Color.yellow.opacity(0.12))
                            .cornerRadius(6)
                    }
                    ForEach(viewModel.bubbles) { bubble in
                        bubbleView(bubble).id(bubble.id)
                    }
                    if !viewModel.streamingReasoning.isEmpty {
                        // P2-⑬：流式思考走披露行（dsh ReasoningRow running 态——
                        // 折叠 + 尾行跟随）。
                        ReasoningRowView(text: viewModel.streamingReasoning,
                                         running: true)
                            .id("streaming-reasoning")
                    }
                    if !viewModel.streamingText.isEmpty {
                        Text(viewModel.streamingText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                            .id("streaming-text")
                    }
                    if case .failed(let message) = viewModel.phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.bubbles) { _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.streamingText) { _ in scrollToBottom(proxy) }
            // E2：只流思考（文本尚空）时同样跟随滚动。
            .onChange(of: viewModel.streamingReasoning) { _ in scrollToBottom(proxy) }
            // T2.6 件4（用户 #16）：消息流不参与键盘规避——键盘弹出时滚动
            // 区域不被压缩（对话不被挤没）；composer chrome 保持键盘安全位
            // （输入可用硬要求）。规避责任只在 composer 侧。
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    @ViewBuilder
    private func bubbleView(_ bubble: ChatViewModel.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text, let images):
            HStack {
                Spacer(minLength: 48)
                // F042：消息图片（dsh MessageImages/ImageGallery 形态——
                // 单图 singleFit、多图 64pt 方格；点开原图预览）。
                VStack(alignment: .trailing, spacing: 6) {
                    if !images.isEmpty {
                        MessageImagesView(images: images,
                                          store: viewModel.attachmentStore)
                    }
                    if !text.isEmpty {
                        Text(text)
                            .padding(10)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
            }
        case .assistant(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
        case .reasoning(let text):
            // P2-⑬：思考块披露行（dsh ReasoningRow 完成态——折叠 + 首行摘要，
            // 点击展开全文）。
            ReasoningRowView(text: text, running: false)
        case .tool(let card):
            ToolCardView(card: card)
        case .command(_, let text):
            Text("⌘ " + text)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .note(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - F042 附件（draft rail + intake 入口 helpers）

    /// 待发送图 rail（dsh ComposerAttachments/AttachmentRail 形态：64pt 缩略
    /// 图 + 移除钮 + 点击原图预览；remove 文案 image.remove「移除图片」）。
    private var draftImageRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.draftImages) { image in
                    draftImageThumb(image)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private func draftImageThumb(_ image: ChatViewModel.DraftImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let ui = UIImage(data: image.data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { draftPreview = UIImage(data: image.data) }
            Button {
                viewModel.removeDraftImage(id: image.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .offset(x: 5, y: -5)
            .accessibilityLabel("移除图片")
        }
    }

    /// 相册选取 intake（loadTransferable 读 Data；UTType → mediaType 白名单
    /// 映射——非白名单候选以 nil 类型进入预检，格式先行拒绝）。
    private func intakePhotoSelection(_ items: [PhotosPickerItem]) async {
        var candidates: [ChatViewModel.DraftImageCandidate] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            candidates.append(.init(data: data,
                                    mediaType: Self.mediaType(of: item.supportedContentTypes),
                                    name: nil))
        }
        viewModel.addDraftImages(candidates)
    }

    /// 拖放 intake（iPad 分屏拖入；loadDataRepresentation 读字节）。
    private func intakeDrop(_ providers: [NSItemProvider]) async {
        var candidates: [ChatViewModel.DraftImageCandidate] = []
        for provider in providers {
            let identifier = UTType.image.identifier
            guard let data = try? await Self.loadProviderData(
                provider, typeIdentifier: identifier) else { continue }
            let mediaType = provider.registeredContentTypes
                .compactMap { Self.mediaType(of: [$0]) }.first
            candidates.append(.init(data: data, mediaType: mediaType, name: nil))
        }
        viewModel.addDraftImages(candidates)
    }

    /// NSItemProvider completion → async 桥接（SDK 对该 API 的 async overlay
    /// 未生成——显式 continuation 确定性编译）。
    private static func loadProviderData(_ provider: NSItemProvider,
                                         typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: error ?? NSError(
                        domain: "WanWo.AttachmentIntake", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "拖拽数据读取失败"]))
                }
            }
        }
    }

    /// 剪贴板 intake（点按 chip 触发；读图后重编码 PNG + 基线推进）。
    private func pasteImagesFromPasteboard() {
        let board = UIPasteboard.general
        let candidates = (board.images ?? []).compactMap { ui -> ChatViewModel.DraftImageCandidate? in
            guard let data = ui.pngData() else { return nil }
            return .init(data: data, mediaType: .png, name: nil)
        }
        viewModel.addDraftImages(candidates)
        pasteboardBaseline = board.changeCount
    }

    /// UTType → 媒体类型白名单映射（dsh mediaTypes 白名单的 iOS 对应物）。
    nonisolated private static func mediaType(of types: [UTType]) -> ImageMediaType? {
        for type in types {
            if type.conforms(to: .png) { return .png }
            if type.conforms(to: .jpeg) { return .jpeg }
            if type.conforms(to: UTType("org.webpproject.webp") ?? .data) { return .webp }
            if type.conforms(to: .gif) { return .gif }
        }
        return nil
    }

    // MARK: - 工具卡（P2-⑬：折叠语义移交 ToolCardView；图标随之内聚）

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // E2：锚点跟随在流的尾部气泡（纯文本流 → streaming-text；纯思考流 →
        // streaming-reasoning；工具卡落位经 bubbles onChange 走同一入口）。
        let anchor: String = viewModel.streamingText.isEmpty
            ? "streaming-reasoning" : "streaming-text"
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(anchor, anchor: .bottom)
        }
    }

    // MARK: - composer 座位（M3 T1 接管路由；T2.2 A1 修正路由顺序——
    // dsh 笔记 2026-07-23-web-permission-and-approval.md:19 原文 "presents
    // the first pending question ahead of concurrent approvals to match
    // composer routing"：提问先于审批接管；原注释误引该句为审批优先依据）

    @ViewBuilder
    private var composerSeat: some View {
        switch ComposerSeatRoute.route(
            hasPendingQuestion: !viewModel.pendingQuestions.isEmpty,
            hasPendingApproval: !viewModel.pendingApprovals.isEmpty) {
        case .question:
            QuestionComposerView(pending: viewModel.pendingQuestions.first!,
                                 busy: viewModel.questionBusy,
                                 onSubmit: { answer in
                                     viewModel.submitQuestionAnswer(
                                        viewModel.pendingQuestions.first!, answer: answer)
                                 },
                                 onCancel: { viewModel.cancelQuestion(
                                    viewModel.pendingQuestions.first!) })
        case .approval:
            ApprovalPanelView(pending: viewModel.pendingApprovals.first!,
                              answering: viewModel.approvalAnswering) { allow in
                viewModel.answerApproval(viewModel.pendingApprovals.first!,
                                         allow: allow)
            }
        case .input:
            inputBar
        }
    }

    // MARK: - 输入区（T2.2：composer 卡形态——文本面 + 底部工具行）

    /// 占位文案（B12；dsh ui-conversation locales.ts zh 逐字：placeholder.default
    /// :16「发消息或做任务… / 调用指令 @ 文件或对话」/ placeholder.plan:15
    /// 「描述你的任务以生成计划」）。
    private var composerPlaceholder: String {
        viewModel.planActive
            ? "描述你的任务以生成计划"
            : "发消息或做任务… / 调用指令 @ 文件或对话"
    }

    /// 主按钮状态机（A5；dsh InputBar.tsx:313-326 primaryStops：running 且
    /// 无草稿 → 主按钮同位变停止；有草稿 → 发送）。
    private var primaryStops: Bool {
        ChatViewModel.primaryStops(running: viewModel.phase == .streaming,
                                   draftEmpty: viewModel.isDraftEmpty)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // 幽灵提示（C7；dsh InputBar.tsx:335-353 claim hint——仅 /plan 有
            // hint 词典，args 为空时显示）。
            if let hint = viewModel.commandHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            // 附件拒绝横幅（F042；intake 预检/提交失败文案——dsh showToast）。
            if let banner = viewModel.attachmentBanner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            // 文本面（占位文案随 plan 态切换——B12）。
            TextField(composerPlaceholder, text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            // 待发送图片 rail（F042；dsh ComposerAttachments/AttachmentRail
            // 形态——64pt 缩略图 + 移除钮 + 点看原图）。
            if !viewModel.draftImages.isEmpty {
                draftImageRail
            }
            // 底部工具行（dsh InputBar css.row：tools 左 / trailing 右）。
            HStack(spacing: 8) {
                // + 按钮 = 打开命令菜单（C7；InputBar.tsx:441-454——非附件）。
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        commandMenuOpen.toggle()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("指令")
                // 添加图片（F042；PhotosPicker——相册/文件两源，intake 预检
                // 整批拒绝）。
                PhotosPicker(selection: $photoSelection,
                             maxSelectionCount: 20,
                             matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.draftImages.isEmpty
                          && viewModel.draftImages.count >= 20)
                .accessibilityLabel("添加图片")
                .onChange(of: photoSelection) { items in
                    let picked = items
                    photoSelection = []
                    Task { await intakePhotoSelection(picked) }
                }
                // 粘贴图片 chip（F042 呈报形态：剪贴板有图且未消费时显示——
                // 用户点按才读取，系统粘贴确认在用户手势下触发）。
                if UIPasteboard.general.hasImages
                    && UIPasteboard.general.changeCount != pasteboardBaseline {
                    Button {
                        pasteImagesFromPasteboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("粘贴图片")
                }
                // 权限挡位下拉（A3；PermissionSelect.tsx——提交走 /permission
                // 命令同一写通路径；confirmed = 下拉内确认已过，双弹修复）。
                if let permission = viewModel.currentPermissionPreset {
                    PermissionSelectView(
                        currentPreset: permission,
                        busy: viewModel.isCommandRunning,
                        onCommand: { line, confirmed in
                            viewModel.runCommandLine(line, confirmed: confirmed)
                        })
                }
                // Plan chip（C10；PlanModeControl.tsx:19-69——plan 生效时渲染，
                // 点击执行 /plan off）。
                if viewModel.planActive {
                    Button {
                        viewModel.runCommandLine("/plan off")
                    } label: {
                        HStack(spacing: 4) {
                            Text("Plan")
                                .font(.footnote.weight(.medium))
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("plan mode 已开启，按下关闭")
                }
                Spacer()
                // 模型挡位（C11；ModelSelect.tsx——两级菜单 Model/Effort；
                // T2.4 P1-3：会话级选择——current/effort 为 VM published 镜像）。
                ModelSelectView(store: viewModel.endpointStore,
                                current: viewModel.currentModelEndpoint,
                                currentEffort: viewModel.sessionEffort,
                                onSelect: { viewModel.selectModel($0) },
                                onEffort: { viewModel.selectEffort($0) })
                // 上下文占用环（C9；ContextMeter.tsx:106-165——无数据不渲染）。
                if let pressure = viewModel.pressure {
                    ContextMeterView(pressure: pressure)
                }
                // 主按钮（A5：发送/停止同位切换；dsh :313-326）。
                Button {
                    if primaryStops {
                        viewModel.cancel()
                    } else {
                        viewModel.send()
                    }
                } label: {
                    Image(systemName: primaryStops ? "stop.fill" : "paperplane.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(primaryStops
                          ? false
                          : !viewModel.canSend || viewModel.isDraftEmpty)
                .accessibilityLabel(primaryStops ? "停止生成" : "发送消息")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // 拖放图片（F042；dsh drop 对应物——iPad 分屏拖入；intake 同一径）。
        .onDrop(of: [UTType.image], isTargeted: nil) { providers in
            guard viewModel.attachmentStore != nil else { return false }
            Task { await intakeDrop(providers) }
            return true
        }
        // P1-5：菜单与捕获层已上移根层 ZStack（原卡上 .overlay 被 clipShape
        // 裁剪 hit-testing——点外关不掉的根因，见 body 注）。
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 手输 "/" 自动开菜单并过滤（MenuView combobox 语义）；离开 "/" 形态
        // 且菜单由 "/" 触发时收起（"+" 直开的菜单不受草稿影响）。
        .onChange(of: viewModel.draft) { newValue in
            if newValue.hasPrefix("/") {
                withAnimation(.easeOut(duration: 0.12)) {
                    commandMenuOpen = true
                }
                slashTriggeredMenu = true
            } else if slashTriggeredMenu {
                commandMenuOpen = false
                slashTriggeredMenu = false
            }
        }
    }

    /// 菜单过滤词（草稿以 "/" 开头时 = 当前草稿；"+" 打开时 = 全列）。
    private var commandMenuQuery: String {
        viewModel.draft.hasPrefix("/") ? viewModel.draft : ""
    }
}

extension ChatViewModel {
    /// 状态条「停止」按钮的显示条件（流式进行中；T2.2 A5 后保留供诊断用）。
    var isBusy: Bool { phase == .streaming }
}

// MARK: - P2-⑬ 工具卡折叠视图

/// 工具卡（dsh toolview 折叠语义 1:1 形态）：行头与交互琥珀行恒显；
/// detail / 流式输出 / 结果文本仅在展开态呈现。默认态 = 运行中展开、
/// 结束后收起（dsh：完成即收敛，点击行头可再展开回看）。
private struct ToolCardView: View {
    let card: ChatViewModel.ToolCard

    /// 展开态（初值随卡片在途性：running 展开、完成收起；用户手动切换后保留）。
    @State private var expanded: Bool

    init(card: ChatViewModel.ToolCard) {
        self.card = card
        _expanded = State(initialValue: card.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 行头（恒显；点击切换折叠——dsh toolview 行头 chevron 语义）。
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: card.name))
                        .font(.caption)
                        .foregroundStyle(card.isRunning ? Color.accentColor
                                                        : (card.isError ? Color.red : Color.secondary))
                    Text(card.title)
                        .font(.footnote.monospaced())
                        .lineLimit(2)
                    Spacer()
                    if card.isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: card.isError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(card.isError ? Color.red : Color.green)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 参数摘要（展开态）。
            if expanded, let detail = card.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            // 交互状态行（M3 T1：审批 waiting/结算态、提问等待——琥珀语义行；
            // 交互态恒显，不随折叠消失）。
            if let status = card.statusNote, !status.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ApprovalPanelStyle.warnPrimary)
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(ApprovalPanelStyle.warnPrimary)
                }
            }
            // 流式输出（展开态）。
            if expanded, !card.liveOutput.isEmpty {
                Text(card.liveOutput)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: 180, alignment: .topLeading)
                    .padding(6)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)
            }
            // 结果文本（展开态）。
            if expanded, let result = card.resultText, !result.isEmpty {
                Text(result)
                    .font(.caption2.monospaced())
                    .foregroundStyle(card.isError ? Color.red : Color.secondary)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(6)
                    .background(Color(.tertiarySystemBackground))
                    .cornerRadius(6)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }

    private func iconName(for tool: String) -> String {
        switch tool {
        case "bash": return "terminal"
        case "read", "read_image", "write", "edit", "str_replace_editor":
            return "doc.text"
        case "glob", "grep": return "magnifyingglass"
        case "web_search", "web_fetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - A4 Full access 前置确认面（/permission danger-full-access 命令门控）

/// /permission danger-full-access 的确认卡片（dsh popupSelect confirming gate；
/// 文案 = 当前会话挡 accessZh 变体——ui-permission-presets locales.ts:43-47）。
struct PermissionConfirmationGate: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var acknowledged = false

    var body: some View {
        RiskConfirmationView(
            title: "确认启用完全权限？",
            description: "启用完全权限后，智能体将减少确认步骤，并且可以直接执行更多操作，"
                + "包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。",
            acknowledgeLabel: "我已了解风险，并愿意继续",
            cancelLabel: "取消",
            confirmLabel: "启用完全权限",
            acknowledged: $acknowledged,
            onCancel: onCancel,
            onConfirm: onConfirm)
    }
}

// （原 presentationDetentsIfAvailable 降级包裹随 P2-⑫ 居中模态化移除——
// detents 是 sheet 语义，fullScreenCover 下无意义。）
