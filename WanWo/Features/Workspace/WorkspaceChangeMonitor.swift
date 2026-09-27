//
//  WorkspaceChangeMonitor.swift
//  WanWo
//
//  【批2 变更卡+页签自动刷新基建（2026-09-27 用户拍板）】
//  语义源 = cc-haha turn checkpoint（fileHistoryTrackEdit → 每 turn filesChanged
//  → CurrentTurnChangeCard）+ useWorkspaceFileWatch 的「AI 动作驱动刷新」。
//
//  【平台适配（呈报已批）】cc-haha 备份发生在宿主文件工具层（Edit/Write 执行
//  前备份）；万我 AI 写文件走 iSH 引擎（bash 任意写法），宿主无法逐次挂钩 →
//  触发源等价替换为「回合边界快照对比」：用户消息落盘拍快照（回合开始），
//  turn/end 再扫对比 → 变更清单。iOS fakefs 无 inotify（08 §一.五③），扫描
//  在宿主项目真目录（projectsHostRoot=fakefs 持久层）原生 FileManager 枚举。
//
//  扫描纪律与 WorkspaceFileTreeModel.enumerate 同源：VCS 元数据/node_modules
//  排除；文件数上限防失控（超出 → truncated，diff 返回 nil 由调用方兜底文案）。
//

import Foundation

@MainActor
final class WorkspaceChangeMonitor {

    static let shared = WorkspaceChangeMonitor()

    struct Entry: Equatable {
        var modifiedAt: Date
        var size: Int
    }

    struct Manifest: Equatable {
        var entries: [String: Entry] = [:]
        var truncated = false
    }

    struct ChangeSet: Equatable {
        var added: [String] = []
        var modified: [String] = []
        var removed: [String] = []
        var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }
    }

    /// 扫描文件数护栏（超出即放弃本回合 diff——变更大到清单无阅读价值，
    /// cc-haha 无此面因其为工具级记录；万我全树快照必须有界）。
    static let maxTrackedFiles = 5_000

    private var snapshots: [String: Manifest] = [:]

    private init() {}

    // MARK: - 快照

    /// 拍摄（或更新）会话工作区快照。workspacePath 为空/非项目路径（guest
    /// 桶根等遗留形态）→ 清掉旧快照（无项目目录不监测，返回 nil 变更）。
    func takeSnapshot(sessionID: String, workspacePath: String?) {
        guard let manifest = Self.scanManifest(workspacePath: workspacePath) else {
            snapshots.removeValue(forKey: sessionID)
            return
        }
        snapshots[sessionID] = manifest
    }

    /// 与最近快照对比并消费（对比后清快照——下一回合由新的用户消息重拍）。
    /// 无快照（首批/重装）→ 只拍新照返回 nil（首回合无基线，不误报全量新增）。
    func consumeChanges(sessionID: String, workspacePath: String?) -> ChangeSet? {
        guard let old = snapshots.removeValue(forKey: sessionID) else {
            takeSnapshot(sessionID: sessionID, workspacePath: workspacePath)
            return nil
        }
        guard let new = Self.scanManifest(workspacePath: workspacePath) else {
            snapshots.removeValue(forKey: sessionID)
            return nil
        }
        var changes = ChangeSet()
        for (path, entry) in new.entries {
            if let prev = old.entries[path] {
                if prev != entry { changes.modified.append(path) }
            } else {
                changes.added.append(path)
            }
        }
        for path in old.entries.keys where new.entries[path] == nil {
            changes.removed.append(path)
        }
        return changes.isEmpty ? nil : changes
    }

    /// 测试缝：注入快照（无需真实目录）。
    func injectSnapshot(sessionID: String, manifest: Manifest) {
        snapshots[sessionID] = manifest
    }

    /// 会话关闭/删除清理。
    func discardSession(_ sessionID: String) {
        snapshots.removeValue(forKey: sessionID)
    }

    // MARK: - 扫描

    /// 项目宿主目录全树清单（相对路径键控）。非项目工作区（guest 桶根/
    /// legacy 路径）→ nil（fail closed：不监测不误报）。
    static func scanManifest(workspacePath: String?) -> Manifest? {
        guard let workspacePath, !workspacePath.isEmpty,
              let hostRoot = WanWoPaths.projectsHostRoot(forGuestPath: workspacePath) else {
            return nil
        }
        var manifest = Manifest()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: hostRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsPackageDescendants]) else { return nil }

        func isExcluded(_ name: String) -> Bool {
            // 与 WorkspaceFileTreeModel.enumerate 同纪律（树渲染排除集）。
            name == ".git" || name == ".svn" || name == ".hg"
                || name == ".jj" || name == ".sl" || name == "node_modules"
        }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if isExcluded(name) {
                enumerator.skipDescendants()
                continue
            }
            if manifest.entries.count > Self.maxTrackedFiles {
                manifest.truncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            guard let isDir = values?.isDirectory else { continue }
            guard !isDir else { continue }
            let rel = url.path.hasPrefix(hostRoot.path + "/")
                ? String(url.path.dropFirst(hostRoot.path.count + 1))
                : url.lastPathComponent
            manifest.entries[rel] = Entry(
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                size: values?.fileSize ?? 0)
        }
        return manifest
    }
}
