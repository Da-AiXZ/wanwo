//
//  ConversationEmptyStateView.swift
//  WanWo
//
//  【UI 对齐批 1 · B 主区空态项目选择页 · 新写】
//  语义源：dsh ui-workspace/src/client/WorkspacePicker.tsx:225-250（空态注册）
//  + ui-conversation/src/client/skeleton/EmptyHero.tsx:38-62（chip）+
//  ConversationRoot.tsx:293-317（hero 工作区行 → onPick → startSession）。
//
//  形态适配（不可抗力标注，简报 B.5）：dsh 是 Menu 弹层；万我 iPad 空态页 =
//  居中卡片列表（整页），视觉对齐 codex 左栏「项目」观感：
//    · 标题区：万我品牌 + 引导文案「选择一个项目开始对话」；
//    · 项目列表：已有工作区逐行（folder 图标 + title；点击 → startSession）；
//    · 「添加工作区」行恒在列表尾；无工作区时即整页主按钮（dsh
//      addIsTheOnlyEntry :143-157 折算——点击直接进目录流，不弹中间层）；
//    · 添加流：FolderPicker（UIDocumentPicker 既有）→ WorkspaceAdoption.
//      adopt（挂载+激活+registry.create 幂等）→ startSession(新工作区)
//      → 选中会话即关闭空态。
//

import SwiftUI

struct ConversationEmptyStateView: View {
    @ObservedObject var environment: AppEnvironment

    /// 工作区快照（workspaceController.follow 帧驱动——同侧栏纪律）。
    @State private var workspaces: [WorkspaceRecord] = []
    @State private var followCancel: (() -> Void)?
    /// 目录选择 sheet（dsh directory flow 的 UIDocumentPicker 映射）。
    @State private var showingPicker = false
    /// 添加失败的用户可见反馈（alert 呈现后清零）。
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 56)
            // 标题区（简报 B.1）：万我品牌 + 引导文案。
            HStack(spacing: 10) {
                Text("万")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor))
                Text("万我")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("选择一个项目开始对话")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            // 项目列表（dsh WorkspacePicker.tsx:107-114——folder icon + title
            // 逐行；「添加工作区」行恒在列表尾，简报 B.3）。
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(workspaces) { workspace in
                        workspaceRow(workspace)
                    }
                    addWorkspaceRow
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            subscribeWorkspaces()
        }
        .onDisappear {
            followCancel?()
            followCancel = nil
        }
        // 目录流（dsh renderDirectoryFlow 的 UIDocumentPicker 映射；add 行
        // 点击直达——空态页无中间层，简报 B.3）。
        .sheet(isPresented: $showingPicker) {
            FolderPicker { url in
                // picker sheet 退场后一拍执行（同侧栏纪律——iOS 拒绝叠 sheet，
                // 同步处理会被首次选择静默丢失）。
                DispatchQueue.main.async {
                    adopt(url)
                }
            }
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

    // MARK: - 行组件

    /// 项目行（EmptyHero.tsx:38-62 chip 语义折算：folder 图标 + 标题；
    /// 点击 → startSession(wsId)——dsh onPick 终点是「开着的新会话」）。
    private func workspaceRow(_ workspace: WorkspaceRecord) -> some View {
        Button {
            environment.workspaceNavigator.startSession(workspace.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(workspace.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("在「\(workspace.title)」中开始新会话")
    }

    /// 「添加工作区」行（恒在列表尾；无工作区时即整页主按钮——dsh
    /// addIsTheOnlyEntry 折算：点击直接进目录流，不弹中间层）。
    private var addWorkspaceRow: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text("添加工作区")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加工作区")
    }

    // MARK: - 数据与操作

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

    /// 添加流（简报 B.4）：FolderPicker → adopt（挂载+激活+create 幂等）
    /// → startSession(新工作区) → 选中会话即关闭空态。
    private func adopt(_ url: URL) {
        do {
            let workspace = try WorkspaceAdoption.adopt(
                pickedURL: url, environment: environment)
            environment.workspaceNavigator.startSession(workspace.id)
        } catch {
            errorText = "添加工作区失败：\(String(describing: error))"
        }
    }
}
