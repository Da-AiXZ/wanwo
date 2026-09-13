//
//  SandboxSeam.swift
//  WanWo
//
//  【M5-B 批 S1 · 沙箱执行缝抽象（F024）】出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/sandbox/sandbox/src/index.ts（178 行全文）：
//    - :39-52  SandboxExecutionPolicy（per-call 载体；sessionId 可缺省）
//    - :54-62  SandboxEnforcement full|partial（partial = 在场后端不能治理
//      每个承诺的文件效果；要求绝对边界的消费者不得当作 full）
//    - :61-68  per-call 语义（两消费者同刻可各在不同策略下受限；批准的提权
//      重试 = 更宽策略的新调用——注释逐条移植）
//    - :74-88  RunnerFailureRule（allowedExitCodes 门 → informational 全行
//      等值剥除 → fatalSignatures 行内大小写不敏感子串；仅退出码永不证明
//      runner 失败）
//    - :90-116 ConfinedArgv（denialSignatures = 该后端的拒绝方言——消费者
//      只对本后端方言匹配，绝不跨后端并集：并集会虚报某后端从不产出的拒绝）
//    - :118-144 SANDBOX_UNAVAILABLE 错误码 + SandboxUnavailableError 文案逐字
//    - :152-176 SandboxProvider.confine 抽象契约（fail closed；静默不受限
//      直通禁止；唯一候选后端可跳过功能探针——其自身拒绝即 fail-closed 终点）
//  匹配函数移植：packages/shell/bash-sandbox/src/helpers.ts:61-116
//  （classifyDenial / classifyRunnerFailure / matchesSignature 逐函数）。
//  消费面先例：packages/sandbox/sandbox-local/src/index.ts:205-240
//  （DENIAL_SIGNATURES 方言表 / RUNNER_FAILURE_RULES 证据规则表 /
//  LocalSandboxProvider.confine 形状）。
//
//  WanWo 形态适配（登记）：
//    · argv → String 命令行：WanWo 执行 = /bin/sh 命令行串（dsh 的
//      shell-shaped consumer 传 ['bash','-c',command]——同一 shell 级身份；
//      未来 JS 栅栏/远程 provider 后端再引入各自包装形状）。
//    · dsh SandboxPolicy 的 ConfinedSandboxMode 窄化（:31-32/:69-72）不做：
//      Swift 无接口继承窄化，provider 直接收全三值 mode（danger 语义见下）。
//
//  ── enforcement 判定（本件核心论证，围栏实现取证后裁定：partial）────────
//    · iSH guest 进程天然隔离于宿主（无宿主内核对象可达），但这不等于
//      guest 视角文件效果受控——SandboxExecutionPolicy 承诺的是 guest 视角
//      文件效果（工作区/mount 桶在 guest 内可写）。
//    · read-only：bash 无进程级 wrapper（iOS 不可用 bwrap/Landlock/Seatbelt，
//      08 §二不可抗力），围栏 = SandboxGate 启发式写检测的 pre-execution
//      近似（重定向/写命令模式表，A2 登记漏检面——heredoc 落文件、安装的
//      解释器内写等形态不可枚举尽）→ 启发式不能治理每个承诺的文件效果
//      → partial（"启发式近似"不满足 "absolute boundary"，诚实标注——
//      派单倾向与取证事实一致）。
//    · workspace-write：bash 档不设围栏（SandboxGate.swift 头注 A2 登记
//      原文：「启发式无法验证 containment」）→ 同为 partial（两种 confined
//      模式同为 partial，强弱差距登记：read-only 有 pre-execution 近似门，
//      workspace-write 无门——双值词汇承载不了此差距，S2 消费面呈报时注意）。
//    · danger-full-access：dsh 策略面把 confined 模式窄化为不含 danger；
//      本缝 provider 收全三值时 danger 直通返回原命令、enforcement=.full：
//      该模式承诺的文件效果 = 「无限制」，不设围栏即完整兑现承诺（平凡的
//      完备），非承诺缺口。
//    · runner 失败面：iSH 执行链的 runner 失败 = kernelNotBooted /
//      spawnFailed（IshExecutorBridge.swift:147-161，抛错形态非子进程
//      stderr 行）→ fatalSignatures 取 errorDescription 原文；规则表为
//      词汇完备保留（消费面接线留 S2/P2 内部件）。
//    · denial 方言（fakefs 围栏拒绝文案取证，恰两源）：
//      ① WorkspaceFileAccess.WorkspaceError.pathOutsideRoot——"path escapes
//        the session workspace root: "（WorkspaceFileAccess.swift:351）
//      ② sandboxDenialMarker——"[sandbox: file access denied under "
//        （SandboxEscalation.swift:55；gate 合成拒绝 = bash 启发式与 fs
//        围栏两族的统一词汇）
//      方言纪律（dsh :100-108 注释）：消费者只对本后端方言匹配——guest
//      errno 通用文案（"permission denied" 等）不入表（WanWo 后端不产它，
//      并集会虚报拒绝）。
//    · 关于「静默不受限直通禁止」（dsh :153-157）：本 provider 对受限模式
//      返回的命令行虽原样透传，但不是「直通」——执行完备度由 partial 显式
//      承载、拒绝方言与证据规则随行，真实围栏在 gate（pre-execution）+
//      fakefs 进程内路径判定层（M3 定案）。dsh 该禁令的目标是「伪装有围栏
//      的无围栏透传」；WanWo 形态是诚实的完备度声明 + 周边缝内围栏，S2
//      消费面接线时以此为基础。
//

import Foundation

// MARK: - 策略载体（index.ts:39-52）

/// 一笔能力调用的完整文件效果策略（per-call 载体，dsh SandboxExecutionPolicy
/// 1:1）。root 在不消费它的模式下也随行（dsh :35-38 注释：消费者可在选择
/// 执行路径之前一次性解析策略）。
///
/// per-call 语义（dsh :61-68 注释逐条移植）：策略不固定在 provider 上——
/// 两个消费者可在同一瞬间各在不同策略下受限（bash 在 read-only 下跑而受限
/// 子代理需要其状态目录可写），批准的提权重试 = 携带更宽策略的新调用。
/// 缺省/解析是消费者边界的显式步骤；provider 把策略视为完全指定。
struct SandboxExecutionPolicy: Equatable, Sendable {
    /// 本次执行所处的文件效果模式。
    let mode: SandboxMode
    /// workspace-write 可写的绝对根目录。
    let workspaceRoot: String
    /// 调用会话的身份（dsh 品牌化 SessionId 归一为 String；后端按它键控
    /// per-session 状态）；nil = 无会话调用，回落 per-call 后端状态。
    let sessionId: String?

    init(mode: SandboxMode, workspaceRoot: String, sessionId: String? = nil) {
        self.mode = mode
        self.workspaceRoot = workspaceRoot
        self.sessionId = sessionId
    }
}

// MARK: - 执行完备度（index.ts:54-62）

/// 本宿主的执行完备度（dsh SandboxEnforcement 1:1）。partial = 在场后端
/// 不能治理每个承诺的文件效果；要求绝对边界的消费者不得当作 full。
enum SandboxEnforcement: String, Equatable, Sendable, CaseIterable {
    case full
    case partial
}

// MARK: - 证据规则（index.ts:74-88）

/// 标识沙箱 runner 在执行被包装命令之前失败的证据规则（dsh 1:1）。消费者
/// 匹配序：先（在场时）apply allowedExitCodes，再按全行大小写不敏感等值
/// 剥除 informationalLines，然后在每条残余 stderr 行内大小写不敏感匹配
/// fatalSignatures。仅退出码永不证明 runner 失败（:79 注释语义逐字）。
struct RunnerFailureRule: Equatable, Sendable {
    /// 本规则可匹配的非零退出码；nil = 任何非零退出均可。
    let allowedExitCodes: [Int]?
    /// 单条 stderr 行内的致命 runner 诊断非空子串。
    let fatalSignatures: [String]
    /// fatal 匹配前按全行等值排除的良性 stderr 行。
    let informationalLines: [String]?

    init(allowedExitCodes: [Int]? = nil,
         fatalSignatures: [String],
         informationalLines: [String]? = nil) {
        self.allowedExitCodes = allowedExitCodes
        self.fatalSignatures = fatalSignatures
        self.informationalLines = informationalLines
    }
}

// MARK: - confine 结果（index.ts:90-116 的 WanWo 形态）

/// SandboxProvider.confine 的结果：调用方据此执行替代形态 + 所选后端对该
/// 形态达成的执行完备度。WanWo 形态：command = /bin/sh 命令行串（dsh argv
/// 的 shell 级同一身份——见头注形态适配登记）。
struct ConfinedCommand: Equatable, Sendable {
    /// 替代执行的命令行（未来后端 = runner 前缀形态；iSH = 原样透传）。
    let command: String
    /// 所选后端对本策略文件效果的执行完备度。
    let enforcement: SandboxEnforcement
    /// 所选后端的拒绝方言：本后端拒绝文件效果时产出的大小写不敏感子串。
    /// 从失败运行的 stderr 推断拒绝的消费者，只对这些（而非跨后端并集）
    /// 匹配——并集会虚报某后端从不产出的拒绝（dsh :100-108 注释语义）。
    let denialSignatures: [String]
    /// 结构化 runner 失败证据规则。消费者须先见致命 stderr 行（informational
    /// 剥除后）+ 规则各自的退出码门，才检查拒绝签名：runner 失败 = 命令从未
    /// 跑，denial = 围栏生效且拦下了——两态不可混淆（dsh :109-115 注释语义）。
    let runnerFailureRules: [RunnerFailureRule]
}

// MARK: - 不可用错误（index.ts:118-144 逐字）

/// 请求受限模式但宿主无可用后端时抛出（provider fail closed；错误码经
/// 结构化错误通道透传 tool/result，调用方可区分「缺围栏」与「命令失败」）。
struct SandboxUnavailableError: Error, LocalizedError {
    /// dsh SANDBOX_UNAVAILABLE 错误码（index.ts:124）。
    static let code = "SANDBOX_UNAVAILABLE"

    let message: String
    var errorDescription: String? { message }

    /// dsh SandboxUnavailableError 构造文案逐字（index.ts:131-144）。
    init(mode: SandboxMode, detail: String? = nil) {
        self.message = "sandbox mode \"\(mode.rawValue)\" is requested but no sandbox backend is usable on this host; "
            + "refusing to run the command unconfined. Install bubblewrap or run a Landlock-enforcing "
            + "kernel (Linux), ensure sandbox-exec is usable (macOS), or ensure the ACL "
            + "restricted-token runner can start (Windows) — otherwise switch the consumer to "
            + "danger-full-access."
            + (detail.map { " Runner failure: \($0)" } ?? "")
    }
}

// MARK: - 抽象缝（index.ts:152-176）

/// 抽象进程沙箱服务（dsh SandboxProvider 抽象类的 Swift protocol 形态；
/// cordis Service 面不移植——AppEnvironment 装配注入，ShellTool.jobs 同款缝）。
/// confine 必须返回受限形态或在包装/runner 执行期 fail closed；静默不受限
/// 直通禁止（index.ts:153-157 注释语义——WanWo 形态的承载方式见文件头论证）。
/// 功能探针仲裁多 runner 链，唯一候选后端可跳过探针——其自身拒绝即
/// fail-closed 终点。
protocol SandboxProvider: Sendable {
    /// 把 command 包装成在 policy 下受限执行的形态；调用方执行返回的形态
    /// 替代自身原命令（WanWo 形态收命令行串——dsh argv，见头注）。
    /// - Parameters:
    ///   - policy: 本次执行的文件效果策略（per-call 载体，完全指定）。
    ///   - command: 调用方即将执行的命令行（非 shell 字符串包装层的内部
    ///     拆分——dsh 「NOT a shell string」的对应纪律：这里是 /bin/sh -c
    ///     的完整负载， consumers 已按 shell 级传递）。
    /// - Throws: 请求模式无法在本宿主执行时 fail closed
    ///   （SandboxUnavailableError，code=SANDBOX_UNAVAILABLE）。
    func confine(policy: SandboxExecutionPolicy, command: String) throws -> ConfinedCommand
}

// MARK: - 匹配函数（bash-sandbox helpers.ts:61-116 逐函数移植）

/// 沙箱结果分类助手（dsh bash-sandbox/src/helpers.ts 的消费面匹配逻辑；
/// 纯函数、大小写不敏感语义 1:1——S1 只移植词汇与函数，消费接线留 S2）。
enum SandboxSeamMatcher {

    /// 一条致命 runner 证据（原始命中行——基础设施错误 detail 用）。
    struct RunnerFailureMatch: Equatable, Sendable {
        let detail: String
    }

    /// classifyDenial（helpers.ts:67-69）：失败运行是否命中所选后端的拒绝
    /// 方言（大小写不敏感子串）。
    static func classifyDenial(exitCode: Int?, stderr: String,
                               signatures: [String]) -> Bool {
        return matchesSignature(exitCode: exitCode, stderr: stderr, signatures: signatures)
    }

    /// classifyRunnerFailure（helpers.ts:81-103 逐序移植）：对一条已结算的
    /// 进程按所选后端的结构化 runner 失败规则分类。每条规则要求非零退出 +
    /// （在场时）退出码门 + informational 全行剥除后单行内 fatal 子串命中。
    /// - Parameters:
    ///   - exitCode: 进程退出码；nil = 信号终止（不匹配）。
    ///   - stderr: 收集的 stderr 文本（原样不动）。
    ///   - rules: 活动包装的结构化 runner 失败规则。
    /// - Returns: 首个命中的致命行；证据不足 = nil。
    static func classifyRunnerFailure(exitCode: Int?, stderr: String,
                                      rules: [RunnerFailureRule]) -> RunnerFailureMatch? {
        if exitCode == nil || exitCode == 0 { return nil }
        // \r\n 折一 + 逐行切分（dsh split(/\r?\n/)；尾分隔符产空行同 JS）。
        let lines = stderr
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for rule in rules {
            if let allowed = rule.allowedExitCodes, !allowed.contains(exitCode!) { continue }
            let informational = Set((rule.informationalLines ?? []).map { $0.lowercased() })
            // 空串或纯空白子串不是有意义的 runner 证据——忽略之，同规则内
            // 其余合法签名保持活跃（helpers.ts:91-92 注释语义逐字）。
            let fatalSignatures = rule.fatalSignatures
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.lowercased() }
            for line in lines {
                let lowered = line.lowercased()
                if informational.contains(lowered) { continue }
                if fatalSignatures.contains(where: { lowered.contains($0) }) {
                    return RunnerFailureMatch(detail: line)
                }
            }
        }
        return nil
    }

    /// matchesSignature（helpers.ts:112-116 逐行移植）：非零退出 + stderr
    /// 大小写不敏感子串命中（helpers.ts:113 首行守卫同序）。
    static func matchesSignature(exitCode: Int?, stderr: String,
                                 signatures: [String]) -> Bool {
        if exitCode == nil || exitCode == 0 { return false }
        let lowered = stderr.lowercased()
        return signatures.contains { lowered.contains($0.lowercased()) }
    }
}

// MARK: - iSH 本地 provider（dsh sandbox-local 的 WanWo 形态）

/// iSH 本地沙箱 provider（WanWo 默认实现——唯一候选后端形态：无多 runner
/// 链、无功能探针，dsh :156-157 注释「sole candidate 可跳过探针，其自身
/// 拒绝即 fail-closed 终点」）。enforcement 判定与方言/证据表的论证见
/// 文件头（S1 呈报核心项）。struct 无状态 Sendable；未来后端链替换本实现。
struct LocalSandboxProvider: SandboxProvider {

    /// fakefs 围栏拒绝方言（本后端产出的两族文案——取证来源见文件头；
    /// 通用 errno 文案不入表：并集会虚报本后端从不产出的拒绝）。
    static let denialSignatures: [String] = [
        "path escapes the session workspace root: ",   // WorkspaceFileAccess.swift:351
        "[sandbox: file access denied under ",         // SandboxEscalation.swift:55
    ]

    /// runner 失败证据规则（iSH 执行链 spawn 前失败面的 errorDescription
    /// 原文——IshExecutorBridge.swift:147-161 kernelNotBooted/spawnFailed；
    /// 抛错形态非 stderr 行，规则表为词汇完备保留，消费接线 S2）。
    static let runnerFailureRules: [RunnerFailureRule] = [
        RunnerFailureRule(fatalSignatures: [
            "iSH kernel is not booted",               // ISHCoordinatorError.kernelNotBooted
            "Failed to spawn long-lived process",     // ISHCoordinatorError.spawnFailed
        ]),
    ]

    func confine(policy: SandboxExecutionPolicy, command: String) throws -> ConfinedCommand {
        switch policy.mode {
        case .dangerFullAccess:
            // 承诺 = 无限制，透传即完整兑现（论证见文件头 enforcement 段）。
            return ConfinedCommand(command: command, enforcement: .full,
                                   denialSignatures: [], runnerFailureRules: [])
        case .readOnly, .workspaceWrite:
            // 受限模式：iSH 无进程级 wrapper——命令原样透传（围栏在 gate 的
            // pre-execution 层 + fakefs 进程内路径判定层），执行完备度诚实
            // 标注 partial（论证见文件头）。将来 iSH 后端不可用面收编进
            // provider 时，在此抛 SandboxUnavailableError（fail-closed 终点）。
            return ConfinedCommand(command: command, enforcement: .partial,
                                   denialSignatures: Self.denialSignatures,
                                   runnerFailureRules: Self.runnerFailureRules)
        }
    }
}
