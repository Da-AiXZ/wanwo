//
//  WOSubagentCatalog.swift
//  WanWo
//
//  【M7-Fix2 批2 B1 2026-09-29】子代理目录数据面 + 后代索引 + 子会话只读回放。
//  座位组卡（WOSubagentCatalogCard）退役：目录入口升级为会话标题栏 count
//  徽章 + 下拉目录树（WOSubagentLineageBadge，见 WOSubagentLineageBadge.swift；
//  旧视图零残留，数据面在本文件迁移保留）。
//
//  dsh 语义源（铁律先查，repos/deepseek-harness-master/packages/client/
//  ui-subagent/src/client/ 四文件全文通读）：
//    · subagent-lineage.ts indexSubagentDescendants :24-45 —— 从会话摘要沿
//      parentId 链上溯聚合 count/runningCount（纯函数 1:1 折算为
//      WOSubagentLineageIndex.index；seen 集断环、父不在集合即停）。
//    · SubagentHeaderLineage.tsx :671-685 —— 徽章可见性 = 有子女证据才渲染
//      （entries>0 / 后代计数>0 / 加载出错），空 = 不渲染。
//    · CatalogRows :270-433 —— 行 = 状态点(running?ongoing:done) +
//      label(entry.label ?? id) + secondary=[summary?.title, mode, activity]
//      .join(' · ')；诊断行三态 disabled；加载行；点行 openChild 并收起目录。
//    · locales.ts（zh 字典）= 文案唯一事实源（diagnostic 三态/加载行/
//      mode/activity/readonly.oneShot 逐字）。
//    · SubagentReadOnlyComposer.tsx —— one-shot 只读横幅逐字文案。
//  数据面（全部现成缝，零 Core/Features/AppEnvironment 改动）：
//    · 枚举 = 子会话日志头 lineage 事件（SubagentLineage.read；创建窗口
//      lineage 是子日志第一条事件，AppEnvironment.makeSubagentChildStack
//      实证——头部 64KB 读必然命中）+ descriptor（第二条）。
//    · 状态 = SubagentRuntime.listAgents(callerSessionId:includeDescendants:)
//      （running/idle/ready 三档；one-shot 不驻留 runtime，按 dsh 只标形态）。
//    · 诊断 = AgentListing.diagnosticReason（'corrupt'|'unsupported'|
//      'unavailable'）→ dsh 诊断行三态文案（locales.ts diagnostic.*）。
//    · 回放 = SessionLogScanner 全量 scan（TrajectoryTabView.TrajectoryLoader
//      同款只读纪律）+ ConversationProjector.project 纯函数直接喂子会话事件。
//

import SwiftUI
import UIKit
// 【批6 H1】回放正文 Markdown 渲染（主对话面同库同款——WOChatView 批12 T7）。
import SwiftStreamingMarkdown

// MARK: - 后代索引（dsh subagent-lineage.ts indexSubagentDescendants 1:1）

/// UI 侧自有投影（dsh "UI Subagent-owned projection of descendant counts
/// from Session summaries"——从行记录沿 parentId 链上溯，为每个可能的父
/// 聚合不间断后代 count/runningCount）。纯函数，单测缝。
enum WOSubagentLineageIndex {

    /// 某个可能的父会话的后代计数（dsh SubagentDescendantSummary）。
    struct Summary: Equatable {
        var count = 0
        var runningCount = 0
        static let empty = Summary()
    }

    /// 血缘行（dsh LineageEntry：id + parentId + origin==='subagent' + running）。
    struct Entry: Equatable {
        let id: String
        /// 直接父 id（dsh parentId；nil = 非 subagent-origin，不入索引）。
        let parentID: String?
        /// 运行位（dsh running）。
        let running: Bool
    }

    /// dsh subagent-lineage.ts :24-45 逐行折算：每个后代沿父链上溯，
    /// 逐祖先 +1 count；running 后代逐祖先 +1 runningCount；seen 集断环；
    /// 父不在集合（非 subagent-origin）即停。
    static func index(_ entries: [Entry]) -> [String: Summary] {
        let byID = Dictionary(entries.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var indexed: [String: Summary] = [:]
        for descendant in entries {
            guard descendant.parentID != nil else { continue } // origin!=='subagent'
            var seen = Set<String>()
            var current: Entry? = descendant
            while let node = current,
                  node.parentID != nil,
                  !seen.contains(node.id) {
                seen.insert(node.id)
                let parentID = node.parentID!
                var aggregate = indexed[parentID] ?? Summary()
                aggregate.count += 1
                if descendant.running { aggregate.runningCount += 1 }
                indexed[parentID] = aggregate
                // summaries[current.parentId]——父不是 subagent-origin 即停。
                current = byID[parentID]
            }
        }
        return indexed
    }
}

// MARK: - 目录扫描（纯数据面，单测缝）

enum WOSubagentCatalog {

    /// 目录行（dsh LineageEntry + descriptor 投影）。
    struct ChildRecord: Identifiable, Equatable {
        let id: String
        /// descriptor.label ?? 会话标题回退 ?? session id（dsh :301 回退序）。
        let label: String
        /// 会话标题（dsh secondary 段 summary?.title；与 label 同源时为 nil）。
        let title: String?
        /// one-shot / continuable（SubagentDescriptor.Mode 语义）。
        let mode: String
        let depth: Int
        let createdAt: Date
        /// runtime 状态（running/idle/ready）；one-shot 无 runtime 行 = nil。
        let runtimeStatus: String?
        /// 诊断形态（dsh :271-291 diagnostic 行）：nil = 正常行。
        let diagnosticReason: String?
    }

    /// 全树扫描输出（一次 IO 遍历产出徽章计数 + 树渲染所需全量）。
    struct ScanOutput: Equatable {
        /// 直接子代理行（createdAt 升序）。
        var directChildren: [ChildRecord] = []
        /// 逐父分组行（key = 父会话 id，值按 createdAt 升序）。
        var childrenByParent: [String: [ChildRecord]] = [:]
        /// 根会话的后代聚合（dsh descendants = indexSubagentDescendants）。
        var descendants: WOSubagentLineageIndex.Summary = .init()
        static let empty = ScanOutput()
    }

    /// 子日志头部快照折叠（lineage 是子日志第一条事件——创建窗口直写，
    /// 头部 64KB 读必然命中；未命中 = 非子会话，登记头部读口径）。
    struct HeadFold: Equatable {
        var parentSession: String?
        var label: String?
        var mode: String?
        var depth: Int?
    }

    /// 从 JSONL 头部字节折叠 lineage+descriptor（纯函数；lines 由调用方
    /// 解出——文件 IO 与解析分离，便于单测喂样例行）。
    static func foldHead(lines: [String]) -> HeadFold {
        var fold = HeadFold()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(SessionEvent.self, from: data)
            else { continue }
            switch event.payload {
            case .extensionEvent(SubagentLineage.eventKind, let payload):
                fold.parentSession = payload.field("parentSession")?.stringValue
                fold.depth = payload.field("delegationDepth")?.intValue
            case .extensionEvent(SubagentDescriptor.eventKind, let payload):
                fold.label = payload.field("label")?.stringValue
                fold.mode = payload.field("mode")?.stringValue
            default:
                break
            }
            if fold.parentSession != nil, fold.mode != nil { break }
        }
        return fold
    }

    /// 头部前 limit 字节的完整行集（【批3 A4.1】有界读——旧实现
    /// `Data(contentsOf:)` 整文件进内存后才截 64KB，长会话反而更贵；
    /// FileHandle.readData(ofLength:) 两段封顶）。截断半行丢弃：foldHead
    /// 对残行 JSON 解码失败即跳过（既有兜底）。
    static func headLines(url: URL, limit: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit)
        var text = String(decoding: data, as: UTF8.self)
        if data.count >= limit, let lastNewline = text.lastIndex(of: "\n") {
            text = String(text[text.startIndex..<lastNewline])
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// 全量扫描（同步磁盘面；调用方在后台线程执行）。
    /// 从会话集合逐个读日志头折叠血缘（覆盖 one-shot——runtime 边表仅
    /// continuable 落边），与 runtime listings 合并成整树：
    ///   · statuses = listings 正常行 → runtimeStatus（running/idle/ready）；
    ///   · diagnostics = listings.diagnosticReason → 诊断行
    ///     （head 读不出的子以 listing.parentSessionId 补挂——dsh :72-74
    ///     "reported as diagnostics instead of being silently dropped"）；
    ///   · 【批3 A4.1】非诊断 listings 并入发现行（dsh list-agents.ts
    ///     project() 语义——runtime 可见的子代理不因 head fold 缺口静默
    ///     掉线；head 扫描已发现者带同款 status，不重复）。
    static func scan(rootID: String,
                     sessions: [SessionSummary],
                     listings: [SubagentRuntime.AgentListing]) -> ScanOutput {
        let root = GroupStore.groupSessionsRoot(
            base: WanWoPaths.persistentBase,
            groupID: GroupStore.defaultGroupID)
        var statuses: [String: String] = [:]
        var diagnostics: [String: String] = [:]
        for listing in listings {
            if let reason = listing.diagnosticReason {
                diagnostics[listing.subagentId] = reason
            } else {
                statuses[listing.subagentId] = listing.status
            }
        }
        var byParent: [String: [ChildRecord]] = [:]
        var entries: [WOSubagentLineageIndex.Entry] = []
        // 【批3 A4.1】head 扫描实际发现集合（listings 补挂的查重依据）。
        var discovered = Set<String>()
        for summary in sessions {
            let url = root.appendingPathComponent("\(summary.id).jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // 【批3 A4.1】头部读取分级放宽：lineage/descriptor 恒在头部
            // 事件（原始日志头两行=lineage+descriptor，64KB 内），但 descriptor
            // 若排在 seeding 上下文之后（长首事件）可能越窗——先 64KB，
            // 未折全再放宽到 256KB（IO 有界两档封顶）。
            var fold = foldHead(lines: headLines(url: url, limit: 64 * 1024))
            if fold.parentSession == nil || fold.mode == nil {
                fold = foldHead(lines: headLines(url: url, limit: 256 * 1024))
            }
            guard let parentID = fold.parentSession else { continue }
            discovered.insert(summary.id)
            let label = fold.label ?? summary.title ?? summary.id
            let record = ChildRecord(
                id: summary.id,
                label: label,
                title: (summary.title != nil && summary.title != label)
                    ? summary.title : nil,
                mode: fold.mode ?? "one-shot",
                depth: fold.depth ?? 1,
                createdAt: summary.createdAt,
                runtimeStatus: statuses[summary.id],
                diagnosticReason: diagnostics[summary.id])
            byParent[parentID, default: []].append(record)
            entries.append(WOSubagentLineageIndex.Entry(
                id: summary.id, parentID: parentID,
                running: statuses[summary.id] == "running"))
        }
        // 诊断行：head fold 不可得（元数据缝抛错）→ runtime listing 补挂。
        // 不入后代索引（running 恒 false——fold 不可得，dsh 诊断行不可导航）。
        for listing in listings where listing.diagnosticReason != nil {
            let already = byParent[listing.parentSessionId]?
                .contains { $0.id == listing.subagentId } ?? false
            guard !already else { continue }
            let record = ChildRecord(
                id: listing.subagentId,
                label: listing.label.isEmpty ? listing.subagentId : listing.label,
                title: nil,
                mode: "continuable",
                depth: listing.depth,
                createdAt: .distantPast,
                runtimeStatus: nil,
                diagnosticReason: listing.diagnosticReason)
            byParent[listing.parentSessionId, default: []].append(record)
        }
        // 【批3 A4.1】非诊断 listings 补挂发现行：head 扫描未见（头折缺
        // 口/新落盘竞态）但 runtime 在册的子代理照常入树——运行状态随行，
        // 后代索引照常入（有 parentSessionId 即可导航）。
        for listing in listings
        where listing.diagnosticReason == nil
                && !discovered.contains(listing.subagentId) {
            let record = ChildRecord(
                id: listing.subagentId,
                label: listing.label.isEmpty ? listing.subagentId : listing.label,
                title: nil,
                mode: "continuable",
                depth: listing.depth,
                createdAt: .distantPast,
                runtimeStatus: listing.status,
                diagnosticReason: nil)
            byParent[listing.parentSessionId, default: []].append(record)
            entries.append(WOSubagentLineageIndex.Entry(
                id: listing.subagentId, parentID: listing.parentSessionId,
                running: listing.status == "running"))
        }
        for key in byParent.keys {
            byParent[key]?.sort { $0.createdAt < $1.createdAt }
        }
        let summary = WOSubagentLineageIndex.index(entries)[rootID] ?? .init()
        return ScanOutput(
            directChildren: byParent[rootID] ?? [],
            childrenByParent: byParent,
            descendants: summary)
    }

    // MARK: 行文案（locales.ts zh 字典 = 唯一事实源，逐字）

    /// mode 文案（locales.ts mode.oneShot/mode.continuable）。
    static func modeText(for record: ChildRecord) -> String {
        record.mode == SubagentDescriptor.Mode.oneShot.rawValue ? "一次性" : "可继续"
    }

    /// activity 文案（locales.ts activity.running/inactive）。one-shot 无
    /// runtime 行不做活动断言（README :105 无持久结果语义 → nil 不出词）。
    static func activityText(for record: ChildRecord) -> String? {
        guard record.runtimeStatus != nil else { return nil }
        return record.runtimeStatus == "running" ? "正在运行" : "当前未运行"
    }

    /// 诊断文案（locales.ts diagnostic.corrupt/unsupported/unavailable 三态）。
    static func diagnosticText(_ reason: String) -> String {
        switch reason {
        case "corrupt": return "会话记录损坏"
        case "unsupported": return "子代理记录版本不受支持"
        default: return "会话记录暂不可用"
        }
    }
}

// MARK: - 子会话只读回放（点行落点，sheet 承载）

/// 子会话只读回放（dsh SubagentReadOnlyComposer + "read-only composer
/// identifying the transcript as a completed execution record" 的承载）：
/// SessionLogScanner 全量 scan（TrajectoryLoader 只读纪律）→
/// ConversationProjector.project 纯函数折叠（registry=nil——presentCall
/// 复现仅缺工具卡标题，卡片标题回落工具名，登记）→
/// 【批6 H1】回放行与主对话面 WOChatView.bubbleView 逐类对齐的富渲染
/// （思考披露/工具全型卡/Markdown 正文/用户蓝泡+图片条/轮次 pill；只读
/// 性质不变——无输入面，running 恒 settled）。
/// 【M7-Fix2 批2 B1】底部按 dsh locales.ts readonly.oneShot.* 逐字补
/// 只读横幅（one-shot 形态）；switcher（子会话视角切父/兄弟）按承载形态
/// 裁剪（万我子会话 = sheet 回放，无面包屑基建），登记。
struct WOSubagentReplayView: View {
    let child: WOSubagentCatalog.ChildRecord

    @Environment(\.dismiss) private var dismiss
    @State private var bubbles: [ConversationProjector.Bubble] = []
    @State private var loadError: String?
    /// 【批6 H1】用户气泡图片预览（MessageLightboxView 全屏承载——批4 L1
    /// 双链统一件，replay 复用同一条预览链）。
    @State private var previewRef: ImageAttachmentRef?

    /// 【批6 H1】子会话附件仓（content-addressed；root = 子会话 bucket——
    /// AttachmentStore(sessionId:) 廉价值类型，与 AppEnvironment:1095 同一
    /// 构造面；用户气泡图片读取/预览共用）。
    private var attachmentStore: AttachmentStore {
        AttachmentStore(sessionId: child.id)
    }

    /// 【批6 H1】回放 Markdown 配置（WOChatView.chatMarkdownConfig 1:1 复刻
    /// ——原件 private 不可跨文件复用；值语义逐项照录，改原件须同步此处，
    /// 登记报告 §对拍表）。
    private static let replayMarkdownConfig: MarkdownRenderConfig = {
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

    private var isOneShot: Bool {
        child.mode == SubagentDescriptor.Mode.oneShot.rawValue
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                if isOneShot {
                    readOnlyBanner
                }
            }
            .navigationTitle(child.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // 【批6 H1】图片全屏预览（与主对话面同一条 MessageLightboxView 链
        // ——批4 L1 件；store 缺失/对象缺失自带"图片不可用"兜底）。
        .fullScreenCover(item: $previewRef) { ref in
            MessageLightboxView(ref: ref, store: attachmentStore)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            Text(loadError)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(bubbles) { bubble in
                        replayRow(bubble)
                    }
                }
                .padding(14)
            }
        }
    }

    /// 只读横幅（dsh SubagentReadOnlyComposer one-shot 形态逐字——
    /// locales.ts readonly.oneShot.title/body；role=status ≙ role 状态播报）。
    private var readOnlyBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("一次性子代理记录")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WOAlias.labelPrimary)
            Text("一次性任务不支持后续消息，可在这里查看完整执行记录。")
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WOAlias.bgLayer3)
        .overlay(alignment: .top) {
            Rectangle().fill(WOAlias.borderL1).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    /// 回放装载结果（String 不满足 Result 的 Error 关联值约束——CI修19）。
    private enum ReplayLoadOutcome {
        case loaded([SessionEvent])
        case failed(String)
    }

    private func load() async {
        let childId = child.id
        // 只读 replay（TrajectoryTabView 同款纪律：detached 只回事件，
        // 投影在调用方——ConversationProjector.project 纯函数直接喂子会话事件）。
        let result = await Task.detached(priority: .userInitiated) { () -> ReplayLoadOutcome in
            let url = GroupStore.groupSessionsRoot(
                base: WanWoPaths.persistentBase,
                groupID: GroupStore.defaultGroupID)
                .appendingPathComponent("\(childId).jsonl")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return .failed("子会话日志不可读")
            }
            do {
                return .loaded(try SessionLogScanner.scan(data: data).events)
            } catch {
                return .failed("子会话日志解析失败：\(error)")
            }
        }.value
        switch result {
        case .loaded(let events):
            var callArgs: [String: (name: String, args: JSONValue)] = [:]
            bubbles = ConversationProjector.project(
                events: events, registry: nil, callArgs: &callArgs)
        case .failed(let message):
            loadError = message
        }
    }

    /// 回放行渲染（【批6 H1】与主对话面 WOChatView.bubbleView 逐类对齐——
    /// 思考=披露行、工具=全型卡、正文=Markdown、用户=右对齐蓝泡+图片条、
    /// 用量=轮次 pill、命令=卡底、纸条=降噪灰字。只读性质不变：无输入面、
    /// 无乐观态、running 恒 settled——回放是已完成记录的 transcript）。
    @ViewBuilder
    private func replayRow(_ bubble: ConversationProjector.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text, let images):
            replayUserBubble(text: text, images: images)
        case .assistant(let text):
            replayAssistantRow(text: text)
        case .reasoning(let text):
            // 主对话面同款思考披露（ReasoningDisclosure 为 WOChatView private
            // ——同文件内复刻 WOReplayReasoningDisclosure，settled 形态逐值照录）。
            WOReplayReasoningDisclosure(text: text)
        case .tool(let card):
            // 工具卡全型（WOToolCard internal 复用；sessionID=子会话 id——
            // 卡内 wanwo:// 解析与浏览器工作区解析均 session 域）。
            WOToolCard(card: card, sessionID: child.id)
        case .command(let kind, let text):
            // 主对话面 :1236-1247 同款（卡底平台面色）。
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
            // 主对话面 :1249-1253 同款（全宽降噪灰字）。
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .turnUsage(let summary):
            // 轮次尾用量/用时 pill（主对话面 :1255-1261 同款；internal 复用）。
            HStack {
                WOTurnUsagePill(summary: summary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        case .goalRound(let text):
            // 【批3 A1】goal_round 续轮专卡（与主对话面同件，既有对齐保持）。
            WOGoalRoundCard(text: text)
                .padding(.vertical, 4)
        }
    }

    /// 用户气泡（主对话面 userBubble :1274-1312 1:1——右对齐、蓝软底
    /// WOSpecific.bubble、圆角 22、padding 10/16、lineSpacing 4、max-width
    /// 508（620 列 82%）、长按拷贝；图片条 MessageImagesView 复用，点击
    /// 走本 sheet 内 MessageLightboxView 预览）。
    private func replayUserBubble(text: String, images: [ImageAttachmentRef]) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty {
                    MessageImagesView(images: images,
                                      store: attachmentStore,
                                      onPreview: { previewRef = $0 })
                }
                if !text.isEmpty {
                    // 纯图片消息不画气泡（dsh MessageItem 语义）。
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

    /// 助手行（主对话面 .assistant :1196-1226 1:1——渐变头像 + MarkdownView
    /// 正文 + wanwo:// 截图保序插段；切段/autolink 复用 WOChatView internal
    /// 静态函数，配置复刻 replayMarkdownConfig）。
    private func replayAssistantRow(text: String) -> some View {
        let segments = WOChatView.splitAgentSegments(text)
        return HStack(alignment: .top, spacing: 8) {
            WOAssistantAvatar()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments) { segment in
                    if !segment.text.isEmpty {
                        MarkdownView(text: WOChatView.autolinkBareURLs(segment.text),
                                     config: Self.replayMarkdownConfig)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let url = segment.image {
                        WOInlineAgentImage(url: url, sessionID: child.id)
                    }
                }
            }
        }
        .padding(.top, 1)
    }
}

// MARK: - 批6 H1 思考披露复刻件（ReasoningDisclosure/WOThinkIcon 为
// WOChatView private 不可跨文件——同文件私有复刻，逐值照录；改原件须同步）

/// 思考图标（dsh IconThinkOutline14 path1/path2 原值照录——WOChatView
/// WOThinkIcon 1:1 复刻）。
private struct WOReplayThinkIcon: View {
    static let viewBox = CGSize(width: 14, height: 14)
    static let path1 =
        "M7.06431 5.93342C7.68763 5.93342 8.19307 6.43904 8.19322 7.06233" +
        "C8.19322 7.68573 7.68772 8.19123 7.06431 8.19123C6.44099 8.19113 " +
        "5.9354 7.68567 5.9354 7.06233C5.93555 6.43911 6.44108 5.93353 " +
        "7.06431 5.93342Z"
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
        "3.70482 6.24063 3.24693 6.90705C3.72674 7.63325 " +
        "4.32777 8.37459 5.03892 9.08576C5.64943 9.69627 6.28183 10.2265 " +
        "6.90806 10.6678C7.59368 10.2025 8.2908 9.63076 8.96079 8.96076" +
        "C9.6308 8.29075 10.2025 7.59366 10.6678 6.90803C10.2265 6.2818 " +
        "9.69631 5.6494 9.08579 5.03889C8.37462 4.32773 7.63328 3.72672 " +
        "6.90708 3.2469ZM11.7147 2.15998C11.2996 1.74509 10.4204 1.61288 " +
        "9.08775 2.0926C8.74835 2.21479 8.39382 2.37271 8.03013 2.56428" +
        "C8.67728 3.03065 9.31995 3.5758 9.93443 4.19026C10.4534 4.7092 " +
        "10.9223 5.24896 11.3368 5.79377C11.5164 5.44785 11.6656 5.11052 " +
        "11.7821 4.78694C12.2618 3.45416 12.1297 2.57502 11.7147 2.15998Z" +
        "M4.91197 2.2176C3.57922 1.73788 2.70004 1.86995 2.28501 2.28498" +
        "C1.87001 2.70003 1.73791 3.5792 2.21763 4.91194C2.31709 5.18822 " +
        "2.44112 5.47427 2.58677 5.7674C3.01931 5.1887 3.51474 4.6158 " +
        "4.06529 4.06526C4.61584 3.5147 5.18872 3.01928 5.76743 2.58674" +
        "C5.47431 2.4411 5.18824 2.31706 4.91197 2.2176Z"

    var body: some View {
        ZStack {
            Path { p in
                p.addPath(PathGenerator.path(from: Self.path1, scaledTo: Self.viewBox))
            }
            .fill(WOAlias.labelTertiary)
            Path { p in
                p.addPath(PathGenerator.path(from: Self.path2, scaledTo: Self.viewBox))
            }
            .fill(WOAlias.labelTertiary, style: FillStyle(eoFill: true))
        }
        .frame(width: 14, height: 14)
    }
}

/// 思考披露（WOChatView ReasoningDisclosure settled 形态 1:1 复刻——行件
/// 复用 internal WODisclosureRow；收起 summary=首行，展开=全文 13px
/// labelTertiary 左缩进 22。回放恒 settled：running 态（尾行跟随/扫光）
/// 不需要，不复刻）。
private struct WOReplayReasoningDisclosure: View {
    let text: String

    @State private var expanded = false

    /// settled summary：首行（dsh firstLine 语义）。
    private var firstLine: String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }

    var body: some View {
        WODisclosureRow(icon: WOReplayThinkIcon(), title: "思考",
                        expanded: $expanded,
                        summary: expanded ? "" : firstLine) {
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

// MARK: - 批3 A4.2 子代理会话侧栏可见性源（dsh tree.ts sessionVisible origin 项）

/// dsh `ui-workspace/src/client/tree.ts:131-135` sessionVisible 1:1：
/// `session.origin !== 'subagent'` 恒隐藏（!archived 与 blank 项万我侧栏
/// 既有语义已覆盖）。万我 origin 在日志首事件 lineage（dsh 在
/// SessionHeader.listFields 廉价携带——改 JsonlEventLog 头不可行，平台
/// 适配 = 头折缓存，每会话头折一次/进程生命周期）。
/// 消费方 = SessionsSidebarView.filteredSummaries 与
/// WOVisibleSessionCount.count（B3 红线：两处调用点同源——本类型即唯一
/// 事实源）。锁盒承载（GoalService OnChangeBox 模式，Swift 5.9 禁
/// nonisolated 存储属性）。
enum WOSubagentLineageVisibility {
    private static let lock = NSLock()
    /// 已分类集合（含非子代理——防重复头折）。
    private static var classified: Set<String> = []
    /// 子代理 origin 会话 id（隐藏集合）。
    private static var subagentOrigin: Set<String> = []

    /// 判定（侧栏过滤与可见计数共用）。
    static func isSubagentOrigin(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subagentOrigin.contains(id)
    }

    /// 增量分类：只折未分类过的会话头（64KB 档——lineage 恒在头两行）。
    /// 文件 IO 有界（每会话一次、进程生命周期一次）；调用方保证后台线程。
    /// 已删除会话残留的已分类标记无害（不进列表即不参与判定）。
    static func reconcile(sessions: [SessionSummary]) {
        let pendingIDs: [String] = {
            lock.lock()
            defer { lock.unlock() }
            return sessions.map(\.id).filter { !classified.contains($0) }
        }()
        guard !pendingIDs.isEmpty else { return }
        let root = GroupStore.groupSessionsRoot(
            base: WanWoPaths.persistentBase,
            groupID: GroupStore.defaultGroupID)
        var newlyClassified = Set<String>()
        var newlySubagent = Set<String>()
        for id in pendingIDs {
            newlyClassified.insert(id)
            let url = root.appendingPathComponent("\(id).jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let fold = WOSubagentCatalog.foldHead(
                lines: WOSubagentCatalog.headLines(url: url, limit: 64 * 1024))
            if fold.parentSession != nil {
                newlySubagent.insert(id)
            }
        }
        lock.lock()
        classified.formUnion(newlyClassified)
        subagentOrigin.formUnion(newlySubagent)
        lock.unlock()
    }
}
