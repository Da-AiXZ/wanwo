//
//  ContextInjection.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - F038 runtime-context 快照注入（dsh runtime-context：持久 user 消息基线 +
//      后续快照取代——cache-safe；M2 形态：会话首轮注入基线快照 user 消息）
//    - F039 AGENTS.md 基线 + 增量 reconcile（dsh agent-instructions：64KB 上限）
//    - F040 @file 注入（dsh injection：@path 语法照搬）
//  ERR-025① 时间戳移出快照（对照 dsh 源码为准）：
//    dsh 的 runtime-context 快照只由注册的动态上下文位组成（system-prompt 包
//    CONTEXT_ORDERS：sandbox-policy 110 / approval-policy 115）——**不含时间、
//    不含 AGENTS.md、不含工作区路径**。时间在 dsh 是独立的 opt-in 插件通道
//    packages/context/time-context（agent/pre-step 注入 "Time sampled while
//    preparing turn N, step M: …" 的独立 user 消息，带 refreshIntervalMs 节流），
//    与快照无关。M2 不移植 time-context 通道（列单报批），快照自此只含
//    稳定内容（workspace + AGENTS.md）——内容不变即不重注入，缓存前缀稳定。
//  ERR-025③ agent-instructions 基础文案逐字移植：
//    AGENTS.md 注入帧（<system-reminder> 开闭 + WORKSPACE_CONTEXT_INTRO +
//    "Instructions from:" 段式 + 截断预算标记）与增量 reconcile 文案
//    （Updated instructions / Instructions removed）取自
//    packages/context/agent-instructions/src/render.ts 逐字；
//    </system-reminder> 逃逸（escapeInstructionFrameBody）与 UTF-8 边界安全
//    截断（truncateUtf8）同款移植。M2 差异：dsh 的 AGENTS.md 走独立
//    agent-instructions 通道，WanWo M2 仍并入快照 user 消息（内容不变即不
//    重注入，缓存语义等价）；增量消息保留 <agents-md-update> 前缀（UI 投影
//    层 markerPrefixes 过滤依赖，事件词汇零新增）。
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

    /// M3 T2：approval-policy 动态上下文位供值缝（dsh CONTEXT_ORDERS
    /// approval-policy 115；PermissionCoordinator 装配）。快照通道注入：
    /// 完整当前值跟随、仅变化才重注入、缓存前缀不破（ERR-024 纪律：快照
    /// 不进 system）。nil = 位空缺（缺省不注入）。
    var approvalPolicyProvider: (@Sendable () -> String?)?

    // MARK: - agent-instructions 基础文案（dsh render.ts 逐字）

    /// dsh WORKSPACE_CONTEXT_INTRO（基线注入的引导句）。
    static let workspaceContextIntro = "The following workspace instructions may be relevant to your work. "
        + "Use them as guidance when applicable. More specific instructions take precedence over broader ones. "
        + "They do not override system, developer, or direct user instructions."

    private static let systemReminderOpen = "<system-reminder>"
    private static let systemReminderClose = "</system-reminder>"

    /// dsh escapeInstructionFrameBody：正文中的闭合标记逃逸，防注入帧提前闭合。
    static func escapeInstructionFrameBody(_ body: String) -> String {
        body.replacingOccurrences(of: systemReminderClose, with: "<\\/system-reminder>")
    }

    /// dsh buildInstructionText 的帧装配方言：<system-reminder> 开闭包裹，
    /// blocks 以空行连接（dsh body join("\n\n") + frame join("\n")）。
    private static func renderInstructionFrame(blocks: [String]) -> String {
        let body = blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return [systemReminderOpen, escapeInstructionFrameBody(body), systemReminderClose]
            .joined(separator: "\n")
    }

    /// dsh truncateUtf8：字节预算截断，切断点落在 UTF-8 连续字节上时回退到
    /// 前导字节（保证截断产物是合法 UTF-8 前缀）。
    static func truncateUtf8(_ data: Data, maxBytes: Int) -> (data: Data, originalBytes: Int) {
        let original = data.count
        guard original > maxBytes else { return (data, original) }
        var end = max(0, maxBytes)
        while end > 0, (data[data.startIndex + end] & 0xC0) == 0x80 {
            end -= 1
        }
        return (data.prefix(end), original)
    }

    // MARK: - AGENTS.md（F039）

    /// AGENTS.md 加载结果：截断后正文 + 原始字节数（预算标记需要）。
    struct AgentsMdLoad: Sendable {
        var content: String
        var originalBytes: Int
    }

    /// F039：读工作区 AGENTS.md（宿主直读；缺失/超限按 dsh truncateUtf8 截断）。
    /// - Returns: nil = 文件缺失/不可读/为空。
    func loadAgentsMd(workspace: WorkspaceFileAccess) -> AgentsMdLoad? {
        guard let url = workspace.resolve("AGENTS.md") else { return nil }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let clipped = Self.truncateUtf8(data, maxBytes: Self.agentsMdMaxBytes)
        return AgentsMdLoad(content: String(decoding: clipped.data, as: UTF8.self),
                            originalBytes: clipped.originalBytes)
    }

    /// F039 基线注入块（dsh renderWorkspaceContext 基线渲染 1:1）：
    /// [预算标记（仅截断时）] + [WORKSPACE_CONTEXT_INTRO] +
    /// ["Instructions from: AGENTS.md\n\n<content>"]，<system-reminder> 帧包裹。
    /// - Returns: nil = 无 AGENTS.md 内容（快照中省略该块）。
    static func agentsMdBaselineBlock(_ loaded: AgentsMdLoad?) -> String? {
        guard let loaded, !loaded.content.isEmpty else { return nil }
        let includedBytes = loaded.content.utf8.count
        var blocks: [String] = []
        if loaded.originalBytes > includedBytes {
            // dsh markerText 逐字（截断预算标记；dsh 置于 body 首位）。
            blocks.append("Workspace instruction budget \(Self.agentsMdMaxBytes) bytes: "
                + "truncated AGENTS.md from \(loaded.originalBytes) to \(includedBytes) bytes")
        }
        blocks.append(Self.workspaceContextIntro)
        blocks.append("Instructions from: AGENTS.md\n\n\(loaded.content)")
        return Self.renderInstructionFrame(blocks: blocks)
    }

    /// F038：首轮基线快照文本（workspace + sandbox:policy(110, P1-3) +
    /// approval-policy(115) + AGENTS.md；ERR-025① 无时间戳）。
    func baselineSnapshot(workspace: WorkspaceFileAccess, workspacePath: String) -> String {
        var parts: [String] = []
        parts.append("<runtime-context>")
        parts.append("workspace: \(workspacePath)")
        // P1-3：sandbox:policy 动态上下文位（CONTEXT_ORDERS 110——dsh
        // renderPolicyContext 逐字；挡位切换后本行变化 → 自动重注入）。
        if let provider = sandboxPolicyProvider, let line = provider(), !line.isEmpty {
            parts.append(line)
        }
        // T2：approval-policy 动态上下文位（CONTEXT_ORDERS 115）——策略切换后
        // 本行文本变化 → 快照整体变化 → 自动重注入（RuntimeContextProjection）。
        if let provider = approvalPolicyProvider, let line = provider(), !line.isEmpty {
            parts.append(line)
        }
        if let agentsMd = loadAgentsMd(workspace: workspace),
           let block = Self.agentsMdBaselineBlock(agentsMd) {
            parts.append(block)
        }
        parts.append("</runtime-context>")
        return parts.joined(separator: "\n")
    }

    /// F039 增量 reconcile：AGENTS.md 相对基线变化时返回增量更新消息，否则 nil。
    /// 文案逐字取 dsh render.ts changedSectionText / remove 分支
    /// （"Updated instructions from:" / "Instructions removed:"，
    /// <system-reminder> 帧、空 intro）；外层保留 <agents-md-update> 前缀
    /// （UI 投影层过滤标记，WanWo M2 词汇）。API 保留：AgentLoop 经快照通道
    /// 重注入，本方法暂不被 loop 调用（M3 精细 reconcile 备用）。
    func reconcileAgentsMd(workspace: WorkspaceFileAccess,
                           baselineDigest: String) -> (message: String, digest: String)? {
        guard let loaded = loadAgentsMd(workspace: workspace) else {
            // 基线存在而文件被删 → 注入删除通告（dsh remove 分支逐字）。
            if !baselineDigest.isEmpty {
                let body = "Instructions removed: AGENTS.md\n\n"
                    + "The previously loaded instructions from this file no longer apply."
                let removedFrame = Self.renderInstructionFrame(blocks: [body])
                return ("<agents-md-update>\n\(removedFrame)", "")
            }
            return nil
        }
        let digest = Self.digest(of: loaded.content)
        if digest == baselineDigest { return nil }
        // dsh changedSectionText update 分支逐字。
        let body = [
            "Updated instructions from: AGENTS.md",
            "",
            "This file changed after it was loaded. Use the following content instead "
                + "of the previously loaded instructions from this file.",
            "",
            loaded.content,
        ].joined(separator: "\n")
        let frame = Self.renderInstructionFrame(blocks: [body])
        let message = "<agents-md-update>\n\(frame)"
        return (message, digest)
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
