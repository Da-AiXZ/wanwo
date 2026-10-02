//
//  WOSubagentLineageBadge.swift
//  WanWo
//
//  【M7-Fix2 批2 B1 2026-09-29】会话标题栏子代理 count 徽章 + 下拉目录树。
//  座位组卡（WOSubagentCatalogCard）退役后的新入口（用户问题一/二：
//  按 dsh 截图点名的标题栏徽章形态）。
//
//  dsh 语义源（铁律先查，ui-subagent/src/client/SubagentHeaderLineage.tsx
//  全文逐段对拍，逐段对拍表见 analysis/m7-fix2/e3-report.md）：
//    · count 徽章（variant 'count'，普通会话标题右侧）：running>0 → 前缀
//      ongoing 状态点 + "{count} 个子代理，正在运行"（count=runningCount）；
//      否则 "{count} 个子代理"（count=descendantCount）+ chevron-down。
//    · 徽章可见性 :671-685：有子女证据（目录 entries>0 / 后代计数>0 /
//      加载出错）才渲染，空 = 不渲染；descendantCount = max(healthy 直接行,
//      索引后代)（:516 bootstrap 双源取大）。
//    · 下拉目录树（CatalogRows）：行=状态点(running?ongoing:done)+
//      label+secondary=[title, mode, activity].join(' · ')；hasChildren 行带
//      展开箭头（递归 level+1）；诊断行三态 disabled；加载行；点行
//      openChild 并收起目录（:326-329）。
//  平台差异（触屏裁剪，逐项登记 e3-report.md）：
//    · hover 开合（150ms/120ms）与键盘树导航 → 裁剪为点击开合。
//    · portal 定位（trigger rect+viewport margin :469-480）→ SwiftUI
//      popover 自带锚定与屏边规避（iPad popover / iPhone 折算 sheet）。
//    · metrics 段（token 总数/活跃时长）→ 裁剪：万我会话摘要无
//      tokenUsage/subagentTiming 投影源（Core/ 禁碰）。
//    · switcher（子会话视角切父/兄弟）→ 裁剪：子会话以 sheet 回放承载。
//    · 运行状态刷新：dsh 订阅驱动 → SessionStore 索引失效信号重扫
//      （appState.sessionListEpoch——【批5 根因②】原 sessionsRevision 不含
//      子会话回合中创建的失效信号，登记见下）+ running>0 期 1s 轮询
//      （对位 dsh :652-656 的 1s now 步进）。
//

import SwiftUI

// MARK: - 会话标题栏子代理徽章（dsh CatalogDropdown variant 'count'）

struct WOSubagentLineageBadge: View {
    let environment: AppEnvironment
    let sessionId: String

    @State private var snapshot: WOSubagentCatalog.ScanOutput = .empty
    @State private var scanning = false
    @State private var menuOpen = false
    /// 展开分支集合（dsh expanded ReadonlySet<SessionId>）。
    @State private var expandedBranches: Set<String> = []
    @State private var replayTarget: WOSubagentCatalog.ChildRecord?
    /// 重扫序列令牌（并发重扫只认最新）。
    @State private var scanSeq = 0
    /// epoch 防抖合并任务（写柄追加逐事件 bump epoch——只认窗内最后一次）。
    @State private var rescanDebounce: Task<Void, Never>?
    /// 防抖首推迟时间戳（【批5 复审修 P1-1】deadline 兜底基准；nil = 无挂起推迟）。
    @State private var deferStart: Date?

    /// dsh :516 bootstrap 双源取大（直接行已见 vs 索引聚合——目录可以
    /// 先于基线到达，绝不短算已可见行）。
    private var descendantCount: Int {
        max(snapshot.directChildren.count, snapshot.descendants.count)
    }
    private var runningCount: Int { snapshot.descendants.runningCount }

    /// dsh :671-685：有子女证据才渲染（entries>0 / 后代计数>0），空=不渲染
    /// （无子女会话的加载快照不构成证据——防选择会话即刷新的动作闪入闪出）。
    private var visible: Bool { descendantCount > 0 }

    var body: some View {
        // 【批5 根因①】扫描驱动必须挂在"无条件出现"的真实容器上：
        // Group 的修饰符语义 = 下沉应用到每个子视图——visible=false 时
        // if 分支是 EmptyView、永不 appear，挂在 Group 上的 .task /
        // .onReceive 随之永不激活 → 首扫永不发生 → snapshot 恒 empty
        // → visible 恒 false（死锁：真机徽章永不显示的病根；此前批2
        // 把监听从 if 内挪到 Group 外层并未改变该语义）。ZStack 是真实
        // 布局节点（内容为空同样 appear），驱动挂它恒活——对位 dsh
        // SubagentHeaderLineage：React 组件恒挂载、空时 render null 而
        // hooks 照常运行；SwiftUI 的等价物 = 驱动挂无条件出现的容器。
        ZStack {
            if visible {
                badgeButton
                    .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
                        catalogMenu
                    }
                    .sheet(item: $replayTarget) { target in
                        WOSubagentReplayView(child: target)
                    }
            }
        }
        // 首扫 + 会话切换换身份重扫（立即执行，不走防抖）。
        .task(id: sessionId) { await rescan() }
        // 【批5 根因②】刷新缝改听 appState.sessionListEpoch（防抖+2s 兜底）：
        // 这是 SessionStore 建索引钩子的唯一汇聚信号（database.onIndexChanged
        // → externalListSignal → bumpSessionList，见 SessionStore init），
        // 覆盖子会话创建 / 写柄追加 / 标题落盘 / 建 / 删全部写路径 ⊇
        // sessionsRevision。原 onReceive(environment.$sessionsRevision) 对
        // 回合中诞生的子会话恒失聪——makeSubagentChildStack 经
        // SessionStore.createSession(withID:) 直写索引，失效信号只走
        // epoch；sessionsRevision 仅由 AppEnvironment 用户建删三处直 bump
        //（init:918/:959/:497），与子会话创建零交集。
        // 防抖必要：写柄追加逐事件 bump epoch，流式回合高频；全量重扫
        // 有界（64KB 头折/文件）但不必逐事件跑（scanSeq 保证并读不串台）。
        // 【批5 复审修 P1-1】trailing-reset 防抖有 2s 硬截止兜底（长流中段
        // 诞生的孩子最迟 2s 现形）——机制见 scheduleRescan 注释。
        .onReceive(environment.appState.$sessionListEpoch) { _ in
            scheduleRescan()
        }
        // 运行期 1s 轮询（对位 dsh :652-656 running>0 的 1s 步进；
        // dsh 为订阅驱动，万我 runtime 无发布面——登记）。
        .task(id: runningCount > 0) { await pollWhileRunning() }
    }

    // MARK: 徽章（dsh :751-766 count 触发器）

    private var badgeButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                if runningCount > 0 {
                    // 前缀 ongoing 状态点（dsh :755-759 activitySlot）。
                    WOStateDot(state: .ongoing, size: 6)
                }
                Text(runningCount > 0
                     ? "\(runningCount) 个子代理，正在运行"
                     : "\(descendantCount) 个子代理")
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.labelSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(WOAlias.labelTertiary)
                    .rotationEffect(.degrees(menuOpen ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: menuOpen)
            }
            // 触屏可点目标 ≥44pt（标题栏行高 44 内满高命中）。
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(runningCount > 0
                            ? "\(runningCount) 个子代理，正在运行"
                            : "\(descendantCount) 个子代理")
    }

    // MARK: 下拉目录树（dsh CatalogRows portal menu）

    private var catalogMenu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if scanning && snapshot.directChildren.isEmpty {
                    // dsh 加载行（CatalogLoadingRows → 'loading.label'）。
                    loadingRow
                }
                ForEach(snapshot.directChildren) { record in
                    WOSubagentCatalogRow(
                        record: record,
                        level: 1,
                        childrenOf: { snapshot.childrenByParent[$0] ?? [] },
                        expanded: $expandedBranches,
                        onOpen: { target in
                            // dsh :326-329：点行 openChild 并收起目录。
                            replayTarget = target
                            menuOpen = false
                        })
                }
            }
            .padding(.vertical, 6)
        }
        // dsh :472 width = min(336, viewport − 32)；万我 iPad-only
        //（TARGETED_DEVICE_FAMILY=2，viewport ≥ 768）→ 336 恒不越屏。
        .frame(width: 336)
        .frame(maxHeight: 420)
        .accessibilityLabel("子代理会话")
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 44, height: 28)
            Text("正在加载子代理…")
                .font(.system(size: 13))
                .foregroundColor(WOAlias.labelTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
    }

    // MARK: 数据（扫描编排；IO 全程后台）

    /// 防抖合并窗（常规；epoch 被流式写柄逐事件 bump，合并到窗尾只跑一次）。
    private static let rescanWindow: TimeInterval = 0.25
    /// 兜底硬截止（【批5 复审修 P1-1】）：首次被推迟起最迟 2s 强制执行。
    private static let rescanDeadline: TimeInterval = 2.0

    /// epoch 防抖重扫 + deadline 兜底：
    /// trailing-reset 型防抖在连续长流（chunk 间隔常小于 250ms 窗长）中会被
    /// 无限重置——首个孩子若诞生于不间断长流中段，徽章首现将推迟到事件
    /// 间隙/流结束，与"即时出现"承诺不符。兜底：从第一次被推迟起算 2s
    /// 硬截止，窗长取 min(常规 250ms, 距 deadline 剩余)——deadline 先到即
    /// 提前执行。保证①流式高峰期孩子诞生 → 徽章最迟 2s 出现；②正常间隙
    /// 仍 250ms 合并（省电意义保留）。
    /// 重入/取消安全：deferStart 触碰全程 MainActor（View 方法 + Task 继承
    /// 外围隔离）；旧 Task 先 cancel 再换新，迟到旧任务与 scanSeq 令牌共同
    /// 保证并读不串台；rescan 实际执行时清零 deferStart 开新窗。
    private func scheduleRescan() {
        let now = Date()
        let deadlineRemaining: TimeInterval
        if let start = deferStart {
            deadlineRemaining = Self.rescanDeadline - now.timeIntervalSince(start)
        } else {
            deferStart = now
            deadlineRemaining = Self.rescanDeadline
        }
        let delay = min(Self.rescanWindow, max(0, deadlineRemaining))
        rescanDebounce?.cancel()
        rescanDebounce = Task(priority: .userInitiated) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            deferStart = nil
            await rescan()
        }
    }

    /// 重扫：会话快照（同步缓存面）+ runtime listings（含后代/诊断）→
    /// 后台全量头扫描 → ScanOutput。序列令牌防并发串台。
    private func rescan() async {
        scanSeq += 1
        let seq = scanSeq
        scanning = snapshot.directChildren.isEmpty
        // 【批3 A4.1】SessionStore 为 actor——跨隔离取数补 await（原同步
        // 调用缺 await；AppEnvironment:874 为既有正确惯例。419D6993 场景
        // 徽章空态排查见报告 A4.1 节排除表）。
        let sessions = await environment.sessionStore.listSessions()
        let listings = await environment.subagentRuntime
            .listAgents(callerSessionId: sessionId, includeDescendants: true)
        let parentID = sessionId
        let loaded = await Task.detached(priority: .userInitiated) {
            WOSubagentCatalog.scan(rootID: parentID,
                                   sessions: sessions,
                                   listings: listings)
        }.value
        guard seq == scanSeq else { return }
        snapshot = loaded
        scanning = false
        // 收缩失效：证据消失（子会话全删）即收起，动作不再闪挂空树。
        if max(loaded.directChildren.count, loaded.descendants.count) == 0 {
            menuOpen = false
            expandedBranches.removeAll()
        }
    }

    /// running>0 期 1s 轮询（状态变化/新子会话拾取；任务随 false 取消）。
    private func pollWhileRunning() async {
        guard runningCount > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await rescan()
        }
    }
}

// MARK: - 目录树行（dsh CatalogRows child/diagnostic 行折算；递归 level+1）

struct WOSubagentCatalogRow: View {
    let record: WOSubagentCatalog.ChildRecord
    let level: Int
    /// 逐父取子（整树快照查询闭包——递归渲染面）。
    let childrenOf: (String) -> [WOSubagentCatalog.ChildRecord]
    @Binding var expanded: Set<String>
    let onOpen: (WOSubagentCatalog.ChildRecord) -> Void

    private var isRunning: Bool { record.runtimeStatus == "running" }
    private var isDiagnostic: Bool { record.diagnosticReason != nil }
    private var children: [WOSubagentCatalog.ChildRecord] { childrenOf(record.id) }
    private var hasChildren: Bool { !children.isEmpty }
    private var isExpanded: Bool { expanded.contains(record.id) }

    /// secondary = [summary?.title, mode, activity].join(' · ')
    /// （dsh :304-306；one-shot 无 runtime 行 → activity 不出词）。
    private var secondary: String? {
        var parts: [String] = []
        if let title = record.title, !title.isEmpty { parts.append(title) }
        parts.append(WOSubagentCatalog.modeText(for: record))
        if let activity = WOSubagentCatalog.activityText(for: record) {
            parts.append(activity)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if hasChildren && isExpanded {
                ForEach(children) { child in
                    WOSubagentCatalogRow(record: child,
                                         level: level + 1,
                                         childrenOf: childrenOf,
                                         expanded: $expanded,
                                         onOpen: onOpen)
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Group {
                if hasChildren {
                    // dsh :366-374 disclosure：展开/收起分支（左列独立命中，
                    // 44pt 列宽 = 触屏可点目标）。
                    Button {
                        if isExpanded {
                            expanded.remove(record.id)
                        } else {
                            expanded.insert(record.id)
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(WOAlias.labelTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.2), value: isExpanded)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded
                                        ? "收起 \(record.label) 的下级子代理"
                                        : "展开 \(record.label) 的下级子代理")
                } else {
                    // dsh :363-364：叶行保留 disclosure 空位对齐。
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            WOStateDot(state: isDiagnostic ? .error
                        : (isRunning ? .ongoing : .done),
                       size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.label)
                    .font(.system(size: 13))
                    .foregroundColor(isDiagnostic
                                     ? WOAlias.labelTertiary : WOAlias.labelPrimary)
                    .lineLimit(1)
                if let secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundColor(WOAlias.labelTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(level - 1) * 14) // dsh 递归 level+1 缩进
        .frame(minHeight: 44) // 触屏可点目标 ≥44pt
        .contentShape(Rectangle())
        .opacity(isDiagnostic ? 0.8 : 1)
        .onTapGesture {
            // 诊断行 disabled（dsh aria-disabled，不可导航；"remain
            // readable but disabled"）。
            guard !isDiagnostic else { return }
            onOpen(record)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isDiagnostic
                           ? WOSubagentCatalog.diagnosticText(record.diagnosticReason ?? "")
                           : "打开执行记录")
    }
}
