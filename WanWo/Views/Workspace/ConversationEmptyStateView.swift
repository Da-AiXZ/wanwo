//
//  ConversationEmptyStateView.swift
//  WanWo
//
//  【UI 对齐批 2 · hero 空态重做（替换整页项目选择卡）】
//  语义源（dsh ui-conversation 逐条核实）：
//    · ConversationRoot.tsx:293-317 —— hero 空态同屏三件：品牌/标题区 +
//      工作区行（heroWorkspaceRow）+ composer；
//    · EmptyHero.tsx:38-62 WorkspaceChip —— 工作区胶囊（folder 图标 +
//      项目名/引导语 + chevron）；
//    · ConversationRoot.tsx:318-336（inert 传参）+ InputBar.tsx:125-131
//      workspaceTrigger + ComposerContentEditable.tsx:44 —— 无工作区：
//      composer 同一个框 inert（contentEditable=false、框内 placeholder
//      「选择一个工作区开始」，点击整个框 = 打开工作区选择菜单）；
//    · dsh 工作区菜单：列表行 = folder + title + 当前项勾选，
//      尾行「添加工作区…」。
//  添加流：菜单尾行 → 输入项目名卡（TextField + 确认/取消，过渡动画）→
//  WorkspaceAdoption.adopt(name:environment:)（接口预锁定，
//  WorkspaceNavigator 侧实现中）→ startSession(新工作区) → 会话打开即
//  hero 退场（RootView.detail 按 selection 挂载点不动，形态自换）。
//  动画纪律：交互变化一律 withAnimation + spring(response≈0.3,
//  dampingFraction≈0.85)；菜单展开 = scale（锚定胶囊/卡底缘）+ opacity；
//  hero ↔ 会话切换 = opacity 渐变（transition 挂本视图根层）。
//

import SwiftUI

struct ConversationEmptyStateView: View {
    @ObservedObject var environment: AppEnvironment

    /// 交互动画标准（任务 3：spring 丝滑，response≈0.3 / damping≈0.85）。
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)
    /// 工作区菜单宽（dsh anchored popup 家族形态；iPad 弹层惯例宽度）。
    private static let menuWidth: CGFloat = 320

    /// 工作区快照（workspaceController.follow 帧驱动——同侧栏纪律，原样迁移）。
    @State private var workspaces: [WorkspaceRecord] = []
    @State private var followCancel: (() -> Void)?

    /// 工作区选择菜单开合。
    @State private var menuOpen = false
    /// 「添加工作区…」输入项目名卡开合。
    @State private var showingAddFlow = false
    /// 新工作区名草稿。
    @State private var newWorkspaceName = ""
    /// hero composer 草稿（有工作区时可输入；发送 = startSession——
    /// 草稿交接缝缺失，见文件尾「接口协调」注）。
    @State private var heroDraft = ""
    /// hero composer 卡高度（菜单锚定其上缘向上生长的度量）。
    @State private var composerHeight: CGFloat = 0
    /// 添加失败的用户可见反馈（alert 呈现后清零；原整页卡逻辑迁移）。
    @State private var errorText: String?

    /// 焦点工作区（胶囊标题）：selectedWorkspaceID 优先（adopt/侧栏写入），
    /// 回落快照首项（Host 工作区序）。
    private var featuredWorkspace: WorkspaceRecord? {
        if let id = environment.selectedWorkspaceID,
           let hit = workspaces.first(where: { $0.id == id }) {
            return hit
        }
        return workspaces.first
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            heroStack
            // 捕获层（dsh outside click）：菜单开时全屏拦截，点外收起。
            if menuOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Self.spring) { menuOpen = false }
                    }
                    .transition(.opacity)
                    .zIndex(1)
            }
            // 添加流（模态层：淡遮罩 + 居中卡；遮罩 opacity、卡片
            // scale+opacity——两个条件子节点各自带 transition，进出成对）。
            if showingAddFlow {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { cancelAddFlow() }
                    .transition(.opacity)
                    .zIndex(3)
            }
            if showingAddFlow {
                addWorkspaceCard
                    .transition(.scale(scale: 0.96, anchor: .center)
                        .combined(with: .opacity))
                    .zIndex(4)
            }
        }
        .transition(.opacity)
        .task {
            subscribeWorkspaces()
        }
        .onDisappear {
            followCancel?()
            followCancel = nil
        }
        .alert("添加工作区失败",
               isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - hero 同屏三件（品牌 + 胶囊 + composer）

    /// hero 主体（居中纵列；菜单弹层锚点挂在**内层 VStack** 上——其底缘 =
    /// composer 底缘，overlay bottom + composer 高度内边距 = 菜单悬于
    /// composer 上方；外层 .frame(maxHeight:) 之后挂会把锚点拉到全屏底）。
    private var heroStack: some View {
        VStack(spacing: 0) {
            brandHeader
            workspaceChip
                .padding(.top, 28)
            heroComposer
                .padding(.top, 14)
        }
        // 工作区菜单（scale 锚定底缘 + opacity；捕获层是 ZStack 兄弟位
        // zIndex 1——菜单开合时本层抬到 zIndex 2，菜单行点击不被捕获层拦截）。
        .overlay(alignment: .bottom) {
            if menuOpen {
                workspaceMenu
                    .padding(.bottom, composerHeight + 14)
                    .transition(.scale(scale: 0.95, anchor: .bottom)
                        .combined(with: .opacity))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(menuOpen ? 2 : 0)
    }

    /// 品牌区（原「万/万我」视觉保留；dsh hero 标题位）。
    private var brandHeader: some View {
        VStack(spacing: 12) {
            Text("万")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.accentColor))
            Text("万我")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    /// 工作区胶囊（EmptyHero WorkspaceChip：folder + 项目名/引导语 +
    /// chevron；点击开工作区菜单——首条消息前可换项目/建项目）。
    private var workspaceChip: some View {
        Button {
            withAnimation(Self.spring) { menuOpen.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(featuredWorkspace == nil
                                     ? Color.secondary : Color.accentColor)
                Text(featuredWorkspace?.title ?? "选择工作区")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemFill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(featuredWorkspace.map { "当前工作区 \($0.title)，切换工作区" }
                            ?? "选择工作区")
    }

    // MARK: - composer（无工作区 inert / 有工作区可输入；同一 dock 卡形态）

    /// 占位文案（dsh 逐字）：inert =「选择一个工作区开始」；active =
    /// 「描述你想要构建的内容… / 调用指令 @ 文件或对话」。
    private var heroPlaceholder: String {
        featuredWorkspace == nil
            ? "选择一个工作区开始"
            : "描述你想要构建的内容… / 调用指令 @ 文件或对话"
    }

    @ViewBuilder
    private var heroComposer: some View {
        if featuredWorkspace == nil {
            // inert 态（ConversationRoot.tsx:318-336）：不可输入、不可聚焦；
            // 点击整个框 = 打开工作区选择菜单。
            Button {
                withAnimation(Self.spring) { menuOpen = true }
            } label: {
                composerCard {
                    Text(heroPlaceholder)
                        .font(.body)
                        .foregroundStyle(.placeholder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择一个工作区开始")
        } else {
            // 可输入态：文本区 + 底行（右侧圆形发送；发送 = startSession
            // 打开该工作区会话——hero 随 selection 切换退场）。
            composerCard {
                TextField(heroPlaceholder, text: $heroDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .disabled(featuredWorkspace == nil)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button {
                        sendHeroDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(heroDraft.trimmingCharacters(in: .whitespaces)
                                  .isEmpty)
                    .accessibilityLabel("开始会话")
                }
                .padding(.top, 12)
            }
        }
    }

    /// dock 卡形态（InputBar.module.css .card 语义：大圆角、上 pad 10、
    /// 文本区与底行间距 12——ChatView inputBar 同一形态，双处一致）。
    private func composerCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 12))
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
            // 菜单锚定度量（composer 卡实际高度）。
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: HeroComposerHeightKey.self,
                                           value: geo.size.height)
                }
            )
            .onPreferenceChange(HeroComposerHeightKey.self) { composerHeight = $0 }
    }

    private struct HeroComposerHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func sendHeroDraft() {
        guard let featured = featuredWorkspace else { return }
        // 草稿文本暂不跨视图交接（AppEnvironment 待挂 pendingFirstDraft 缝，
        // 见文件尾接口协调注）；导航本身与 dsh onPick 终点一致。
        environment.workspaceNavigator.startSession(featured.id)
    }

    // MARK: - 工作区菜单（列表行 + 「添加工作区…」尾行）

    private var workspaceMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(workspaces) { workspace in
                menuRow(workspace)
            }
            if !workspaces.isEmpty {
                Divider()
                    .padding(.vertical, 4)
            }
            addWorkspaceMenuRow
        }
        .padding(8)
        .frame(width: Self.menuWidth, alignment: .leading)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }

    /// 工作区行（folder + title；当前项勾选——dsh menuitemradio 语义）。
    private func menuRow(_ workspace: WorkspaceRecord) -> some View {
        let isCurrent = workspace.id == featuredWorkspace?.id
        return Button {
            withAnimation(Self.spring) { menuOpen = false }
            environment.workspaceNavigator.startSession(workspace.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(workspace.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isCurrent ? Color.accentColor.opacity(0.08)
                                  : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("在「\(workspace.title)」中开始新会话")
    }

    /// 「添加工作区…」尾行（恒在列表尾；无工作区时即菜单唯一项——
    /// dsh addIsTheOnlyEntry 语义）。
    private var addWorkspaceMenuRow: some View {
        Button {
            withAnimation(Self.spring) {
                menuOpen = false
                showingAddFlow = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                Text("添加工作区…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加工作区")
    }

    // MARK: - 添加流（输入项目名卡 → adopt → startSession）

    private var addWorkspaceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加工作区")
                .font(.headline)
            TextField("输入项目名", text: $newWorkspaceName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmAddWorkspace() }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { cancelAddFlow() }
                    .buttonStyle(.bordered)
                Button("确认") { confirmAddWorkspace() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newWorkspaceName.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(Color(.systemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        // 模态卡居中（根 ZStack 条件子节点挂此 frame）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cancelAddFlow() {
        withAnimation(Self.spring) {
            showingAddFlow = false
            newWorkspaceName = ""
        }
    }

    /// 确认：WorkspaceAdoption.adopt(name:environment:)（接口预锁定）→
    /// startSession(新工作区)（dsh 添加流终点语义）。失败保持卡片打开
    /// （可改名重试），alert 呈现原因。
    private func confirmAddWorkspace() {
        let name = newWorkspaceName.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let workspace = try WorkspaceAdoption.adopt(
                name: name, environment: environment)
            withAnimation(Self.spring) {
                showingAddFlow = false
                newWorkspaceName = ""
            }
            environment.workspaceNavigator.startSession(workspace.id)
        } catch {
            errorText = "添加工作区失败：\(String(describing: error))"
        }
    }

    // MARK: - 数据订阅（原整页卡逻辑迁移，勿丢）

    /// workspaceController.follow 订阅（B3 follow 快照流——同侧栏纪律）。
    private func subscribeWorkspaces() {
        guard followCancel == nil else { return }
        let (stream, cancel) = environment.workspaceController.follow()
        followCancel = cancel
        Task { @MainActor in
            for await frame in stream {
                workspaces = frame.workspaces
            }
        }
    }
}

// MARK: - 接口协调（呈报主理人，本域不可自行改动）
//
//  1. WorkspaceAdoption.adopt 签名切换：本文件按预锁定新签名
//     adopt(name: String, environment: AppEnvironment) throws -> WorkspaceRecord
//     调用；WorkspaceNavigator.swift 旧签名 adopt(pickedURL:environment:)
//     由负责工程师同步切换（两侧合流前 CI 会有一个不匹配窗口）。
//  2. hero 草稿交接：hero composer 有工作区时发送只做 startSession，
//     草稿文本不进新会话输入框——需要 AppEnvironment 暴露
//     pendingFirstDraft: String?（ChatView init/onAppear 消费后清零）。
//     未接线前行为 = dsh onPick 同款「开新会话不带稿」。
//  3. hero ↔ 会话切换 opacity 渐变：transition 已挂本视图根层，生效还需
//     RootView.detail 的 selection 分支切换包 withAnimation（App/ 域）。
