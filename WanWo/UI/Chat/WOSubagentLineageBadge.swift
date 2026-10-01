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
//    · 运行状态刷新：dsh 订阅驱动 → sessionsRevision 失效重扫（用户
//      反馈8 刷新缝根因修复）+ running>0 期 1s 轮询（对位 dsh :652-656
//      的 1s now 步进）。
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
        // 刷新缝挂 Group 外层（不可见期也要听失效信号——首个子会话回合中
        // 诞生时徽章还不可见，监听挂 if 内会永久失聪，反馈8 复发）。
        Group {
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
        // 首扫 + 会话切换换身份重扫。
        .task(id: sessionId) { await rescan() }
        // 刷新缝（反馈8 根因修复）：订阅环境会话列表失效信号——回合中
        // 新建子会话（sessionsRevision bump）触发重扫，不再是
        // "仅会话打开扫一次"。
        .onReceive(environment.$sessionsRevision) { _ in
            Task { await rescan() }
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
