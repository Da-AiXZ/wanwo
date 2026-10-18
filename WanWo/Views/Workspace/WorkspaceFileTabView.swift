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
    /// 【P2-2】图片形态内容（loadFile 按扩展名分流；非空=图片预览态）。
    @State private var fileImageData: UIImage?
    /// 【P2-1c】当前选中文件的宿主绝对路径（图片态点击预览直接用）。
    @State private var selectedHostPath: String?
    @State private var fileLoadError: String?
    /// md 渲染/源码切换（默认渲染视图）。
    @State private var showSource = false
    @State private var copiedToast = false
    /// 【批2 高亮】本回合变更文件集（store.turn 变更卡同源；树行渲染 tint，
    /// 下次刷新/会话切换覆盖或清除）。
    @State private var highlightedPaths: Set<String> = []
    /// 【批2 自动刷新】右栏真值源订阅——fileChangeEpoch 变化驱动本视图
    /// 重渲染，onChange 才能求值触发 reload（未订阅则信号永不到达）。
    @ObservedObject private var workspaceStore = WOWorkspaceStore.shared

    private var sessionID: String? {
        WorkspaceRightSidebarView.sessionID(of: environment.selection)
    }

    /// 会话 guest 工作区前缀（header cwd 单一真值源；批12+工作区贯穿）。
    private var workspacePath: String {
        environment.guestWorkspacePath(for: sessionID ?? "")
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
        .onAppear {
            reload()
            highlightedPaths = WOWorkspaceStore.shared.changeHighlight[sessionID ?? ""] ?? []
            // 【P2-2 修1】初装即消费外源打开请求——新建页签场景 pendingFileOpen
            // 已在页签创建前置位，onChange 注册晚于置位会永久错过（真机实证
            // "第一次点不打开、第二次才开"）；onAppear 主动消费一次补齐。
            consumePendingFileOpen()
        }
        .onChange(of: environment.selection) { _ in
            reload()
            highlightedPaths = []
        }
        // 【批2 文件页签自动刷新 2026-09-27】文件活动纪元（AI 工具结果/回合
        // 边界驱动；cc-haha useWorkspaceFileWatch 语义的万我动作驱动等价）→
        // 重载根层 + 同步高亮集（turn 变更文件；下次刷新覆盖）。
        .onChange(of: workspaceStore.fileChangeEpoch[sessionID ?? ""]) { _ in
            reload()
            highlightedPaths = workspaceStore.changeHighlight[sessionID ?? ""] ?? []
        }
        // 【P2-2 方案甲 2026-09-28】外源打开请求（深链分流/统一打开入口）→
        // 选中 + 加载该文件（树行点击之外的第二入口；cc-haha openTarget 落点）。
        .onChange(of: workspaceStore.pendingFileOpen) { _ in
            consumePendingFileOpen()
        }
    }

    /// 消费外源打开请求（onAppear 初装 + onChange 变化两路共用）。
    private func consumePendingFileOpen() {
        guard let request = workspaceStore.pendingFileOpen,
              request.sessionID == sessionID,
              !request.path.isEmpty, !request.path.contains("..") else { return }
        expandAncestors(to: request.path)
        selectedPath = request.path
        loadFile(request.path)
        workspaceStore.pendingFileOpen = nil
    }

    /// 外源打开时展开祖先目录链（懒展开树——逐级枚举宿主目录挂载子层 +
    /// 插入展开集；attachChildren 幂等，已挂载目录重复枚举无害）。
    private func expandAncestors(to path: String) {
        guard let sessionID,
              let hostRoot = WorkspaceFileTreeModel.hostRoot(for: sessionID,
                                                             workspacePath: workspacePath) else { return }
        let parts = path.split(separator: "/").map(String.init)
        var cumulative = ""
        for part in parts.dropLast() {
            cumulative = cumulative.isEmpty ? part : cumulative + "/" + part
            let children = WorkspaceFileTreeModel.enumerate(
                hostDir: hostRoot.appendingPathComponent(cumulative),
                relativeBase: cumulative)
            tree.attachChildren(relativePath: cumulative, children: children)
            tree.expandedPaths.insert(cumulative)
        }
    }

    private func reload() {
        guard let sessionID else {
            tree.clear()
            selectedPath = nil
            fileContent = nil
            return
        }
        tree.load(sessionID: sessionID, workspacePath: workspacePath)
        if let selectedPath {
            loadFile(selectedPath)
        }
    }

    // MARK: - 顶栏（根路径 + 复制路径 + 树收起钮）

    private var header: some View {
        HStack(spacing: 8) {
            Text(workspacePath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                UIPasteboard.general.string = workspacePath
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
            // 【批3 引用挂载】引用当前选中文件到对话（cc-haha FileTab 引用
            // 入口；无选中文件时禁用）。
            Button {
                guard let sessionID, let selectedPath else { return }
                WOWorkspaceStore.shared.requestComposerInsert(
                    sessionID: sessionID, token: "@\(selectedPath)")
            } label: {
                Label("引用到对话", systemImage: "at")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(selectedPath == nil)
            .accessibilityLabel("引用当前文件到对话")
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
        let forced = WorkspaceFileTreeModel.expandedAncestorPaths(in: tree.roots,
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
                // 【批2 高亮】本回合变更文件标记（accent 圆点；非文件/已选中
                // 不叠——选中态已有 accent 前景色）。
                if highlightedPaths.contains(row.node.id), !isSelected {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 10)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 【批3 引用挂载】树行长按菜单：引用该路径到对话（cc-haha TreePane
        // 引用入口语义；file 级=批3 拍板范围，选区/行评论=M9.7）。
        .contextMenu {
            Button {
                guard let sessionID else { return }
                let token = row.node.isDirectory ? "@\(row.node.id)/" : "@\(row.node.id)"
                WOWorkspaceStore.shared.requestComposerInsert(
                    sessionID: sessionID, token: token)
            } label: {
                Label("引用到对话", systemImage: "at")
            }
        }
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
              let hostRoot = WorkspaceFileTreeModel.hostRoot(for: sessionID,
                                                             workspacePath: workspacePath) else { return }
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
        } else if let image = fileImageData {
            // 【P2-2】图片预览态（cc-haha previewType=image 同语义）。
            // 【P2-1c 修4】去 ScrollView 直铺容器（ScrollView 内 scaledToFit
            // 拿无限约束=原始尺寸渲染，真机实证"完全没适配大小"）；点击 →
            // 集中预览通道全屏。
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let sessionID, let selectedHostPath {
                        WOWorkspaceStore.shared.requestImagePreview(
                            sessionID: sessionID, hostPath: selectedHostPath)
                    }
                }
                .background(Color.black.opacity(0.85))
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
        fileImageData = nil
        selectedHostPath = nil
        fileLoadError = nil
        showSource = false
        guard let sessionID else {
            fileLoadError = "未打开会话"
            return
        }
        guard let hostRoot = WorkspaceFileTreeModel.hostRoot(for: sessionID,
                                                             workspacePath: workspacePath) else {
            fileLoadError = "工作区目录不可用"
            return
        }
        // 防逃逸：相对路径不得含 ".."（词法校验——树行来源本身受控，双保险）。
        guard !relativePath.contains("..") else {
            fileLoadError = "路径不合法"
            return
        }
        let url = hostRoot.appendingPathComponent(relativePath)
        selectedHostPath = url.standardizedFileURL.path
        // 【P2-2】大小帽（cc-haha too_large 态语义）——超大文件直读卡 UI。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > Self.maxPreviewBytes {
            fileLoadError = String(format: "文件过大（%.1f MB），不预览", Double(size) / 1_048_576)
            return
        }
        // 【P2-2】图片形态先试（cc-haha previewType=image——png/jpg 等由
        // 系统解码渲染，不走 UTF-8 文本路径）。
        if Self.isImageExtension(url.pathExtension), let image = UIImage(contentsOfFile: url.path) {
            fileImageData = image
            return
        }
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

    /// 预览大小帽（10MB——超过即提示不读入内存）。
    private static let maxPreviewBytes = 10 * 1_048_576

    /// 图片扩展名（UIImage 可解码族 + svg；svg 解码失败自然落二进制提示）。
    nonisolated static func isImageExtension(_ ext: String) -> Bool {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "svg":
            return true
        default:
            return false
        }
    }
}
