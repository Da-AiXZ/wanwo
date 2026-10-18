//
//  ReviewTabView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.5（骨架级——§6.6a⑴）】
//  审查页签：横幅（仅显示已跟踪的更改 + 刷新）+ 每文件 diff（路径 +N −M、
//  红/绿行高亮、未修改行折叠块点击展开）；分支下拉/提交或推送/创建 PR =
//  M9.6 占位（禁用态+标注）。右=文件树/树收起 = M9.6（本批骨架级单栏）。
//

import SwiftUI

struct ReviewTabView: View {
    @ObservedObject var environment: AppEnvironment
    @StateObject private var model: ReviewTabModel

    /// 手动展开的折叠块（key = 文件路径 + hunk 序 + fold 行序）。
    @State private var expandedFolds: Set<String> = []
    /// 收起的文件（默认全部展开——文件量少时直读）。
    @State private var collapsedFiles: Set<String> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        let sessionID = WorkspaceRightSidebarView.sessionID(of: environment.selection)
            ?? "m0-shell-test"
        _model = StateObject(wrappedValue: ReviewTabModel(
            sessionID: sessionID,
            workspacePath: environment.guestWorkspacePath(for: sessionID)))
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            content
        }
        .task { await model.refresh() }
    }

    // MARK: - 横幅（仅显示已跟踪的更改 + 刷新 + M9.6 占位簇）

    private var banner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("仅显示已跟踪的更改")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.busy)
                .accessibilityLabel("刷新 diff")
            }
            // M9.6 占位簇（禁用态 + 标注——派单口径）。
            HStack(spacing: 8) {
                Menu {
                    Text("未提交更改")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down.circle")
                            .font(.caption2)
                        Text("分支")
                            .font(.caption)
                    }
                }
                .disabled(true)
                Spacer()
                Button("提交或推送") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                Button("创建 Pull Request") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
            }
            Text("分支切换与提交 / 推送随 M9.6 提供")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .probing:
            ProgressView("正在读取变更…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            VStack(spacing: 10) {
                Image(systemName: "plus.slash.minus")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.green)
                    Text("没有未提交的更改")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                diffList
            }
        }
    }

    private var diffList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.files) { file in
                    fileSection(file)
                }
            }
            .padding(10)
        }
    }

    private func fileSection(_ file: DiffFile) -> some View {
        let collapsed = collapsedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if collapsed { collapsedFiles.remove(file.id) } else { collapsedFiles.insert(file.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("+\(file.addedCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green)
                    Text("−\(file.removedCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.red)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(hunk.header)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                        ForEach(Array(GitDiffParser.foldedLines(hunk.lines).enumerated()),
                                id: \.offset) { lineIndex, presentable in
                            presentationLine(key: "\(file.id)-\(hunkIndex)-\(lineIndex)",
                                             presentable)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func presentationLine(key: String,
                                  _ presentable: DiffPresentationLine) -> some View {
        switch presentable.kind {
        case .visible:
            if let line = presentable.line {
                Text(line.text)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(backgroundColor(for: line.kind))
                    .foregroundStyle(foregroundColor(for: line.kind) ?? Color.primary)
            }
        case .fold(let count):
            let isExpanded = expandedFolds.contains(key)
            Button {
                if isExpanded { expandedFolds.remove(key) } else { expandedFolds.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(count) unmodified lines")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
    }

    private func backgroundColor(for kind: DiffLine.Kind) -> Color? {
        switch kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.12)
        case .context: return nil
        }
    }

    private func foregroundColor(for kind: DiffLine.Kind) -> Color? {
        switch kind {
        case .added: return Color.green
        case .removed: return Color.red
        case .context: return nil
        }
    }
}
