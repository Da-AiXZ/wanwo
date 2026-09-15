//
//  WorkspaceFileTreeModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.1（codex 截图「文件」讲解版）】
//  工作区文件树：目录折叠 + 文件行 + 筛选框 + 懒展开。
//  树构建 / 筛选 / 可见行展开三段为纯函数（单测直呼——本批验收面：文件树过滤）；
//  宿主枚举经 FsContextRouter（会话工作区桶直读，§7.5 数据源纪律）。
//

import Foundation

/// 文件树节点（相对工作区根的路径为身份）。
struct FileTreeNode: Identifiable, Equatable {
    /// 相对路径（"docs/readme.md"；根目录子项直接为首段）。
    let id: String
    let name: String
    let isDirectory: Bool
    var children: [FileTreeNode]
}

/// 展平后的可见行（List 渲染形态；depth 控制缩进）。
struct FileTreeRow: Identifiable, Equatable {
    let node: FileTreeNode
    let depth: Int
    var id: String { node.id }
}

/// 文件树模型（枚举走宿主 FS；树逻辑纯函数收口）。
@MainActor
final class WorkspaceFileTreeModel: ObservableObject {

    @Published private(set) var roots: [FileTreeNode] = []
    @Published var filterText = ""
    @Published var expandedPaths: Set<String> = []
    /// 树收起钮（§6.1：文件树整栏收起、内容全宽，再点恢复）。
    @Published var treeHidden = false
    /// 加载失败解释（宿主目录不可达等）。
    @Published var loadError: String?

    /// 会话工作区桶的宿主根（FsContextRouter 既有面；§7.5 直读纪律）。
    static func hostRoot(for sessionID: String) -> URL? {
        FsContextRouter.shared.hostURL(forGuest: WanWoPaths.workspaceLinuxDir,
                                       sid: sessionID)
    }

    /// 加载工作区根一层（目录懒展开——大目录不全量递归）。
    func load(sessionID: String) {
        guard let hostRoot = Self.hostRoot(for: sessionID) else {
            loadError = "工作区目录不可用"
            roots = []
            return
        }
        let loaded = Self.enumerate(hostDir: hostRoot, relativeBase: "")
        roots = loaded
        loadError = nil
    }

    /// 清空树（无会话时复位；roots 为 private(set)，视图层经此方法置空）。
    func clear() {
        roots = []
        loadError = nil
    }

    /// 宿主目录一层枚举（目录前、名称序——树形惯例）。
    static func enumerate(hostDir: URL, relativeBase: String) -> [FileTreeNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: hostDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: []) else { return [] }
        var dirs: [FileTreeNode] = []
        var files: [FileTreeNode] = []
        for item in items {
            let name = item.lastPathComponent
            // 与 WorkspaceFileAccess.filesUnder 同纪律：VCS 元数据排除。
            if name == ".git" || name == ".svn" || name == ".hg"
                || name == ".jj" || name == ".sl" || name == "node_modules" {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            let relPath = relativeBase.isEmpty ? name : relativeBase + "/" + name
            let node = FileTreeNode(id: relPath, name: name,
                                    isDirectory: isDir.boolValue, children: [])
            if isDir.boolValue { dirs.append(node) } else { files.append(node) }
        }
        return dirs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 懒展开：给相对路径目录挂上子层（根外路径递归更新）。
    func attachChildren(relativePath: String, children: [FileTreeNode]) {
        roots = Self.updating(children: children, for: relativePath, in: roots)
    }

    /// 深度更新（按相对路径定位；纯函数形态便于复核）。
    nonisolated static func updating(children: [FileTreeNode],
                                     for path: String,
                                     in nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes.map { node in
            if node.id == path {
                return FileTreeNode(id: node.id, name: node.name,
                                    isDirectory: node.isDirectory, children: children)
            }
            guard node.isDirectory, path.hasPrefix(node.id + "/") else { return node }
            return FileTreeNode(id: node.id, name: node.name,
                                isDirectory: true,
                                children: updating(children: children,
                                                   for: path, in: node.children))
        }
    }

    // MARK: - 纯函数（单测面）

    /// 由相对路径清单构树（单测构造形态；运行时走懒枚举不整树构建）。
    /// 实现：先收集目录/文件路径集合，再按前缀逐层重组（值语义下免嵌套
    /// inout 的稳妥构型）。
    nonisolated static func buildTree(relativePaths: [String]) -> [FileTreeNode] {
        var files = Set<String>()
        var directories = Set<String>()
        for raw in relativePaths {
            let parts = raw.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var accumulated = ""
            for (index, part) in parts.enumerated() {
                accumulated = accumulated.isEmpty ? part : accumulated + "/" + part
                if index < parts.count - 1 {
                    directories.insert(accumulated)
                } else {
                    files.insert(accumulated)
                }
            }
        }
        func build(dirPath: String) -> [FileTreeNode] {
            let prefix = dirPath.isEmpty ? "" : dirPath + "/"
            func directChildren(of set: Set<String>) -> [String] {
                set.filter { path in
                    path.hasPrefix(prefix)
                        && !path.dropFirst(prefix.count).contains("/")
                }
                .map { String($0.dropFirst(prefix.count)) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            var nodes: [FileTreeNode] = directChildren(of: directories).map { name in
                let childPath = prefix + name
                return FileTreeNode(id: childPath, name: name, isDirectory: true,
                                    children: build(dirPath: childPath))
            }
            nodes += directChildren(of: files).map { name in
                FileTreeNode(id: prefix + name, name: name,
                             isDirectory: false, children: [])
            }
            return nodes
        }
        return build(dirPath: "")
    }

    /// 树排序：目录前、名称序（递归）。
    nonisolated static func sortTree(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
        nodes
            .map { node in
                node.isDirectory
                    ? FileTreeNode(id: node.id, name: node.name, isDirectory: true,
                                   children: sortTree(node.children))
                    : node
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// 筛选：保留名字命中的文件及其祖先链（目录自身命中也保留整枝）。
    /// 命中节点在结果树中视为"可见"（配合 flattenedVisible 自动展开语义：
    /// 筛选态下 expandedPaths 缺省命中链全部展开）。
    nonisolated static func filterTree(_ nodes: [FileTreeNode],
                                       query: String) -> [FileTreeNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { node in
            let selfMatch = node.name.localizedCaseInsensitiveContains(needle)
            if node.isDirectory {
                let filteredChildren = filterTree(node.children, query: needle)
                if selfMatch { return node }
                if filteredChildren.isEmpty { return nil }
                return FileTreeNode(id: node.id, name: node.name, isDirectory: true,
                                    children: filteredChildren)
            }
            return selfMatch ? node : nil
        }
    }

    /// 筛选态命中的目录链（供视图把祖先全部标为展开）。
    nonisolated static func expandedAncestorPaths(in nodes: [FileTreeNode],
                                                  query: String) -> Set<String> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var result: Set<String> = []
        func walk(_ list: [FileTreeNode]) {
            for node in list where node.isDirectory {
                let subtreeHit = subtreeContainsMatch(node, query: needle)
                if subtreeHit {
                    result.insert(node.id)
                    walk(node.children)
                }
            }
        }
        walk(nodes)
        return result
    }

    private nonisolated static func subtreeContainsMatch(_ node: FileTreeNode,
                                                         query: String) -> Bool {
        if node.name.localizedCaseInsensitiveContains(query) { return true }
        return node.children.contains { subtreeContainsMatch($0, query: query) }
    }

    /// 展平可见行：目录折叠 + 懒展开语义——目录仅在 expandedPaths 命中（或
    /// forceExpand）时渲染子层。纯函数（页签视图与单测共用）。
    nonisolated static func flattenedVisible(_ nodes: [FileTreeNode],
                                             expanded: Set<String>,
                                             depth: Int = 0) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        for node in nodes {
            rows.append(FileTreeRow(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.id) {
                rows.append(contentsOf: flattenedVisible(node.children,
                                                         expanded: expanded,
                                                         depth: depth + 1))
            }
        }
        return rows
    }
}
