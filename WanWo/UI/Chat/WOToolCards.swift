//
//  WOToolCards.swift
//  WanWo
//
//  R2a 对话域保真批 1 —— 工具卡全型（11-ui-design §六.4；D6 清偿）。
//  规格=digest-F §41（ui-tool 54 文件）+ digest-B §6.3 + digest-H 原型：
//  - ToolRow 24px 折叠行语义（头行恒显点击切换展开；running 展开初值）
//  - 状态 pill（「运行中」灰 /「已完成」绿；signal 优先——dsh tool-row）
//  - 输入分节（prettyJSON mono）+ 输出分节（错误头行 errorName:code + 原文）
//  - 输出 16 行帽（dsh TerminalBlock DEFAULT_TERMINAL_MAX_LINES 语义，head/tail 对半分）
//  - 琥珀状态行恒显（审批等待/结算——不随折叠消失）
//  - wanwo:// 资源链接行（旧 ToolCardView wanwoLinks 纯函数 1:1）
//  结构沿用旧 ChatView.ToolCardView（digest-K §6.1 复用判定），样式换 WO 令牌+
//  升级 dsh 形态（pill/行高/帽）；terminalFailed 唯一失败信号的输出侧呈现
// （isError 已由投影层按结果态给出）。
//

import SwiftUI

/// 工具卡全型（对应旧 ChatView.ToolCardView；消费 ConversationProjector.ToolCard）。
struct WOToolCard: View {
    let card: ConversationProjector.ToolCard
    let sessionID: String?

    /// 展开态（初值随卡片在途性：running 展开、完成收起；用户手动切换后保留）。
    @State private var expanded: Bool

    init(card: ConversationProjector.ToolCard, sessionID: String? = nil) {
        self.card = card
        self.sessionID = sessionID
        _expanded = State(initialValue: card.isRunning)
    }

    /// 输出行 16 行帽（head/tail 对半分——dsh headTailCap 语义）。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 行头（恒显；点击切换展开——dsh ToolRow 语义）。
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    WOStateDot(state: card.isRunning ? .ongoing
                                        : (card.isError ? .error : .done),
                               size: 8)
                        .frame(width: 16, height: 16)
                    Text(card.title.isEmpty ? card.name : card.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // 状态 pill（dsh tool-row signal pill：「运行中」/「已完成」）。
                    Text(card.isRunning ? "运行中" : (card.isError ? "出错" : "已完成"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(card.isRunning ? WOAlias.labelSecondary
                                            : (card.isError ? WOAlias.stateErrorPrimary
                                               : WOAlias.stateSuccessPrimary))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(
                            card.isError ? WOAlias.stateErrorSecondary : WOAlias.stateSuccessTertiary))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WOAlias.labelTertiary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: 24)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    // 输入分节（DetailsPanel input 段：prettyJSON；argsRaw 缺失回退 detail）。
                    if let detail = card.detail, !detail.isEmpty {
                        sectionLabel("输入")
                        Text(ConversationProjector.prettyJSON(card.argsRaw ?? detail))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(WOAlias.labelSecondary)
                            .lineLimit(10)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(WOAlias.bgLayer2))
                    }
                    // 流式输出（在途）。
                    if card.isRunning, !card.liveOutput.isEmpty {
                        sectionLabel("输出")
                        Text(liveCapped)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(WOAlias.labelPrimary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(WOAlias.bgLayer2))
                    }
                    // 结果分节（错误头行 errorName:code + 原文；16 行帽）。
                    if let output = cappedOutput {
                        sectionLabel("输出")
                        if card.isError, let errorName = card.errorName {
                            Text(card.errorCode.map { "\(errorName): \($0)" } ?? errorName)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(WOAlias.stateErrorPrimary)
                        }
                        Text(output.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(card.isError ? WOAlias.stateErrorPrimary : WOAlias.labelSecondary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(WOAlias.bgLayer2))
                        ForEach(Self.wanwoLinks(in: output.text), id: \.self) { link in
                            wanwoResourceRow(link)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        // 琥珀状态行恒显（审批等待/结算——交互态不随折叠消失；dsh statusNote 语义）。
        .background(
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if let status = card.statusNote, !status.isEmpty {
                    HStack(spacing: 6) {
                        Circle().fill(WOAlias.stateWarnPrimary).frame(width: 6, height: 6)
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.stateWarnLabel)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }
        )
        .background(RoundedRectangle(cornerRadius: 12).fill(WOAlias.bgModulePlatform))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
        .padding(.leading, 30) // dsh tool-card 左缩进（状态点留位语义）
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(WOAlias.labelTertiary)
    }

    /// wanwo:// 资源链接行（旧 ToolCardView.wanwoLinks 消费端 1:1；点击打开
    /// 右栏浏览器页签——WanwoURLRouter R4 接线，本环先显可点行）。
    private func wanwoResourceRow(_ link: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundColor(WOAlias.stateBusinessPrimary)
            Text(link)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(WOAlias.stateBusinessPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(WOAlias.bgLayer2))
        .contentShape(Rectangle())
        // R4 接线点：WanwoURLRouter.open(link) → 右栏浏览器页签。
    }

    /// wanwo:// 链接提取（旧 ToolCardView.wanwoLinks 纯函数 1:1——首个空白字符止）。
    nonisolated static func wanwoLinks(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "wanwo://\\S+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
