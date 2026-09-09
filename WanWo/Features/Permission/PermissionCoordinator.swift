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
//      纪律冲突处按快照位实现，team-lead 已追认）。
//  事件词汇：approval/policy（T2 批准）+ sandbox/mode（T2.1 补批，01 笔记
//  sandbox-policy 原件词汇）均走 E1 extensionEvent 通道，schema 由
//  AppEnvironment 装配期注册（projection=logOnly，pairing=none）。
//

import Foundation

/// 每会话权限协调器：双旋钮状态 + 规则引擎入口 + 会话审批缓存 + 沉淀 +
/// /permission 实现 + approval-policy 上下文位供值。
/// 线程模型：审批缝在后台线程读（knobs/rules/cache 均 NSLock 保护），
/// /permission 在命令任务写。
/// T2.1：双旋钮均持久——approval/policy 与 sandbox/mode 两个 extension 事件
/// （均已批）先落盘成功再进内存（fail closed）；resume 时分别折叠恢复。
final class PermissionCoordinator: @unchecked Sendable {
    /// approval/policy 扩展事件 kind（wire type = "extension/approval/policy"）。
    static let policyEventKind = "approval/policy"
    /// sandbox/mode 扩展事件 kind（wire type = "extension/sandbox/mode"；
    /// T2.1 补批——01 笔记 sandbox-policy 原件词汇，修沙箱旋钮内存态缺口）。
    static let sandboxEventKind = "sandbox/mode"
    /// 沉淀前缀规则的 token 上限（防超长命令生成巨型规则）。
    static let maxPrefixTokens = 8

    let knobs = PermissionKnobs()
    let rules: PermissionRulesStore
    private let cache = SessionApprovalCache()
    private let writer: SessionWriter
    /// 会话工作目录（缓存键「环境」位；M1-M3 恒定值）。
    private let cwd: String

    /// 新会话缺省双旋钮供值缝（T2.2 派单项 2：App 级默认源——设置·新会话
    /// 默认权限行；不再硬编码 ask+workspace-write。缺省供值 = dsh
    /// BootHostOptions.sandbox 部署默认语义，笔记 :13）。
    let newSessionDefaults: @Sendable () -> (sandbox: SandboxMode,
                                             approval: ApprovalPolicy)

    private static let logger = AppLogger(category: "PermissionCoordinator")

    init(writer: SessionWriter,
         rules: PermissionRulesStore,
         cwd: String = WanWoPaths.workspaceLinuxDir,
         newSessionDefaults: @escaping @Sendable () -> (sandbox: SandboxMode,
                                                        approval: ApprovalPolicy) =
            { (.workspaceWrite, .ask) }) {
        self.writer = writer
        self.rules = rules
        self.cwd = cwd
        self.newSessionDefaults = newSessionDefaults
        restoreKnobs()
    }

    // MARK: - 折叠（resume：从会话事件流恢复双旋钮）

    /// 分别取事件流中最后一条 approval/policy 与 sandbox/mode 的值进内存
    /// （有历史 → 事件值优先；无对应历史 → 回落 App 级新会话默认源——T2.2：
    /// 设置·新会话默认权限行。两旋钮独立判定，fail closed 不混合猜测）。
    private func restoreKnobs() {
        for event in writer.events.reversed() {
            if case .extensionEvent(Self.policyEventKind, let payload) = event.payload,
               let raw = payload.field("policy")?.stringValue,
               let policy = ApprovalPolicy(rawValue: raw) {
                knobs.approval = policy
                break
            }
        }
        for event in writer.events.reversed() {
            if case .extensionEvent(Self.sandboxEventKind, let payload) = event.payload,
               let raw = payload.field("mode")?.stringValue,
               let mode = SandboxMode(rawValue: raw) {
                knobs.sandbox = mode
                break
            }
        }
        let defaults = newSessionDefaults()
        if !hasPolicyEvent {
            knobs.approval = defaults.approval
        }
        if !hasSandboxEvent {
            knobs.sandbox = defaults.sandbox
        }
    }

    /// 事件流中是否存在过对应旋钮事件（恢复优先级判定用）。
    private var hasPolicyEvent: Bool {
        writer.events.contains {
            if case .extensionEvent(Self.policyEventKind, _) = $0.payload { return true }
            return false
        }
    }

    private var hasSandboxEvent: Bool {
        writer.events.contains {
            if case .extensionEvent(Self.sandboxEventKind, _) = $0.payload { return true }
            return false
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
        cache.contains(cacheKey(tool: tool, args: args))
    }

    /// 会话审批缓存登记（allowedOnce 结算后调用）。
    func rememberApproval(tool: String, args: JSONValue) {
        cache.insert(cacheKey(tool: tool, args: args))
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
            + "custom 为派生态，不可作为切换目标。"
    }

    /// 切换预设（dsh apply 语义：双旋钮持久 diff 写——先全部落盘成功再统一
    /// 进内存，任一失败整体不切换（fail closed）；叙述以 user 消息注入——
    /// model-visible=logged）。
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
        // 双旋钮持久 diff 写（值没变不写；schema 由写侧门校验，词汇恒合法；
        // 先写后提交内存——半切换状态不存在，fail closed）。
        do {
            if knobs.approval != spec.approval {
                _ = try await writer.append(.extensionEvent(
                    kind: Self.policyEventKind,
                    payload: .object(["policy": .string(spec.approval.rawValue)])))
            }
            if knobs.sandbox != spec.sandbox {
                _ = try await writer.append(.extensionEvent(
                    kind: Self.sandboxEventKind,
                    payload: .object(["mode": .string(spec.sandbox.rawValue)])))
            }
        } catch {
            Self.logger.error("permission preset append failed: "
                + "\(String(describing: error))")
            return "错误：预设落盘失败（\(String(describing: error))），"
                + "预设未切换（fail closed）。"
        }
        knobs.approval = spec.approval
        knobs.sandbox = spec.sandbox
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

    // MARK: - 动态上下文位（CONTEXT_ORDERS sandbox:policy 110 + approval-policy 115）

    /// dsh user-approval index.ts:68 ASK_SENTENCE 逐字。
    private static let askSentence = "Approval policy: ask. Operations that require approval may ask "
        + "through the configured answerers; without an available answerer, the request fails closed."
    /// dsh user-approval index.ts:66 NEVER_SENTENCE 逐字。
    private static let neverSentence = "Approval prompts are disabled in this session: actions that "
        + "require approval are rejected automatically — do not request sandbox escalation "
        + "(do not set `sandbox_permissions`)."

    /// 当前审批策略上下文行（ContextInjector.approvalPolicyProvider 装配；
    /// 快照通道注入——完整当前值跟随，仅变化时重注入，缓存前缀不破）。
    var approvalPolicyContextLine: String? {
        switch knobs.approval {
        case .ask: return Self.askSentence
        case .never: return Self.neverSentence
        }
    }

    /// 当前沙箱策略上下文行（P1-3：CONTEXT_ORDERS sandbox:policy 110——dsh
    /// sandbox-policy renderPolicyContext 三段逐字，SandboxPolicy.renderPolicyContext）。
    var sandboxPolicyContextLine: String? {
        SandboxPolicy.renderPolicyContext(knobs.sandbox)
    }
}
