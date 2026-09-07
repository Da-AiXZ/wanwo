//
//  SpillStore.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh compaction spill 语义（>50KB 大结果落盘 +
//  locator 按引用取回）+ 10-design §5.7（SpillStore F037）/ 附录 B #22。
//  M2 形态：宿主容器落盘（App 沙盒），locator = 宿主文件路径文本；
//  spill 文件同时登记进会话工作区桶旁路目录（UI/用户可经 Files 取回）。
//

import Foundation

/// 大结果落盘（F037）。
final class SpillStore: @unchecked Sendable {
    /// spill 根（App 沙盒；按会话分桶）。
    private let root: URL
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 落盘一份大结果文本，返回 locator 文本（文件路径）。
    func spill(_ text: String, sessionId: String, callId: String) async -> String {
        let safeSession = sessionId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_",
                                                         options: .regularExpression)
        let safeCall = callId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_",
                                                   options: .regularExpression)
        let dir = root.appendingPathComponent(safeSession, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(safeCall).txt")
        do {
            try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        } catch {
            return "(spill failed: \(error.localizedDescription))"
        }
        return fileURL.path
    }

    /// 按 locator 取回（F037 按引用取回；失败返回 nil）。
    func retrieve(_ locator: String) -> String? {
        guard FileManager.default.fileExists(atPath: locator) else { return nil }
        return try? String(contentsOfFile: locator, encoding: .utf8)
    }
}
