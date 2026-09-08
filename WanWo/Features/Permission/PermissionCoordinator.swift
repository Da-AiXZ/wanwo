//
//  PermissionCoordinator.swift
//  WanWo
//
//  【按缝新写 · M3 T2】出处：
//    - 06-codex-gap1 §八.1/§八.3 —— 规则引擎接 pre-execute 缝（命中取最严，
//      未命中回落既有审批 waterfall）+ 会话级审批缓存（完备键）；
//    - §七.3 —— 沉淀（ApprovedExecpolicyAmendment 形态：审批通过 + 用户点
//      「允许并记住」→ bash 命令导出 allow 前缀规则落盘 user 层；黑名单与
//      签名去重把关）；
//    - dsh packages/interaction/permission-presets/src/index.ts —— /permission
//      handler 文案形态（空输入报当前值 + available 清单；未知名报错带清单）
//      + apply 的 diff 写语义 + preset 切换以 user 消息叙述（dsh inject user
//      message 语义；WanWo 以 <permission-update> 标记前缀落盘 user/message，
//      投影层过滤不渲染气泡）。
//    - dsh CONTEXT_ORDERS approval-policy(115) —— 审批策略动态上下文位。
//      WanWo 落点 = RuntimeContextProjection 快照通道（ContextInjector.
//      approvalPolicyProvider 供值）：完整当前值跟随、仅变化才重注入、缓存
//      前缀不破（ERR-024 纪律：快照不进 system——「system 段」字面与缓存
//      纪律冲突处按快照位实现，偏差登记见批次报告）。
//  事件词汇：approval/policy 走 E1 extensionEvent 通道（T2 报批登记；
//  schema 由 AppEnvironment 装配期注册：policy ∈ {ask, never}，
//  projection=logOnly，pairing=none）。
//

import Foundation

/// 每会话权限协调器：双旋钮状态 + 规则引擎入口 + 会话审批缓存 + 沉淀 +
/// /permission 实现 + approval-policy 上下文位供值。
/// 线程模型：审批缝在后台线程读（knobs/rules/cache 均 NSLock 保护），
/// /permission 在命令任务写。
final class PermissionCoordinator: @unchecked Sendable {
    /// approval/policy 扩展事件 kind（wire type = "extension/approval/policy"）。
    static let policyEventKind = "approval/policy"
    /// 沉淀前缀规则的 token 上限（防超长命令生成巨型规则）。
    static let maxPrefixTokens = 8

    let knobs = PermissionKnobs()
    let rules: PermissionRulesStore
    private let cache = SessionApprovalCache()
    private let writer: SessionWriter
    /// 会话工作目录（缓存键「环境」位；M1-M3 恒定值）。
    private let cwd: String

    private static let logger = AppLogger(category: "PermissionCoordinator")

    init(writer: SessionWriter,
         rules: PermissionRulesStore,
         cwd: String = WanWoPaths.workspaceLinuxDir) {
        self.writer = writer
        self.rules = rules
        self.cwd = cwd
        restoreApprovalPolicy()
    }

    // MARK: - 折叠（resume：从会话事件流恢复审批策略）

    /// 取事件流中最后一条 approval/policy 的 policy 值进内存（无历史 →
    /// 保持缺省 ask——fail closed 缺省）。
    private func restoreApprovalPolicy() {
        for event in writer.events.reversed() {
            if case .extensionEvent(Self.policyEventKind, let payload) = event.payload,
               let raw = payload.field("policy")?.stringValue,
               let policy = ApprovalPolicy(rawValue: raw) {
                knobs.approval = policy
                return
            }
        }
    }

    // MARK: - 规则引擎 + 策略指纹 + 会话缓存（CompositeApprovalSeam 消费）

    /// 规则引擎判定入口（多层引擎；nil = 未命中 → 调用方回落启发式矩阵）。
    func rulesVerdict(tool: String, args: JSONValue) -> ApprovalDecisionVerdict? {
        rules.engine().decide(tool: tool, args: args)
    }

    /// 策略指纹（codex requirements 指纹语义：审批策略值 + 规则库版本摘要）。
    var policyFingerprint: String {
        knobs.approval.rawValue + ":" + rules.signatureDigest()
    }

    /// 会话审批缓存查询（gap1 §八.3 完备键；命中 = 本会话已批准过同一请求）。
    func cachedApproval(tool: String, args: JSONValue) -> Bool {
        cache.contains(Self.cacheKey(tool: tool, args: args))
    }

    /// 会话审批缓存登记（allowedOnce 结算后调用）。
    func rememberApproval(tool: String, args: JSONValue) {
        cache.insert(Self.cacheKey(tool: tool, args: args))
    }

    private func cacheKey(tool: String, args: JSONValue) -> String {
        SessionApprovalCache.key(cwd: cwd, tool: tool, args: args,
                                 sandboxMode: knobs.sandbox.rawValue,
                                 policyFingerprint: policyFingerprint)
    }

    // MARK: - 沉淀（「允许并记住」→ 前缀规则落盘）

    /// 把审批通过的 bash 命令沉淀为 allow 前缀规则（user 层 JSONL 追加，
    /// flock 排他 + 签名去重；黑名单命中拒绝沉淀）。返回用户可见结果文案。
    func sedimentPrefixRule(fromCommand command: String) -> String {
        let tokens = PermissionRulesEngine.tokenize(command)
        guard !tokens.isEmpty else {
            return "记住失败：命令为空"
        }
        if let violation = BannedPrefixSuggestions.violation(in: tokens) {
            Self.logger.warning("sediment refused: banned prefix \"\(violation)\"")
            return "记住失败：命令前缀 \"\(violation)\" 在禁推黑名单内，不允许沉淀为规则"
        }
        let pattern = tokens.prefix(Self.maxPrefixTokens).map { [$0] }
        let prefixText = pattern.map { $0[0] }.joined(separator: " ")
        let rule = PermissionRule(
            id: UUID().uuidString,
            kind: "prefix",
            pattern: Array(pattern),
            host: nil,
            verdict: PermissionRuleVerdict.allow.rawValue,
            source: "remembered",
            origin: command,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        if rules.add(rule) {
            return "已记住：以 \"\(prefixText)\" 开头的命令今后将直接放行（可在 设置 · 权限 中管理）"
        }
        return "该命令前缀规则已存在，无需重复记住"
    }

    // MARK: - /permission（dsh permission-presets handler 语义）

    /// 空输入 → 当前值 + available 清单（dsh handler 文案形态）。
    func statusText() -> String {
        let current = knobs.currentPresetName()
        let available = PermissionPresets.availableNames.joined(separator: ", ")
        return "当前权限预设：\(current)（sandbox: \(knobs.sandbox.rawValue), "
            + "approval: \(knobs.approval.rawValue)）\n"
            + "可选预设：\(available)\n"
            + "read-only 档需自定义预设，本构建暂未提供；custom 为派生态，不可作为切换目标。"
    }

    /// 切换预设（dsh apply 语义适配：审批旋钮持久 diff 写；沙箱旋钮内存
    /// diff 写；叙述以 user 消息注入——model-visible=logged）。
    func applyPreset(named rawName: String?) async -> String {
        let name = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return statusText() }
        guard name != PermissionPresets.custom else {
            return "错误：\"custom\" 是派生态，不能作为切换目标。可选预设："
                + PermissionPresets.availableNames.joined(separator: ", ")
        }
        guard let spec = PermissionPresets.spec(named: name) else {
            return "错误：未知权限预设 \"\(name)\"。可选预设："
                + PermissionPresets.availableNames.joined(separator: ", ")
        }
        if knobs.currentPresetName() == spec.name {
            return "已处于权限预设 \"\(spec.name)\"，无需切换。"
        }
        // 审批旋钮：持久 diff 写（值没变不写；落盘失败绝不进内存——fail closed）。
        if knobs.approval != spec.approval {
            do {
                _ = try await writer.append(.extensionEvent(
                    kind: Self.policyEventKind,
                    payload: .object(["policy": .string(spec.approval.rawValue)])))
            } catch {
                Self.logger.error("approval/policy append failed: "
                    + "\(String(describing: error))")
                return "错误：审批策略落盘失败（\(String(describing: error))），"
                    + "预设未切换（fail closed）。"
            }
            knobs.approval = spec.approval
        }
        // 沙箱旋钮：内存 diff 写（sandbox/mode 事件词汇未获报批——偏差登记）。
        if knobs.sandbox != spec.sandbox {
            knobs.sandbox = spec.sandbox
        }
        knobs.lastSelection = spec.name
        // 切换叙述（dsh inject user message；<permission-update> 前缀由投影层
        // 过滤——用户可见反馈走 command/done 文本）。叙述丢失不致命（快照位
        // 仍会随下次注入携带当前策略），故 try? 静默。
        let narration = "<permission-update>\n权限预设已切换为 \"\(spec.name)\""
            + "（sandbox: \(spec.sandbox.rawValue), approval: \(spec.approval.rawValue)）。"
        try? await writer.append(.userMessage(text: narration))
        return "已切换到权限预设 \"\(spec.name)\" — sandbox: \(spec.sandbox.rawValue), "
            + "approval: \(spec.approval.rawValue)。"
    }

    // MARK: - approval-policy 动态上下文位（CONTEXT_ORDERS 115）

    /// 当前审批策略上下文行（ContextInjector.approvalPolicyProvider 装配；
    /// 快照通道注入——完整当前值跟随，仅变化时重注入，缓存前缀不破）。
    var approvalPolicyContextLine: String? {
        switch knobs.approval {
        case .ask:
            return "approval-policy: ask — tools with side effects require explicit user "
                + "approval before each run, unless a remembered permission rule allows them."
        case .never:
            return "approval-policy: never — no approval prompts are shown; calls that "
                + "would require approval are rejected outright."
        }
    }
}
