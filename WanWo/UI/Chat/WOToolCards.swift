//
//  WOToolCards.swift
//  WanWo
//
//  批12 T6 —— 工具行 dsh 化（ui-tool/ToolRow.tsx + module.css 真值落地）：
//  - expanded 初值恒 false——running 不自动展开，状态变化绝不重置用户选择
//    （触屏语义：初值收起，点击开合；旧版「running 自动开合」病根清除）
//  - 行=裸行（无卡底无描边）：[16×16 leading] gap6 [title 13/24/400
//    labelPrimary] gap8 [2×2 点] gap8 [summary 13/24 单行省略 flex fill]
//  - leading：error=StateDot(.error)红点；其余=工具图标（14px labelTertiary，
//    SF Symbol 语义映射）；展开时 leading=chevron.down（WODisclosureRow 统一）
//  - running：整行叠扫光（WOSweepModifier 2.6s）；无 pill、无「运行中」文字
//  - summary：error=错误首行（stateErrorPrimary）；正常=argsRaw 摘要（ToolCard
//    无独立 summary 字段，取参数 JSON 首行；空 summary 时分隔点一起消失）
//  - 展开体=ioCard：margin 4/0/4/4（左缩进 4）；border 0.5px borderL1；r12；
//    bg=代码块底色 bgLayer2；内部分节 grid [标签 caption 11px] gap14 [内容
//    11px mono labelSecondary]，节 padding 12/16，每节 max-height 150 独立
//    滚动；IN/OUT 节间 0.5px borderL2 全宽分隔线
//  - 错误头行 errorName:code 保持；16 行帽（cappedOutput/liveCapped 现函数
//    不动）；wanwo:// 资源行保持；琥珀状态行（statusNote）恒显不随折叠；
//    左缩进 .padding(.leading, 30) 保持；长按菜单不加（dsh 无）
//


import SwiftUI
import UIKit

/// 工具行全型（消费 ConversationProjector.ToolCard；行头复用批12 T5 的
/// WODisclosureRow 共用行件）。
struct WOToolCard: View {
    let card: ConversationProjector.ToolCard
    let sessionID: String?

    /// 批12 T6（dsh ToolRow）：expanded 初值恒 false——running 也不自动展开，
    /// 状态变化绝不重置用户选择（init 不再看 isRunning）。
    @State private var expanded = false

    init(card: ConversationProjector.ToolCard, sessionID: String? = nil) {
        self.card = card
        self.sessionID = sessionID
        // dsh：初值恒收起（@State private 使 memberwise init 降级为 private，
        // 跨文件调用面需显式 init——同旧件写法）。
        _expanded = State(initialValue: false)
    }

    /// 输出行 16 行帽（head/tail 对半分——dsh headTailCap 语义；现函数不动）。
    private var cappedOutput: (text: String, hidden: Int)? {
        guard let result = card.resultText, !result.isEmpty else { return nil }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 16 else { return (result, 0) }
        let head = lines.prefix(8)
        let tail = lines.suffix(8)
        let text = head.joined(separator: "\n")
            + "\n…（中间省略 \(lines.count - 16) 行）\n"
            + tail.joined(separator: "\n")
        return (text, lines.count - 16)
    }

    private var liveCapped: String {
        guard !card.liveOutput.isEmpty else { return "" }
        let lines = card.liveOutput.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 16 else { return card.liveOutput }
        return lines.prefix(16).joined(separator: "\n") + "\n…（已截断）"
    }

    /// dsh ToolRow summary：error=错误首行（errorName:code）；正常=argsRaw
    /// 摘要（ToolCard 无独立 summary 字段，取参数 JSON 首行；为空则分隔点
    /// 一起消失）。
    private var summaryText: String {
        if card.isError {
            guard let errorName = card.errorName else { return "" }
            return card.errorCode.map { "\(errorName): \($0)" } ?? errorName
        }
        let raw = card.argsRaw ?? card.detail ?? ""
        let line = raw.split(separator: "\n").first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// 输出分节在场性：在途=liveOutput 非空；收敛=16 行帽（cappedOutput）非 nil。
    private var hasOutput: Bool {
        (card.isRunning && !card.liveOutput.isEmpty) || cappedOutput != nil
    }

    /// 展开体输出文本：在途=liveOutput 16 行帽；收敛=cappedOutput 文本。
    private var outputText: String {
        if card.isRunning, !card.liveOutput.isEmpty { return liveCapped }
        return cappedOutput?.text ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 行头（T5 WODisclosureRow：裸行 24px；title=labelPrimary；
            // running 整行叠扫光；expanded 恒 false 初值）。
            WODisclosureRow(icon: leadingIcon,
                            title: card.title.isEmpty ? card.name : card.title,
                            expanded: $expanded,
                            summary: expanded ? "" : summaryText,
                            sweepActive: card.isRunning,
                            titleColor: WOAlias.labelPrimary,
                            summaryColor: card.isError
                                ? WOAlias.stateErrorPrimary
                                : WOAlias.labelTertiary) {
                ioCard
            }
            // 琥珀状态行恒显（审批等待/结算——不随折叠消失；dsh statusNote 语义）。
            if let status = card.statusNote, !status.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(WOAlias.stateWarnPrimary).frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundColor(WOAlias.stateWarnLabel)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)
            }
        }
        .padding(.leading, 30) // dsh tool-card 左缩进（状态点留位语义）
    }

    // MARK: - 行头 leading（dsh ToolRow：error 红点 / 其余工具图标；展开时
    // leading 换 chevron.down 由 WODisclosureRow 统一处理）

    @ViewBuilder
    private var leadingIcon: some View {
        if card.isError {
            // dsh：error=StateDot(.error) 红点（WanWo ToolCard 无 stopped 态
            // ——StateDot(.warning) 分支缺席，登记报告）。
            WOStateDot(state: .error, size: 8)
                .frame(width: 14, height: 14)
        } else {
            // 其余=工具图标（14px labelTertiary；SF Symbol 语义映射）。
            Image(systemName: Self.toolIconName(for: card.name))
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelTertiary)
        }
    }

    /// 工具图标映射（dsh ToolRow SF Symbol 语义映射；file-private 纯函数；
    /// 未知名走默认 wrench.fill）。
    private static func toolIconName(for name: String) -> String {
        let key = name.lowercased()
        if key.contains("read") { return "doc.text" }
        if key.contains("bash") || key.contains("exec") { return "terminal" }
        if key.contains("browser") { return "globe" }
        if key.contains("grep") || key.contains("search") { return "magnifyingglass" }
        if key.contains("write") || key.contains("edit") { return "pencil" }
        return "wrench.fill"
    }

    // MARK: - 展开体 ioCard（dsh ToolRow 展开态：margin 4/0/4/4；border 0.5px
    // borderL1；r12；bg=代码块底色 bgLayer2；IN/OUT 节间 0.5px borderL2 分隔）

    private var ioCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 输入分节（DetailsPanel input 段：prettyJSON；argsRaw 缺失回退 detail）。
            if let detail = card.detail, !detail.isEmpty {
                ioSection("输入") {
                    Text(ConversationProjector.prettyJSON(card.argsRaw ?? detail))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(WOAlias.labelSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                if hasOutput {
                    // IN/OUT 节间分隔线（0.5px borderL2 全宽）。
                    Rectangle()
                        .fill(WOAlias.borderL2)
                        .frame(height: 0.5)
                }
            }
            // 输出分节（错误头行 errorName:code + 原文；16 行帽；wanwo:// 资源行）。
            if hasOutput {
                ioSection("输出") {
                    VStack(alignment: .leading, spacing: 6) {
                        if card.isError, let errorName = card.errorName {
                            Text(card.errorCode.map { "\(errorName): \($0)" } ?? errorName)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(WOAlias.stateErrorPrimary)
                        }
                        Text(outputText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(card.isError
                                ? WOAlias.stateErrorPrimary
                                : WOAlias.labelSecondary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                        ForEach(Self.wanwoLinks(in: outputText), id: \.self) { link in
                            wanwoResourceRow(link)
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(WOAlias.bgLayer2))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(WOAlias.borderL1, lineWidth: 0.5))
        // dsh ioCard margin 4/0/4/4（上/右/下/左——左缩进 4，右 0 贴边）。
        .padding(.top, 4)
        .padding(.bottom, 4)
        .padding(.leading, 4)
    }

    /// ioCard 分节（dsh grid：[标签 caption 11px] gap14 [内容 11px mono]；
    /// 节 padding 12/16；内容 max-height 150 独立纵向滚动）。
    private func ioSection<Body: View>(_ label: String,
                                       @ViewBuilder content: () -> Body) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(WOAlias.labelTertiary)
            ScrollView(.vertical) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    /// wanwo:// 资源链接行（旧 ToolCardView.wanwoLinks 消费端 1:1；点击打开
    /// 右栏浏览器页签——WanwoURLRouter R4 接线，本环先显可点行）。
    private func wanwoResourceRow(_ link: String) -> some View {
        // 旧件 wanwoResourceRow 1:1（ChatView:1013）：点击 → WanwoURLRouter.handle
        // → WORootFrame 消费 → 右栏对应页签（browser/files）；可解析宿主文件
        // → 64×48 缩略（WanwoURLSchemeHandler.resolveWanwoURL，会话桶锚=本卡）。
        Button {
            if let url = URL(string: link) {
                WanwoURLRouter.shared.handle(url)
            }
        } label: {
            HStack(spacing: 6) {
                if let url = URL(string: link),
                   let fileURL = WanwoURLSchemeHandler.resolveWanwoURL(url, sessionID: sessionID),
                   let thumb = UIImage(contentsOfFile: fileURL.path) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 48)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(WOAlias.stateBusinessPrimary)
                }
                Text(link)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(WOAlias.stateBusinessPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10))
                    .foregroundColor(WOAlias.labelTertiary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(WOAlias.bgLayer2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开资源 \(link)")
    }

    /// wanwo:// 链接提取（旧 ToolCardView.wanwoLinks 纯函数 1:1——首个空白字符止）。
    nonisolated static func wanwoLinks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "wanwo://\\S+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
