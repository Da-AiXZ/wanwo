//
//  WorkspaceFileTabView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.1（codex 截图「文件」全交互）】
//  双栏：左 = 内容主区（宽），右 = 文件树窄栏（筛选框 + 目录 chevron 折叠 +
//  文件行）；空态 = "打开文件 从工作区目录树中选择文件"；顶部左侧工作区根
//  路径、右侧复制路径钮；面包屑；md 默认渲染视图 + 查看源代码/查看预览切换
//  （源码带行号）；代码文件语法高亮（轻量实现）+ 行号；树收起钮 = 树整栏
//  收起、内容全宽。
//  「打开（系统方式）」不做（用户 2026-09-16 裁定）。
//

import SwiftUI

struct WorkspaceFileTabView: View {
    @ObservedObject var environment: AppEnvironment
    @StateObject private var tree = WorkspaceFileTreeModel()
    /// 选中文件（相对工作区根路径）。
    @State private var selectedPath: String?
    /// 文件内容快照（选中时加载）。
    @State private var fileContent: String?
    @State private var fileLoadError: String?
    /// md 渲染/源码切换（默认渲染视图）。
    @State private var showSource = false
    @State private var copiedToast = false

    private var sessionID: String? {
        WorkspaceRightSidebarView.sessionID(of: environment.selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tree.treeHidden {
                // 树收起态：内容全宽（纯浏览态）。
                contentPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    contentPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    treePane
                        .frame(width: 150)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: environment.selection) { _ in reload() }
    }

    private func reload() {
        guard let sessionID else {
            tree.roots = []
            selectedPath = nil
            fileContent = nil
            return
        }
        tree.load(sessionID: sessionID)
        if let selectedPath {
            loadFile(selectedPath)
        }
    }

    // MARK: - 顶栏（根路径 + 复制路径 + 树收起钮）

    private var header: some View {
        HStack(spacing: 8) {
            Text("/var/wanwo/workspace")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                UIPasteboard.general.string = WanWoPaths.workspaceLinuxDir
                copiedToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copiedToast = false
                }
            } label: {
                Label(copiedToast ? "已复制" : "复制路径",
                      systemImage: copiedToast ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    tree.treeHidden.toggle()
                }
            } label: {
                Image(systemName: tree.treeHidden
                        ? "sidebar.leading" : "sidebar.squares.leading")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(tree.treeHidden ? "恢复文件树" : "收起文件树")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 文件树窄栏

    private var treePane: some View {
        VStack(spacing: 6) {
            filterField
            if let error = tree.loadError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleRows) { row in
                        treeRow(row)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.vertical, 6)
    }

    private var visibleRows: [FileTreeRow] {
        let needle = tree.filterText
        if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return WorkspaceFileTreeModel.flattenedVisible(tree.roots,
                                                           expanded: tree.expandedPaths)
        }
        let filtered = WorkspaceFileTreeModel.filterTree(tree.roots, query: needle)
        let forced = WorkspaceFileTreeModel.expandedAncestorPaths(tree.roots,
                                                                  query: needle)
            .union(tree.expandedPaths)
        return WorkspaceFileTreeModel.flattenedVisible(filtered, expanded: forced)
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("筛选文件…", text: $tree.filterText)
                .textFieldStyle(.plain)
                .font(.caption)
                .autocorrectionDisabled()
            if !tree.filterText.isEmpty {
                Button {
                    tree.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    private func treeRow(_ row: FileTreeRow) -> some View {
        let isSelected = row.node.id == selectedPath && !row.node.isDirectory
        return Button {
            if row.node.isDirectory {
                toggleExpand(row.node)
            } else {
                selectedPath = row.node.id
                loadFile(row.node.id)
            }
        } label: {
            HStack(spacing: 3) {
                if row.node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(tree.expandedPaths.contains(row.node.id) ? 90 : 0))
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 8, height: 8)
                    Image(systemName: "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(row.node.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 10)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleExpand(_ node: FileTreeNode) {
        if tree.expandedPaths.contains(node.id) {
            tree.expandedPaths.remove(node.id)
            return
        }
        tree.expandedPaths.insert(node.id)
        // 懒展开：子层为空时枚举宿主目录挂载（空目录即空子层，防重复枚举
        // 用「已挂载」标记——空 children 与未挂载区分：挂载过则幂等）。
        guard node.children.isEmpty,
              let sessionID,
              let hostRoot = WorkspaceFileTreeModel.hostRoot(for: sessionID) else { return }
        let hostDir = hostRoot.appendingPathComponent(node.id)
        let children = WorkspaceFileTreeModel.enumerate(hostDir: hostDir,
                                                        relativeBase: node.id)
        tree.attachChildren(relativePath: node.id, children: children)
    }

    // MARK: - 内容主区

    @ViewBuilder
    private var contentPane: some View {
        if let selectedPath {
            VStack(spacing: 0) {
                breadcrumb(path: selectedPath)
                Divider()
                fileBody
            }
        } else {
            // 空态（codex 词汇逐字）。
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("打开文件")
                    .font(.headline)
                Text("从工作区目录树中选择文件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func breadcrumb(path: String) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(parts.indices, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(parts[index])
                        .font(.caption)
                        .foregroundStyle(index == parts.count - 1
                                         ? Color.primary : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private var fileBody: some View {
        if let error = fileLoadError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if let content = fileContent {
            let isMarkdown = LightweightSyntaxHighlighter.isMarkdown(
                fileName: (selectedPath as NSString?)?.lastPathComponent ?? "")
            if isMarkdown && !showSource {
                renderedMarkdown(content)
            } else {
                sourceView(content)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// md 渲染视图 + 查看源代码切换。
    private func renderedMarkdown(_ content: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button {
                        showSource = true
                    } label: {
                        Text("查看源代码")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let attributed = try? AttributedString(
                    markdown: String(content.prefix(200_000)),
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    /// 源码视图（带行号；代码文件轻量语法高亮）。
    private func sourceView(_ content: String) -> some View {
        let fileName = selectedPath.map { ($0 as NSString).lastPathComponent } ?? ""
        let isMarkdownFile = LightweightSyntaxHighlighter.isMarkdown(fileName: fileName)
        let capped = String(content.prefix(1_000_000))
        let lines = capped.split(separator: "\n", omittingEmptySubsequences: false)
        let attributed = LightweightSyntaxHighlighter.highlight(code: capped,
                                                                fileName: fileName)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isMarkdownFile {
                    HStack {
                        Spacer()
                        Button {
                            showSource = false
                        } label: {
                            Text("查看预览")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                // 行号列 + 高亮正文双列（行数对齐以等宽字体 + 同行距保证）。
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                            Text("\(index + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 30, alignment: .trailing)
                        }
                    }
                    Text(attributed)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                if content.count > 1_000_000 {
                    Text("文件过大，仅显示前 1MB。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    private func loadFile(_ relativePath: String) {
        fileContent = nil
        fileLoadError = nil
        showSource = false
        guard let sessionID else {
            fileLoadError = "未打开会话"
            return
        }
        guard let hostRoot = WorkspaceFileTreeModel.hostRoot(for: sessionID) else {
            fileLoadError = "工作区目录不可用"
            return
        }
        // 防逃逸：相对路径不得含 ".."（词法校验——树行来源本身受控，双保险）。
        guard !relativePath.contains("..") else {
            fileLoadError = "路径不合法"
            return
        }
        let url = hostRoot.appendingPathComponent(relativePath)
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                fileLoadError = "无法以 UTF-8 解码（二进制文件不预览）"
                return
            }
            fileContent = text
        } catch {
            fileLoadError = "读取失败：\(error.localizedDescription)"
        }
    }
}
