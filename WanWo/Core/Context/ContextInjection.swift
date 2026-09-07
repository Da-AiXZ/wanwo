//
//  ContextInjection.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - F038 runtime-context 快照注入（dsh runtime-context：持久 user 消息基线 +
//      后续快照取代——cache-safe；M2 形态：会话首轮注入基线快照 user 消息）
//    - F039 AGENTS.md 基线 + 增量 reconcile（dsh agent-instructions：64KB 上限）
//    - F040 time / @file 注入（dsh injection：@path 语法照搬）
//  快照/增量以 `<runtime-context>` / `<agents-md-update>` / `<file>` 标记的
//  user 消息注入（model-visible=logged；UI 投影层过滤标记消息不渲染气泡）。
//

import Foundation

/// 上下文注入器（F038/F039/F040）。
struct ContextInjector: Sendable {
    /// AGENTS.md 注入上限（F039：64KB）。
    static let agentsMdMaxBytes = 64_000
    /// @file 单文件注入上限（防单条消息爆上下文）。
    static let fileRefMaxBytes = 16_000
    /// 每回合 @file 引用上限。
    static let maxFileRefs = 4

    /// F039：读工作区 AGENTS.md（宿主直读；缺失/超限截断安全处理）。
    func loadAgentsMd(workspace: WorkspaceFileAccess) -> String? {
        guard let url = workspace.resolve("AGENTS.md") else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var text = String(decoding: data.prefix(Self.agentsMdMaxBytes), as: UTF8.self)
        if data.count > Self.agentsMdMaxBytes {
            text += "\n[AGENTS.md truncated at \(Self.agentsMdMaxBytes) bytes]"
        }
        return text
    }

    /// F038：首轮基线快照文本（时间 + 工作区 + AGENTS.md 摘要头）。
    func baselineSnapshot(workspace: WorkspaceFileAccess, workspacePath: String) -> String {
        var parts: [String] = []
        parts.append("<runtime-context>")
        parts.append(timeSection())
        parts.append("workspace: \(workspacePath)")
        if let agentsMd = loadAgentsMd(workspace: workspace), !agentsMd.isEmpty {
            parts.append("<agents-md>\n\(agentsMd)\n</agents-md>")
        }
        parts.append("</runtime-context>")
        return parts.joined(separator: "\n")
    }

    /// F039 增量 reconcile：AGENTS.md 相对基线变化时返回增量更新消息，否则 nil。
    func reconcileAgentsMd(workspace: WorkspaceFileAccess,
                           baselineDigest: String) -> (message: String, digest: String)? {
        guard let agentsMd = loadAgentsMd(workspace: workspace) else {
            // 基线存在而文件被删 → 注入删除通告。
            if !baselineDigest.isEmpty {
                return ("<agents-md-update>AGENTS.md was removed from the workspace.</agents-md-update>", "")
            }
            return nil
        }
        let digest = Self.digest(of: agentsMd)
        if digest == baselineDigest { return nil }
        let preview = agentsMd.count > 4_000 ? String(agentsMd.prefix(4_000)) + "\n[...]" : agentsMd
        let message = "<agents-md-update>\nAGENTS.md changed since it was last injected. "
            + "Updated content:\n\(preview)\n</agents-md-update>"
        return (message, digest)
    }

    /// F040：时间段。
    func timeSection() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm (zzz)"
        return "current time: \(formatter.string(from: Date()))"
    }

    /// F040：@file 展开。扫描用户文本中的 `@path` 令牌，工作区内命中的文件内容
    /// 以 `<file>` 块注入；返回 (注入消息, 处理后的提示)。
    func expandFileReferences(in text: String,
                              workspace: WorkspaceFileAccess) -> (injected: String?, cleaned: String) {
        guard text.contains("@") else { return (nil, text) }
        var refs: [String] = []
        var blocks: [String] = []
        // 令牌：@ 后的非空白串（@file 语法照 dsh；不处理转义）。
        let tokens = text.split { $0.isWhitespace || $0.isNewline }
        for token in tokens {
            let word = String(token)
            guard word.hasPrefix("@"), word.count > 1 else { continue }
            let path = String(word.dropFirst())
            guard refs.count < Self.maxFileRefs else { break }
            guard let url = workspace.resolve(path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty else { continue }
            // 二进制安全：非 UTF8 文本跳过。
            guard let content = String(data: data.prefix(Self.fileRefMaxBytes), encoding: .utf8) else {
                continue
            }
            refs.append(path)
            let truncated = data.count > Self.fileRefMaxBytes
                ? "\n[file truncated at \(Self.fileRefMaxBytes) bytes]"
                : ""
            blocks.append("<file path=\"\(path)\">\n\(content)\(truncated)\n</file>")
        }
        if blocks.isEmpty { return (nil, text) }
        return (blocks.joined(separator: "\n"), text)
    }

    /// 稳定摘要（增量比较用；M2 用计数+长度+哈希前缀，无需密码学强度）。
    static func digest(of text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_6037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "v1:\(text.utf8.count):\(hash)"
    }
}
