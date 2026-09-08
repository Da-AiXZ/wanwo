//
//  ApprovalDecision.swift
//  WanWo
//
//  【语义移植 · M3 T1 判定骨架】出处：
//    - 06-codex-gap1 §3.1/§八.1 —— 三值 Decision（allow/prompt/forbidden）与
//      审批旋钮解耦；规则引擎（T2）作为 pre-execute 缝的高优先级判定入口，
//      allow→跳过审批 / prompt→走既有审批缝 / forbidden→阻断（带 justification）。
//    - 06-codex-gap1 §4.6 —— default_exec_approval_requirement 纯旋钮矩阵：
//      策略未声明的部分由沙箱兜底，规则明说 prompt 的部分才弹窗。
//    - m3-scope-brief §二.3 —— T1「ApprovalDecision 判定骨架：workspace-write
//      最简矩阵起步 + 工具效果分类静态表」；T2 规则引擎（prefix/network 规则、
//      取最严、沉淀写回）接管 rows 后本表保留为兜底分类。
//    - dsh packages/interaction/user-approval/src/index.ts:48-68 —— dsh 自身
//      无效果分类表（审批由沙箱拒绝触发）；WanWo T1 无沙箱强制（M5），
//      以静态效果分类近似 dsh「沙箱拒绝才问」的触发面，偏差已登记。
//  fail-closed 纪律：未分类工具一律 prompt（绝不默认放行）。
//

import Foundation

// MARK: - 三值判定（06-codex-gap1 §3.1 Decision）

/// 规则/矩阵判定的三值结论（codex Decision 词汇）：
///   · allow     —— 直接放行（跳过审批缝）；
///   · prompt    —— 需要询问（走 ApprovalCoordinator 挂起）；
///   · forbidden —— 确定性拒绝（不询问，合成失败结果）。
enum ApprovalDecisionVerdict: Equatable, Sendable {
    case allow
    case prompt
    case forbidden

    /// 取最严（06-codex-gap1 §七.2：多条命中取 max，只增不减）。
    /// 严格度序：allow < prompt < forbidden。
    static func strictest(_ a: ApprovalDecisionVerdict, _ b: ApprovalDecisionVerdict)
        -> ApprovalDecisionVerdict {
        switch (a, b) {
        case (.forbidden, _), (_, .forbidden): return .forbidden
        case (.prompt, _), (_, .prompt): return .prompt
        default: return .allow
        }
    }
}

// MARK: - 工具效果分类静态表

/// 工具效果分类（静态表；T1 骨架，T2 规则引擎接管后保留为兜底）。
enum ToolEffect: String, Sendable {
    /// 只读观察类：无副作用。
    case readOnly
    /// 工作区写入类：workspace-write 档的工作区写放行，read-only 档需审批。
    case workspaceWrite
    /// 任意效果类（bash 等）：沙箱强制缺位时一律审批。
    case arbitrary
    /// 人机交互类：工具本身在收集人类输入，绝不可再触发审批（自锁死锁）。
    case interaction
}

enum ToolEffectTable {
    /// 只读观察类（WanWo 内置工具清单逐一归类；web_search/web_fetch 为网络读）。
    static let readOnly: Set<String> = ["read", "glob", "grep", "read_image",
                                        "web_search", "web_fetch"]
    /// 工作区写入类（fs 写侧三件；均在 /var/wanwo/workspace 工作区内）。
    static let workspaceWrite: Set<String> = ["write", "edit", "str_replace_editor"]
    /// 人机交互类（ask_user_question 自身；语义出处 dsh tool-ask-user——
    /// 工具在暂停等人类回答，若再触发审批会互相等待死锁）。
    static let interaction: Set<String> = ["ask_user_question"]
    /// 任意效果类：bash（guest 内任意代码执行）。
    static let arbitrary: Set<String> = ["bash"]

    /// 分类查询；未注册工具一律 arbitrary（fail closed：未分类即 prompt）。
    static func classify(_ tool: String) -> ToolEffect {
        if readOnly.contains(tool) { return .readOnly }
        if workspaceWrite.contains(tool) { return .workspaceWrite }
        if interaction.contains(tool) { return .interaction }
        if arbitrary.contains(tool) { return .arbitrary }
        return .arbitrary
    }
}

// MARK: - 判定矩阵

/// 审批判定矩阵（T1：workspace-write 最简矩阵起步；T2 规则引擎接管 rows）。
///
/// 叠加语义（06-codex-gap1 §八.1/§七.2）：有序规则行先判（多条命中取最严），
/// 未命中回落到「沙箱模式 × 工具效果」静态矩阵——对应 codex
/// 「规则未声明的部分由沙箱兜底，规则明说 prompt 的部分才弹窗」（§4.4）。
struct ApprovalDecisionMatrix: Sendable {
    /// 沙箱档（dsh permission-presets 双旋钮的 sandbox 旋钮词汇；T2 接三档切换，
    /// T1 固定 workspace-write 缺省档——m3-scope-brief §三.2 默认表）。
    enum SandboxMode: String, Sendable {
        case readOnly = "read-only"
        case workspaceWrite = "workspace-write"
        case dangerFullAccess = "danger-full-access"
    }

    /// 有序规则行（T1 为空表占位；T2 由声明式规则引擎填充 prefix/network 规则）。
    struct Row: Sendable {
        /// 命中谓词（T1 无行；T2 换成 prefix/network 匹配器）。
        let matches: @Sendable (_ tool: String, _ args: JSONValue) -> Bool
        let verdict: ApprovalDecisionVerdict
        /// 判定理由（forbidden/prompt 时进审批呈现与合成结果）。
        let reason: String?
    }

    let sandboxMode: SandboxMode
    var rows: [Row] = []

    init(sandboxMode: SandboxMode = .workspaceWrite, rows: [Row] = []) {
        self.sandboxMode = sandboxMode
        self.rows = rows
    }

    /// 判定一笔工具调用（纯函数：仅依赖 tool/args/sandboxMode/rows——
    /// live 与 replay 同形，与 ToolCardIntent 纯函数契约同纪律）。
    func decide(tool: String, args: JSONValue) -> ApprovalDecisionVerdict {
        // 1. 规则行先行，多条命中取最严（T1 rows 恒空；T2 填充）。
        var verdict: ApprovalDecisionVerdict?
        for row in rows where row.matches(tool, args) {
            let current = verdict.map { ApprovalDecisionVerdict.strictest($0, row.verdict) }
                ?? row.verdict
            verdict = current
        }
        if let verdict { return verdict }

        // 2. 静态矩阵兜底（workspace-write 最简矩阵）。
        switch ToolEffectTable.classify(tool) {
        case .interaction:
            // 交互工具不得再触发审批（否则审批卡与提问卡互相等待死锁）。
            return .allow
        case .readOnly:
            return .allow
        case .workspaceWrite:
            return sandboxMode == .readOnly ? .prompt : .allow
        case .arbitrary:
            // bash 与未分类工具：T1 无沙箱强制（M5）→ 一律审批（fail closed：
            // 宁可多问，不可放行任意效果）。danger-full-access 档全放行
            // （dsh：该档捆绑 approval=never 且沙箱不设限，无审批触发面）。
            return sandboxMode == .dangerFullAccess ? .allow : .prompt
        }
    }
}
