//
//  WONodeContent.swift
//  WanWo
//
//  【批 1 · 件 1】节点内容装配——从 WOChatView 原样迁移的渲染链（视觉零变化）：
//    entryNode/entryBubble/bubbleView/userBubble → WONodeItemContent/WONodeBubbleView；
//    chatMarkdownConfig static 迁入本件。
//  变化点（机制层，非视觉）：
//    · animatedIDs/pendingUserSeen（原 WOChatView @State）→ WOEntryLedger
//      （@MainActor 引用型账本，归 UIKit 列表 core 持有——cell 复用/重建
//      不再丢 seen 门，等价原 LazyVStack 语义）；
//    · settled（落盘非流式）助手正文 → WOCachedMarkdown（批 1 件 4：NSCache
//      文档直喂，滚回秒出）；live 槽正文保持 MarkdownView(text:)（流式红线：
//      块级 diff 原地更新语义不动）；
//    · phase/settledBubbleIDs 等以 WONodeContext 值快照传入（core 每次 sync
//      从 viewModel 重建），渲染代码不再直连 ObservableObject。
//

import SwiftUI
import SwiftStreamingMarkdown

// MARK: - 入场账本（原 WOChatView @State animatedIDs/entrySeeded/pendingUserSeen）

/// 单例生命周期 = 一次列表 core 装配（会话切换 core reset 时重建）。
/// 纪律：账本只增 seen（一次性门）；补种走 seedAll（幂等 formUnion）。
@MainActor
final class WOEntryLedger {
    /// 已播过/已豁免入场动画的节点 id（原 animatedIDs）。
    private(set) var seenIDs: Set<String> = []
    /// 用户消息哨兵交接旗（原 pendingUserSeen）——"u-pending"（乐观 mInR）
    /// 被 "u(seq)"（落盘投影）替换时后者即时呈现不重播；onSeen 归位。
    var pendingUserSeen = false
    /// 历史种子位（原 entrySeeded）：open 完成后的首投影不播入场。
    private(set) var seeded = false

    /// 入场完成登记（原 WOEntryModifier.onSeen 闭包体）。
    /// kindTag == "user" 时交接哨兵旗：seen 的是 u-pending → 置真；
    /// 之后的落盘 user 节点 → 归位假（下一轮乐观气泡照常入场）。
    func markSeen(_ id: String, kindTag: String) {
        seenIDs.insert(id)
        if kindTag == "user" { pendingUserSeen = (id == "u-pending") }
    }

    /// 补种（原 seedEntry 的 animatedIDs.formUnion 与回合边界补种）。
    func seedAll(_ ids: some Sequence<String>) {
        seenIDs.formUnion(ids)
    }

    func markSeeded() { seeded = true }

    /// 会话切换全量重置（core reset）。
    func reset() {
        seenIDs = []
        pendingUserSeen = false
        seeded = false
    }
}

// MARK: - 节点上下文（core 每次 sync 从 viewModel 重建的值快照）

struct WONodeContext {
    let phase: ChatViewModel.Phase
    let justEndedStreaming: Bool
    let settledBubbleIDs: Set<String>
    let sessionId: String
    /// 附件存储缝（MessageImagesView 图片源；open() 装配后非 nil）。
    let attachmentStore: AttachmentStore?
    /// 入场账本（引用型——onSeen 写面跨 cell 生命周期共享）。
    let ledger: WOEntryLedger
    /// 消息气泡图片原图预览回调（原 messagePreview @State binding 的闭包形）。
    let onImagePreview: (ImageAttachmentRef) -> Void
    /// 【CI修49 拍板②】本帧新插入的行 id（sync 插入检测；仅插入帧非空，
    /// 每帧重建 context 自动清空）——这些行的 SwiftUI 入场动画豁免
    /// （non-user），入场视觉全权交给 UIKit 插入动画（周围 cell 平移
    /// "推开" + 新 cell 淡入**同时**——用户裁决的同出形态；旧 fadeUp
    /// "先上移占位再出现"的两步观感退役）。
    let freshlyInsertedIDs: Set<String>

    init(phase: ChatViewModel.Phase,
         justEndedStreaming: Bool,
         settledBubbleIDs: Set<String>,
         sessionId: String,
         attachmentStore: AttachmentStore?,
         ledger: WOEntryLedger,
         onImagePreview: @escaping (ImageAttachmentRef) -> Void,
         freshlyInsertedIDs: Set<String> = []) {
        self.phase = phase
        self.justEndedStreaming = justEndedStreaming
        self.settledBubbleIDs = settledBubbleIDs
        self.sessionId = sessionId
        self.attachmentStore = attachmentStore
        self.ledger = ledger
        self.onImagePreview = onImagePreview
        self.freshlyInsertedIDs = freshlyInsertedIDs
    }
}

// MARK: - 内容高度上报桥（CI修48：SwiftUI 异步高度 → UIKit 列表回传）

/// PreferenceKey 载体（单 cell 子树仅一个 reporter，dict 单 key 无归并冲突）。
private struct WOContentHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat],
                       nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// 内容实测高度上报（background GeometryReader 不影响布局；值变即回传）。
/// 治：Markdown task 异步解析完成、图片异步加载完成、折叠组件展开等
/// "高度事后变化"——显示 cell 实测高度 → core 更新池缓存 + invalidateLayout。
/// 离屏量高 host（未挂窗）不触发渲染循环，此桥恒静默（安全面）。
struct WOHeightReporting: ViewModifier {
    let id: String
    let onChange: (String, CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: WOContentHeightKey.self,
                                           value: [id: geo.size.height])
                }
            )
            .onPreferenceChange(WOContentHeightKey.self) { values in
                for (key, height) in values where height > 0 {
                    onChange(key, height)
                }
            }
    }
}

// MARK: - 条目内容（列表 cell 的 SwiftUI 面：气泡 + 四类元条目）

struct WONodeItemContent: View {
    let node: WOMListNode
    let context: WONodeContext

    var body: some View {
        switch node.kind {
        case .bubble(let bubble):
            WONodeBubbleView(bubble: bubble, context: context)
        case .history(let loading):
            historyHeader(loading: loading)
        case .loading:
            // 原 messageList :851-858 装配 spinner（形态原样）。
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.top, 48)
        case .beam:
            // 原 :875-882 流光换字状态行（形态原样）。
            // 【CI修49】左对齐：根视图=内容尺寸，hosting 内默认居中
            // （旧链 LazyVStack 行容器 leading 语义的等价补偿）。
            WOBeamSwapper()
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            // 原 :883-891 错误横幅（形态原样）。
            // 【CI修49】fixedSize(vertical:)：Text 拒绝高度压缩（量高/回传
            // 闭环的不可压缩前提——可压缩 Text 被 proposal 截断后回传量到
            // 被压值，死区吞掉 → 永久截断）。
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(WOAlias.stateErrorPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(WOAlias.stateErrorSecondary))
        }
    }

    /// 批 1 件 3：「载入更早」列表头（lody ChatHistoryHeader 语义的万我形态
    /// ——新元素，无既有视觉包袱；量高切片进行中 = spinner）。
    private func historyHeader(loading: Bool) -> some View {
        HStack(spacing: 6) {
            if loading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(loading ? "正在载入更早消息…" : "查看更早消息")
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }
}

// MARK: - 单气泡（entryBubble/bubbleView/userBubble 原样迁移）

struct WONodeBubbleView: View {
    let bubble: ConversationProjector.Bubble
    let context: WONodeContext

    /// 批12+联动（2026-09-26）：聊天 Markdown 配置（原 WOChatView private
    /// static 1:1 迁入——settled 正文与流式直播共用）。
    static let chatMarkdownConfig: MarkdownRenderConfig = {
        let inline = MarkdownRenderConfig.default.inlineStyle
        return MarkdownRenderConfig.default
            .withShouldAnimateText(value: true)
            .withInlineStyle(value: .init(
                boldTextColor: inline.boldTextColor,
                linkTextFont: inline.linkTextFont,
                linkTextColor: WOAlias.stateBusinessPrimary,
                linkUnderlineStyle: [.single],
                codeTextFont: inline.codeTextFont,
                codeTextColor: inline.codeTextColor,
                codeBackgroundColor: inline.codeBackgroundColor,
                codeUnderlineColor: inline.codeUnderlineColor))
    }()

    /// 批 1 遗留清偿（滚回淡入观察预案）：WOCachedMarkdown 直喂 DocumentView
    /// 路径的 config 分叉开关——真机若见滚动回看重淡入（shouldAnimateText 在
    /// DocumentView 首挂载重放），翻转本位即切 settled 静态直出，不需新批次。
    /// 默认 false（与 live 同 config = 视觉零变化基线）。
    static var settledDisableTextAnimation = false

    /// settled 正文渲染 config（分叉缝；live 槽恒用 chatMarkdownConfig）。
    static var settledMarkdownConfig: MarkdownRenderConfig {
        settledDisableTextAnimation
            ? chatMarkdownConfig.withShouldAnimateText(value: false)
            : chatMarkdownConfig
    }

    var body: some View {
        entryBubble
    }

    // MARK: 入场决策（原 entryBubble 逐行迁移；状态源换 context/ledger）

    private var entryBubble: some View {
        // 批12+回归五校（用户令）：思考/工具节点=fadeUp（.4s 自下 8px+淡入）；
        // 过程组不再整块动画——组内节点逐个走入场门；消息保持 mInL/mInR。
        // seen = ledger.seenIDs ∪ settledBubbleIDs——结算帧落盘节点由 VM 预登记
        // （内容用户刚在直播看过，即时呈现不播动画）。
        let isLive = bubble.id.hasPrefix("live-")
        let seen = context.ledger.seenIDs.contains(bubble.id)
            || context.settledBubbleIDs.contains(bubble.id)
        let kindTag: String = {
            switch bubble.kind {
            case .user: return "user"
            case .assistant: return "assistant"
            case .reasoning: return "reasoning"
            case .tool: return "tool"
            case .goalRound: return "goalRound"
            default: return "other"
            }
        }()
        // 批12+回归九校：思考落盘改 instant——动画已前移到直播思考行出现
        // 时刻；正文保持 instant（同理由）。
        // 批12+回归九校-B：justEndedStreaming——onTurnEnd 里 reproject 与
        // phase=.idle 同帧，单看 phase 会漏判，旗标补上跨帧语义。
        // live 节点（live-r-N/live-t-N）不参与 instantLive——直播段落的
        // fadeUp 正是它的入场（generation id 天然一次性）。
        let instantLive = !isLive
            && (context.phase == .streaming || context.justEndedStreaming)
            && (kindTag == "assistant" || kindTag == "reasoning")
        // live 节点强制 fadeUp（原 liveTailNode 的 WOEntryModifier 参数原样）。
        let fadeUp = isLive || kindTag == "tool" || kindTag == "reasoning"
            || kindTag == "goalRound"
        let fromRight = kindTag == "user"
        // 批12+回归八校：用户消息哨兵交接——落盘投影（非哨兵）在乐观入场后
        // 即时呈现不重播；onSeen 归位旗标。
        // 【CI修49 拍板②】插入帧豁免（non-user）：本帧新插入行的入场交给
        // UIKit 插入动画（推开+淡入同出）；user 行保留 mInR（原型语义）。
        let fresh = context.freshlyInsertedIDs.contains(bubble.id) && kindTag != "user"
        let animate = !seen && !instantLive && !fresh
            && !(kindTag == "user" && context.ledger.pendingUserSeen
                 && bubble.id != "u-pending")
        let branch = animate ? (fadeUp ? "fadeUp" : (fromRight ? "mInR" : "mInL")) : "instant"
        let offset: CGSize = fadeUp ? CGSize(width: 0, height: 8)
            : CGSize(width: fromRight ? 16 : -16, height: 0)
        let scale: CGFloat = fadeUp ? 1 : 0.95
        let duration: Double = fadeUp ? 0.4 : 0.55
        // 批12+回归八校（点4 手术）：同批落盘的思考（delay 0）与工具
        // （delay 0.3s）错峰。
        let entryDelay: Double = fadeUp && kindTag == "tool" ? 0.3 : 0
        return bubbleView
            .modifier(WOEntryModifier(
                offset: offset,
                scale: scale,
                duration: duration,
                delay: entryDelay,
                animate: animate,
                diag: seen ? nil : "entry id=\(bubble.id) kind=\(kindTag) branch=\(branch) phase=\(String(describing: context.phase))",
                onSeen: {
                    context.ledger.markSeen(bubble.id, kindTag: kindTag)
                }))
    }

    // MARK: 单气泡渲染（原 bubbleView 逐 case 迁移）

    @ViewBuilder
    private var bubbleView: some View {
        switch bubble.kind {
        case .user(let text, let images):
            userBubble(text: text, images: images)

        case .goalRound(let text):
            HStack(alignment: .center, spacing: 0) {
                WOGoalRoundCard(text: text)
                    .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 0)
            }

        case .assistant(let text):
            // 助手行：渐变头像 + 正文。
            // 【批1 件4】settled（落盘非流式）正文 → WOCachedMarkdown（NSCache
            // 文档直喂，滚回秒出）；live 槽（live-t-N）保持 MarkdownView(text:)
            // （块级 diff 原地更新流式语义红线不动）。两者同一 BlockView 渲染
            // 管线（DocumentView 与 MarkdownView body 同源）——视觉零变化。
            let segments = WOChatView.splitAgentSegments(text)
            let isLive = bubble.id.hasPrefix("live-")
            HStack(alignment: .top, spacing: 8) {
                WOAssistantAvatar()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        if !segment.text.isEmpty {
                            if isLive {
                                MarkdownView(text: WOChatView.autolinkBareURLs(segment.text),
                                             config: Self.chatMarkdownConfig)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                WOCachedMarkdown(text: WOChatView.autolinkBareURLs(segment.text),
                                                 config: Self.settledMarkdownConfig)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let url = segment.image {
                            WOInlineAgentImage(
                                url: url,
                                sessionID: context.sessionId.isEmpty ? nil : context.sessionId)
                        }
                    }
                }
            }
            .padding(.top, 1)

        case .reasoning(let text):
            // 思考披露：live 槽（live-r-N）= running 态；落盘 = settled。
            ReasoningDisclosure(text: text,
                                running: bubble.id.hasPrefix("live-r-"))

        case .tool(let card):
            WOToolCard(card: card,
                       sessionID: context.sessionId.isEmpty ? nil : context.sessionId)

        case .command(let kind, let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(kind)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(WOAlias.bgModulePlatform))

        case .note(let text):
            // 【CI修49】fixedSize(vertical:)：变更纸条等多行文本被 cell
            // proposal 截断成"…"（可压缩 Text 回传死区）的根治——拒绝高度
            // 压缩后 GeometryReader 量到理想高，回传修正闭环自愈。
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .turnUsage(let summary):
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

    /// 用户气泡（原 userBubble 主体原样迁移）。
    private func userBubble(text: String, images: [ImageAttachmentRef]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    MessageImagesView(images: images,
                                      store: context.attachmentStore,
                                      onPreview: { context.onImagePreview($0) })
                }
                if !text.isEmpty {
                    // 纯图片消息不画气泡（dsh MessageItem 语义）。
                    Text(text)
                        .font(.system(size: 14))
                        .foregroundColor(WOAlias.labelPrimary)
                        .multilineTextAlignment(.trailing)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
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
    }
}
