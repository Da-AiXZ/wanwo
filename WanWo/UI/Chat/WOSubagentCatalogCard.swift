//
//  WOSubagentCatalogCard.swift
//  WanWo
//
//  【M7-E3 2026-09-29】会话内子代理记录卡 + 子会话只读回放（最小面）。
//
//  dsh 语义源（铁律先查，ui-subagent 包 README/subagent-lineage.ts 逐点）：
//    · 父会话内可浏览"subagent-origin 后代"目录（README :28——header lineage
//      trigger 打开 descendant catalog，行=mode + running/inactive activity +
//      log-backed title）；行无 label 回退 session id（:32）；损坏/缺失行
//      "remain readable but disabled"。
//    · one-shot 子会话打开 = 只读形态，transcript 标识为"已完成的执行记录"
//      （README :12 "A one-shot child always opens a read-only composer
//      identifying the transcript as a completed execution record"）。
//    · 目录无持久结果语义（README :105 Known Limitations——"activity and
//      timing do not distinguish completion, failure, or cancellation"）→
//      one-shot 行**不做完成/失败断言**，只标"执行记录"。
//    · subagent-origin 会话行在普通侧栏省略，目录是唯一入口（README :12）→
//      侧栏挂子项不做（与 dsh 同语义，登记）。
//  平台差异登记（analysis/m7-fix/e3-report.md）：目录入口从 session header
//  下移到会话内座位组卡（万我会话头无 lineage 面包屑基建，最小面裁剪）；
//  键盘树导航/展开分支/FIFO 续聊/独立 Stop 均不做（只读最小面）。
//
//  数据面（全部现成缝，零 Core/Features/AppEnvironment 改动）：
//    · 枚举 = 子会话日志头 lineage 事件（SubagentLineage.read；创建窗口
//      lineage 是子日志第一条事件，AppEnvironment.makeSubagentChildStack
//      :1629-1635 实证——头部 64KB 读必然命中）+ descriptor（第二条）。
//    · 状态 = SubagentRuntime.listAgents(callerSessionId:includeDescendants:)
//      （running/idle/ready 三档；one-shot 不驻留 runtime，按 dsh 只标形态）。
//    · 回放 = SessionLogScanner 全量 scan（TrajectoryTabView.TrajectoryLoader
//      同款只读纪律）+ ConversationProjector.project(events:registry:…)
//      纯函数直接喂子会话事件（replay 打开共用同一折叠规则，:120-131 注释
//      "replay 打开共用" 语义 1:1）。
//

import SwiftUI

// MARK: - 目录扫描（纯数据面，单测缝）

enum WOSubagentCatalog {

    /// 目录行（dsh LineageEntry + descriptor 投影）。
    struct ChildRecord: Identifiable, Equatable {
        let id: String
        /// descriptor.label ?? 会话标题回退 ?? session id（README :32 回退序）。
        let label: String
        /// one-shot / continuable（SubagentDescriptor.Mode 语义）。
        let mode: String
        let depth: Int
        let createdAt: Date
        /// runtime 状态（running/idle/ready）；one-shot 无 runtime 行 = nil。
        let runtimeStatus: String?
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

    /// 枚举 parent 的直接子代理（同步磁盘面；调用方在后台线程执行）。
    static func children(of parentId: String,
                         sessions: [SessionSummary],
                         runtimeStatuses: [String: String]) -> [ChildRecord] {
        let root = GroupStore.groupSessionsRoot(
            base: WanWoPaths.persistentBase,
            groupID: GroupStore.defaultGroupID)
        var out: [ChildRecord] = []
        for summary in sessions where summary.id != parentId {
            let url = root.appendingPathComponent("\(summary.id).jsonl")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else { continue }
            // 头部 64KB 足够覆盖 lineage+descriptor（前两条事件）。
            let head = data.prefix(64 * 1024)
            let lines = String(decoding: head, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            let fold = foldHead(lines: lines)
            guard fold.parentSession == parentId else { continue }
            let label = fold.label
                ?? summary.title
                ?? summary.id // dsh README :32 无 label 行回退 session id
            out.append(ChildRecord(
                id: summary.id,
                label: label,
                mode: fold.mode ?? "one-shot",
                depth: fold.depth ?? 1,
                createdAt: summary.createdAt,
                runtimeStatus: runtimeStatuses[summary.id]))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// 行状态文案（dsh README :105——无持久结果语义：one-shot 只标"执行记录"
    /// 不做完成/失败断言；continuable 用 runtime 三档原词）。
    static func statusText(for record: ChildRecord) -> String {
        if record.mode == SubagentDescriptor.Mode.oneShot.rawValue {
            return "执行记录"
        }
        return record.runtimeStatus ?? "ready"
    }
}

// MARK: - 会话内子代理记录卡

/// 座位组卡片：标题行「子代理记录 · N」+ 目录行（label/时间/形态/状态），
/// 点行 → 子会话只读回放（sheet）。无子代理不渲染（dsh "empty renders
/// nothing" 语义，todo 卡同款口径）。
struct WOSubagentCatalogCard: View {
    let environment: AppEnvironment
    let sessionId: String

    @State private var records: [WOSubagentCatalog.ChildRecord] = []
    @State private var replayTarget: WOSubagentCatalog.ChildRecord?

    var body: some View {
        if !records.isEmpty {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WOAlias.stateBusinessPrimary)
                Text("子代理记录 · \(records.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WOAlias.labelPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ForEach(records) { record in
                Button {
                    replayTarget = record
                } label: {
                    row(record)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开子代理「\(record.label)」执行记录")
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(WOAlias.bgLayer1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WOAlias.borderL1, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .task(id: sessionId) { await reload() }
        .sheet(item: $replayTarget) { target in
            WOSubagentReplayView(child: target)
        }
    }

    private func row(_ record: WOSubagentCatalog.ChildRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: record.mode == SubagentDescriptor.Mode.oneShot.rawValue
                    ? "record.circle" : "bubble.left.and.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(WOAlias.labelSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label)
                    .font(.system(size: 13))
                    .foregroundColor(WOAlias.labelPrimary)
                    .lineLimit(1)
                Text(record.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(WOSubagentCatalog.statusText(for: record))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(record.runtimeStatus == "running"
                                 ? WOAlias.stateBusinessPrimary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule()
                    .fill((record.runtimeStatus == "running"
                           ? WOAlias.stateBusinessPrimary : Color.secondary).opacity(0.12)))
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    /// 枚举 + runtime 状态合并（IO 在 Task 内执行——不卡主线程）。
    private func reload() async {
        let sessions = await environment.sessionStore.listSessions()
        let listings = await environment.subagentRuntime
            .listAgents(callerSessionId: sessionId, includeDescendants: false)
        var statuses: [String: String] = [:]
        for listing in listings { statuses[listing.subagentId] = listing.status }
        let parentId = sessionId
        let loaded = await Task.detached(priority: .userInitiated) {
            WOSubagentCatalog.children(of: parentId, sessions: sessions,
                                       runtimeStatuses: statuses)
        }.value
        withAnimation(.easeInOut(duration: 0.2)) { records = loaded }
    }
}

// MARK: - 子会话只读回放

/// 子会话只读回放（dsh one-shot "read-only composer identifying the
/// transcript as a completed execution record" 的最小承载）：SessionLogScanner
/// 全量 scan（TrajectoryLoader 只读纪律）→ ConversationProjector.project
/// 纯函数折叠（registry=nil——presentCall 复现仅缺工具卡标题，回放退化可接受，
/// 登记）→ 简化只读行渲染。
struct WOSubagentReplayView: View {
    let child: WOSubagentCatalog.ChildRecord

    @Environment(\.dismiss) private var dismiss
    @State private var bubbles: [ConversationProjector.Bubble] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    Text(loadError)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
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
            .navigationTitle(child.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// 回放装载结果（String 不满足 Result 的 Error 关联值约束——CI修19）。
    private enum ReplayLoadOutcome {
        case loaded([SessionEvent])
        case failed(String)
    }

    private func load() async {
        let childId = child.id
        // 只读 replay（TrajectoryTabView :464 同款纪律：detached 只回事件，
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

    /// 只读行（dsh 回放是 transcript 呈现，非交互——纯文本形态）。
    @ViewBuilder
    private func replayRow(_ bubble: ConversationProjector.Bubble) -> some View {
        switch bubble.kind {
        case .user(let text, _):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(WOAlias.labelPrimary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(WOAlias.bgLayer3))
            }
        case .assistant(let text):
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelPrimary)
                .lineSpacing(4)
        case .reasoning(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.leading, 12)
        case .tool(let card):
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(card.title.isEmpty ? card.name : card.title)
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineLimit(1)
            }
            .padding(.leading, 12)
        case .command(let kind, let text):
            VStack(alignment: .leading, spacing: 2) {
                Text(kind)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(WOAlias.labelSecondary)
            }
            .padding(.leading, 12)
        case .note(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.labelTertiary)
        case .turnUsage:
            EmptyView()
        }
    }
}
