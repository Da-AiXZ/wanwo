//
//  ReviewTabModel.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.5（骨架级范围——§6.6a⑴）】
//  审查页签骨架级：git 仓库项目（工作区宿主根存在 .git）显示入口；diff 经
//  shell 工具通道取（IshExecutorBridge 只读命令，当前会话 fs_context 路由）。
//  分支下拉 / 提交或推送 / 创建 PR = M9.6 既定范围——本批仅占位按钮（禁用态）。
//  GitDiffParser = 纯函数（单测面：+/− 计数、hunk 结构、折叠块）。
//  降级路径（派单允许）：git 二进制不可用 → 入口保留 + 空态解释 + 标注 M9.6。
//

import Foundation

// MARK: - diff 解析（纯函数）

/// 一条 diff 行。
struct DiffLine: Equatable {
    enum Kind: Equatable { case added, removed, context }

    let kind: Kind
    let text: String
}

/// 一个 hunk（@@ -a,b +c,d @@ 之间）。
struct DiffHunk: Equatable {
    /// @@ 头原文（呈现 hunk 定位）。
    let header: String
    let lines: [DiffLine]
}

/// 一个文件的 diff。
struct DiffFile: Equatable, Identifiable {
    /// git 报告路径（a/ b/ 前缀已剥）。
    let path: String
    let addedCount: Int
    let removedCount: Int
    let hunks: [DiffHunk]

    var id: String { path }
}

enum GitDiffParser {

    /// 解析 `git diff` 原文（unified diff；纯函数）。
    nonisolated static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var currentPath: String?
        var currentAdded = 0
        var currentRemoved = 0
        var currentHunks: [DiffHunk] = []
        var hunkHeader = ""
        var hunkLines: [DiffLine] = []

        func flushFile() {
            flushHunk()
            if let path = currentPath {
                files.append(DiffFile(path: path, addedCount: currentAdded,
                                      removedCount: currentRemoved,
                                      hunks: currentHunks))
            }
            currentPath = nil
            currentAdded = 0
            currentRemoved = 0
            currentHunks = []
        }

        func flushHunk() {
            if !hunkLines.isEmpty || !hunkHeader.isEmpty {
                currentHunks.append(DiffHunk(header: hunkHeader, lines: hunkLines))
                hunkHeader = ""
                hunkLines = []
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") {
                flushFile()
                // "diff --git a/x b/x" → x（优先 b/ 段——重命名呈现新名）。
                let parts = line.split(separator: " ")
                if let bPart = parts.last.map(String.init),
                   bPart.hasPrefix("b/") {
                    currentPath = String(bPart.dropFirst(2))
                } else if let aPart = parts.last.map(String.init),
                          aPart.hasPrefix("a/") {
                    currentPath = String(aPart.dropFirst(2))
                } else {
                    currentPath = parts.last.map(String.init)
                }
                continue
            }
            guard currentPath != nil else { continue }
            if line.hasPrefix("@@") {
                flushHunk()
                hunkHeader = line
                continue
            }
            if line.hasPrefix("+++") || line.hasPrefix("---")
                || line.hasPrefix("index ") || line.hasPrefix("new file")
                || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
                || line.hasPrefix("rename ") || line.hasPrefix("old mode")
                || line.hasPrefix("new mode") {
                continue
            }
            if line.hasPrefix("+") {
                currentAdded += 1
                hunkLines.append(DiffLine(kind: .added,
                                          text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                currentRemoved += 1
                hunkLines.append(DiffLine(kind: .removed,
                                          text: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                hunkLines.append(DiffLine(kind: .context,
                                          text: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — 呈现面跳过。
                continue
            }
            // 其余（空行等）忽略。
        }
        flushFile()
        return files
    }

    /// 连续 context 折叠块（§6.5：未修改行折叠——≥ foldThreshold 连成
    /// "N unmodified lines" 点击展开）。返回折叠后的呈现行序列。
    nonisolated static func foldedLines(_ lines: [DiffLine],
                                        foldThreshold: Int = 4)
        -> [DiffPresentationLine] {
        var result: [DiffPresentationLine] = []
        var contextRun: [DiffLine] = []
        func flushRun() {
            guard !contextRun.isEmpty else { return }
            if contextRun.count >= foldThreshold {
                result.append(DiffPresentationLine(kind: .fold(count: contextRun.count),
                                                   line: nil))
            } else {
                for item in contextRun {
                    result.append(DiffPresentationLine(kind: .visible, line: item))
                }
            }
            contextRun.removeAll()
        }
        for line in lines {
            if line.kind == .context {
                contextRun.append(line)
            } else {
                flushRun()
                result.append(DiffPresentationLine(kind: .visible, line: line))
            }
        }
        flushRun()
        return result
    }
}

/// 折叠呈现行（可见行 / 折叠块）。
struct DiffPresentationLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case visible
        case fold(count: Int)
    }

    let kind: Kind
    let line: DiffLine?
    var id: String {
        switch kind {
        case .visible:
            return (line?.kind == .added ? "+" : line?.kind == .removed ? "-" : " ")
                + (line?.text ?? "")
        case .fold(let count):
            return "fold-\(count)"
        }
    }
}

// MARK: - 页签模型

@MainActor
final class ReviewTabModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case probing
        /// git 不可用/非仓库/无 diff 通道——带用户可解解释。
        case unavailable(String)
        case ready
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var files: [DiffFile] = []
    @Published var busy = false

    /// 入口可见性的静态判据（宿主根存在 .git 目录——model 层复查用；
    /// 入口首道判定在 WorkspaceRightSidebarModel.updateReviewAvailability）。
    nonisolated static func hasGitDirectory(hostRoot: URL) -> Bool {
        var isDir: ObjCBool = false
        let gitDir = hostRoot.appendingPathComponent(".git", isDirectory: true)
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    private let sessionID: String

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// 探测 + 取 diff（只读命令经 shell 通道；fs_context = 当前会话工作区桶）。
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        phase = .probing
        do {
            // ① git 二进制 + 仓库判定。
            let probe = try await IshExecutorBridge.shared.execute(
                sessionId: sessionID,
                command: "git -C /var/wanwo/workspace rev-parse --is-inside-work-tree 2>&1",
                timeout: 15,
                lineCallback: { _ in },
                pidCallback: { _ in })
            guard probe.exitCode == 0,
                  probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
                      .contains("true") else {
                phase = .unavailable(
                    "这不是一个 git 仓库工作区（或 git 不可用）。"
                    + "把含 .git 的目录挂载为工作区后可在此审查变更。")
                return
            }
            // ② 已跟踪变更 diff（骨架级：未提交 diff 一档；暂存/分支档 = M9.6）。
            let diff = try await IshExecutorBridge.shared.execute(
                sessionId: sessionID,
                command: "git -C /var/wanwo/workspace diff",
                timeout: 30,
                lineCallback: { _ in },
                pidCallback: { _ in })
            files = GitDiffParser.parse(diff.output)
            phase = .ready
        } catch {
            phase = .unavailable("无法执行 git（内核未就绪或命令失败）："
                                 + "\(error.localizedDescription)")
        }
    }
}
