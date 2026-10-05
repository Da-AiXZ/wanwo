//
//  WONodeContent.swift
//  WanWo
//
//  【重做批 2 · 组件装配缝】节点渲染装配——从 WOChatView 原样迁移的渲染链
//  （视觉零变化；方案 analysis/chat-rework-plan-20261006.md 批 2）。
//    · WOChatView.bubbleView/userBubble → WONodeBubbleView（switch kind 逐字
//      保持，viewModel.attachmentStore/sessionId/messagePreview 以
//      WONodeContext 值快照注入——渲染代码不再直连 ObservableObject）；
//    · chatMarkdownConfig/AgentSegment/splitAgentSegments/autolinkBareURLs
//      static 工具迁入本件（全仓使用点仅在渲染链内，grep 实证）；
//    · WODisclosureRow/WOThinkIcon/ReasoningDisclosure 迁入本件（原 private
//      放宽 internal——WOToolCards.swift:94 既有跨文件引用语义不变）。
//  动画语义（entryBubble/entryNode/WOEntryModifier/入场账本）**留在
//  WOChatView**——本件只承载纯渲染结构；账本/高度回传桥/元条目装配随
//  批 3/4 引擎内核接入（见方案批次表）。
//

import SwiftUI
import SwiftStreamingMarkdown

// MARK: - 节点渲染上下文（装配缝值快照）

/// 渲染所需的宿主状态快照。批 2 最小集（宿主身份/附件存储/图片预览回调）；
/// 批 4 引擎接入时按 tag WONodeContext 扩展 phase/settledBubbleIDs 等
/// 引擎消费字段（struct 加属性+init 默认值，破坏面为零）。
struct WONodeContext {
    let sessionId: String
    /// 附件存储缝（MessageImagesView 图片源；open() 装配后非 nil）。
    let attachmentStore: AttachmentStore?
    /// 消息气泡图片原图预览回调（原 messagePreview @State binding 的闭包形
    /// ——lightbox 状态仍在 WOChatView 宿主层）。
    let onImagePreview: (ImageAttachmentRef) -> Void
}

// MARK: - 单气泡渲染（全事件类型可见；原 WOChatView.bubbleView/userBubble 原样迁移）

struct WONodeBubbleView: View {
    let bubble: ConversationProjector.Bubble
    let context: WONodeContext

    /// 批12+联动（2026-09-26）：聊天 Markdown 配置（settled 正文与流式直播
    /// 共用）。①链接可辨识——库默认 linkTextAttributes 置空
    /// （ParagraphUIView:200）=链接与正文同款不可辨识，经 withInlineStyle
    /// 显式染主题蓝+下划线（点击链路库内置 onUrlTap→UIApplication.open，
    /// wanwo:// 深链本就可用）；②shouldAnimateText=true（三校：逐字淡入，
    /// 官方 Demo 同款）。
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

    /// 【P2-1c 修5 2026-09-28】保序切分：正文按 wanwo:// 图片出现位置切段
    /// ——每段文本 + 段尾可选图片，渲染时图片**跟随 AI 叙述位置**（"图1：
    /// …图1"紧邻呈现），不再抽取堆消息尾部（旧 splitAgentImages 设计、用户
    /// 两轮实证排版不可接受）。库 ImageConfig 三源不支持自定义 scheme
    ///（ImageConfig+SourceResolution `case .some → nil` 实证，SPM 远程依赖
    /// 不可 fork）→ 图片走原生视图插段。连续图片产生空文本段（跳过渲染）。
    struct AgentSegment: Identifiable {
        let id: Int
        let text: String
        let image: URL?
    }

    private static let agentImageRegex = try? NSRegularExpression(
        pattern: "!\\[[^\\]]*\\]\\((wanwo://[^)\\s]+)\\)")

    static func splitAgentSegments(_ text: String) -> [AgentSegment] {
        guard let regex = agentImageRegex, !text.isEmpty else {
            return text.isEmpty ? [] : [AgentSegment(id: 0, text: text, image: nil)]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text,
                                    range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return [AgentSegment(id: 0, text: text, image: nil)]
        }
        var segments: [AgentSegment] = []
        var cursor = 0
        for (index, m) in matches.enumerated() {
            let head = ns.substring(with: NSRange(location: cursor,
                                                  length: m.range.location - cursor))
            let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHead.isEmpty || index == 0 {
                segments.append(AgentSegment(id: segments.count, text: head, image: nil))
            }
            if let url = URL(string: ns.substring(with: m.range(at: 1))) {
                segments.append(AgentSegment(id: segments.count, text: "", image: url))
            }
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor)
        let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTail.isEmpty {
            segments.append(AgentSegment(id: segments.count, text: tail, image: nil))
        }
        return segments
    }

    /// 批12+联动B：裸 URL autolink——库 parser 不识别裸 URL（无 .link 属性
    /// =不可点、无链接样式，用户实测"选中才能 Open Link"根因），预处理包成
    /// markdown 链接（chatMarkdownConfig 染色可辨）。
    /// 已在 markdown 链接/图片目标位内的 URL 跳过（前置 `(` `"` `=` `[` 判定，
    /// 等价原 lookbehind 语义）。
    /// 【闪退修复 2026-09-27】原 NSRegularExpression lookbehind 实现渲染首个
    /// 气泡即 ObjC 异常 abort（.ips lastExceptionBacktrace 实证本函数帧）
    /// —— Foundation ICU 路径整体弃用，改纯 Swift 手工扫描（无异常面）：
    /// 逐字符扫，遇协议头判前置字符 → 扫到空白/markdown 结构字符为止 →
    /// 包 `[url](url)`，指针跳过 URL 本体。
    static func autolinkBareURLs(_ text: String) -> String {
        let markers = ["https://", "wanwo://"]
        // 【批2 修复 2026-09-27】反引号必须同时是 URL 边界与 code-span 排除位：
        // AI 常以 `wanwo://…`（inline code）输出链接——此前反引号不在两张表里，
        // 导致 ①code span 内的 URL 也被包链 ②URL 吃进闭合反引号使原 code span
        // 未闭合延伸到行尾，整行按纯代码渲染（用户截图 IMG_2463 棕色 [..](..) 字样）。
        let stopChars = Set(" \t\n\r<>()\\[]\"'`")
        let blockPrev = Set("(\"=[`")
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let remaining = text[index...]
            if let marker = markers.first(where: { remaining.hasPrefix($0) }) {
                let prevOK: Bool
                if index == text.startIndex {
                    prevOK = true
                } else {
                    let prev = text[text.index(before: index)]
                    prevOK = !blockPrev.contains(prev)
                }
                var end = index
                while end < text.endIndex, !stopChars.contains(text[end]) {
                    end = text.index(after: end)
                }
                let url = String(text[index..<end])
                if prevOK, url.count > marker.count {
                    out += "[\(url)](\(url))"
                } else {
                    out += url
                }
                index = end
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    var body: some View {
        switch bubble.kind {
        case .user(let text, let images):
            // 【批3 A1】goal_round 拦截分支移除——投影器已将注入文本特判为
            // `.goalRound` 专卡（乐观路径同时被 marker 拦截，双卡不再可
            // 能）；user case 回归纯用户消息渲染。
            userBubble(text: text, images: images)

        case .goalRound(let text):
            // 【批3 A1】goal_round 续轮指令专卡（WOGoalRoundCard 形态保持
            // 不变——E3 战场只引用不改；收敛渲染 = 乐观/落盘/结算三态同
            // 一身份 gr(seq)，无整树刷新）。
            HStack(alignment: .center, spacing: 0) {
                WOGoalRoundCard(text: text)
                    .frame(maxWidth: 620, alignment: .leading)
                Spacer(minLength: 0)
            }

        case .assistant(let text):
            // 助手行：渐变头像 + 正文（digest-H Bot 行形态；13px 时间戳因
            // 引擎气泡无墙钟字段缺席，登记报告）。
            // 批12 T7：正文换 MarkdownView（SwiftStreamingMarkdown——标题/
            // 列表/代码块/表格可渲染）。库自带 textSelection 配置——外层
            // .textSelection 去掉避免双选区行为。
            // 批12+联动（2026-09-26）：①config=chatMarkdownConfig（链接染色
            // 可辨识——库默认 linkTextAttributes 置空=链接与正文同款）②正文
            // 预处理提取 wanwo:// 截图（库 ImageConfig 三源均不支持自定义
            // scheme 且默认 disabled）→ 气泡下方图片条渲染。
            // 【P2-1c 修5】保序切分：图片跟随 AI 叙述位置原位插段（旧设计
            // 抽取堆消息尾部，用户两轮实证排版不可接受）；图片视图点击 →
            // 集中预览通道（sessionID 显式锚，不依赖挂载时序——P2-1b 语义）。
            let segments = Self.splitAgentSegments(text)
            HStack(alignment: .top, spacing: 8) {
                WOAssistantAvatar()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        if !segment.text.isEmpty {
                            MarkdownView(text: Self.autolinkBareURLs(segment.text),
                                         config: Self.chatMarkdownConfig)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let url = segment.image {
                            WOInlineAgentImage(url: url,
                                               sessionID: context.sessionId.isEmpty ? nil : context.sessionId)
                        }
                    }
                }
            }
            .padding(.top, 1)

        case .reasoning(let text):
            // 思考披露：标题 + 首行预览 + chevron；展开体左缩进 22（digest-H .think）。
            // 流式官方化：live 槽（live-r-N）= running 态（LED 尾行跟随+扫光），
            // 落盘 = 同一组件参数翻转 running→settled，零视图重建（dsh 同节点
            // 收敛语义；落盘思考节点 id=a(seq)-b(idx) 恒不撞 live-r- 前缀）。
            ReasoningDisclosure(text: text,
                                running: bubble.id.hasPrefix("live-r-"))

        case .tool(let card):
            // R2a：工具卡全型（digest-F §41；D6 清偿）。
            WOToolCard(card: card, sessionID: context.sessionId.isEmpty ? nil : context.sessionId)

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

    /// 用户气泡（原 case .user 主体原样抽出——goal_round 拦截分流的另一支；
    /// 行内注释与形态逐项保持）。
    private func userBubble(text: String, images: [ImageAttachmentRef]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    // 消息内图片（复用 MessageImagesView；单图 80pt=
                    // 用户既定裁定 T2.6 件7，不改）。
                    MessageImagesView(images: images,
                                      store: context.attachmentStore,
                                      onPreview: { context.onImagePreview($0) })
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
    }
}

// MARK: - 批12 T5：dsh DisclosureRow 共用行件 + IconThinkOutline14
//
//  规格=ui-chat/ReasoningRow.tsx + module.css + ui-primitives/DisclosureRow
//  （主理人逐文件核证真值）：收起/展开是同一个 24px 行组件——
//    [16×16 leading 盒（内 14px 图标）] gap6 [title 13/24/400] [2×2 分隔点
//    margin 0 8] [summary 13 单行省略]；展开时 leading 换 chevron.down；
//    summary 空时分隔点一起消失；sweepActive 时整行叠 WOSweepModifier（2.6s）。
//  注：WOToolCards.swift（T6 工具行）复用本件（原 WOChatView.swift 内
//  internal，批 2 随渲染链迁入本文件，引用面不变）。

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
                        if summaryFollowEnd {
                            // 批12+回归五校（用户令：LED 走字式跟随，四校的
                            // 截头显尾判废=窗口跳变不丝滑）：思考流式末端在行内
                            // 右缘进字、左缘滑出，滑动速度=模型思考出字速度。
                            WOLedTail(text: summary, color: summaryColor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text(summary)
                                .font(.system(size: 13))
                                .foregroundColor(summaryColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
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
