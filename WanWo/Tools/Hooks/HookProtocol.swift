//
//  HookProtocol.swift
//  WanWo
//
//  【语义移植 · dsh hook-protocol 四纯函数件】出处（逐行亲读，file:line 对拍）：
//    - packages/hooks/hook-protocol/src/types.ts:56-137（CommandHook /
//      MatcherGroup / MatcherMode / HookOutput——M4-E 合并批 E1 端口）
//    - src/codec.ts 全文（:1-135；BLOCKING_EXIT_CODE=2:11 / parseHookOutput:59-89 /
//      applyStructured:97-134）
//    - src/merge.ts 全文（:1-101；rank:35-42 / mergeHookOutputs:62-100）
//    - src/matcher.ts 全文（:1-66；isMatchAll:13-15 / CLAUDE_LITERAL:18 /
//      compileRegex:21-29 / matcherDiagnostic:37-44 / matchesMatcher:57-65）
//  E1 范围=四纯函数件（零宿主依赖、零事件词汇——R2/R3 天然满足）；events
//  （hook/* 事件对）/invariant/detached 属 E3/E5 不越界。README 语义原文：
//  "Dialect-neutral vocabulary shared by the Claude Code and Codex hook
//  bridges. Payload construction, matching differences, environment, and
//  extension-point-specific decision mapping remain owned by each bridge."
//
//  JS→Swift 形态映射（差异登记见 E1 呈报）：
//    · MatcherMode 'claude-code'|'codex' → enum 双 case rawValue 保真。
//    · HookOutput.decision 五值枚举（'approve'|'allow'|'block'|'deny'|'ask'）
//      → HookDecision enum；可选性逐字段保真（全部 optional——hook 可行使
//      任意子集，bridge 决定哪些字段对其 hook point 有意义）。
//    · `continue` 为 Swift 关键字——属性名用反引号保真（dsh 字段名 1:1）。
//    · updatedInput Record<string, unknown> → [String: JSONValue]（ERR-026
//      纪律：经既有 JSONValue 无损载体）。
//    · JS RegExp（无 flag 的 test() = unanchored search）→ NSRegularExpression
//      默认选项 firstMatch != nil（等价性自证见呈报③）。
//

import Foundation

// MARK: - types（types.ts:56-137）

/// dsh types.ts:79——matcher 模式：Claude Code 对纯 `[A-Za-z0-9_|]+` 模式用
/// literal（pipe=精确备选）、其余用 regex；Codex 恒 regex。bridge 按方言择定。
/// （rawValue 与 dsh 词汇 1:1——与 HookDialect 同词汇形状，E3 事件面另行取用。）
enum MatcherMode: String, Equatable, Sendable {
    case claudeCode = "claude-code"
    case codex = "codex"
}

/// dsh types.ts:56-61——一条 command hook（两方言共有的 `{ type:'command',
/// command, timeout? }` 形状；CC 的 prompt/agent/http 非命令型由 bridge 解析后
/// 跳过，到 runner 的只有此形状）。
struct CommandHook: Equatable, Sendable {
    /// 待执行的 shell 命令行。
    var command: String
    /// 每 hook 超时（秒——线上单位；runner 换算 ms）。
    var timeoutSec: Int?

    init(command: String, timeoutSec: Int? = nil) {
        self.command = command
        self.timeoutSec = timeoutSec
    }
}

/// dsh types.ts:68-71——一个 matcher 组：matcher 模式（absent/''/'*' = 全匹配）
/// + 匹配时运行的命令 hooks。两方言同形状（CC/Codex 的 hooks.json）。
struct MatcherGroup: Equatable, Sendable {
    var matcher: String?
    var hooks: [CommandHook]

    init(matcher: String? = nil, hooks: [CommandHook]) {
        self.matcher = matcher
        self.hooks = hooks
    }
}

/// dsh types.ts:119——hook 表达的中性 blocking decision，由两通道折叠：
/// 顶层 legacy `decision`（仅 approve/block）与 hookSpecificOutput.
/// permissionDecision（仅 allow/deny/ask）。归一为一枚举——block/deny 禁止、
/// approve/allow 放行、ask 待确认；allow/deny/ask 只可能来自 permissionDecision。
enum HookDecision: String, Equatable, Sendable {
    case approve
    case allow
    case block
    case deny
    case ask
}

/// dsh types.ts:89-137——一个 hook 产出的方言中性 outcome（parseHookOutput 从
/// exit code + stdout JSON + stderr 解析）。每字段可选：hook 可行使任意子集。
struct HookOutput: Equatable, Sendable {
    /// 原始进程退出码（hook 未能运行时为 nil）。
    var exitCode: Int?
    /// trim 后的 stderr——blocking（exit 2）hook 的 block-reason 来源。
    var stderr: String
    /// trim 后 stdout 原文（CC 渲染为输出 / Codex 视为 additionalContext——
    /// bridge 需要原文而非只有结构化字段；无 stdout 时空串）。
    var stdout: String
    /// false ⇒ hook 请求中止（CC/Codex continue:false），伴随 stopReason；
    /// true/absent ⇒ 继续。（dsh 字段名 1:1——Swift 关键字反引号保真。）
    var `continue`: Bool?
    /// continue=false 时展示的人读理由。
    var stopReason: String?
    /// 折叠的中性 blocking decision（见 HookDecision 注释）；absent ⇒ 无显式
    /// decision（由 exit code 治理）。
    var decision: HookDecision?
    /// 伴随 decision 的理由/解释。
    var reason: String?
    /// hookSpecificOutput 声称的事件判别名；异名时 parseHookOutput 保留此值
    /// 但丢弃事件域字段。
    var hookEventName: String?
    /// 注入下一模型请求的额外上下文（CC additionalContext）。
    var additionalContext: String?
    /// 呈给用户的警告（CC systemMessage）。
    var systemMessage: String?
    /// hook 请求的工具输入改写（CC updatedInput）。**已解析但不执行**——输入
    /// 改写延迟设计（dsh interception extension-points Agent Note）；bridge
    /// 在场时 log+warn。
    var updatedInput: [String: JSONValue]?

    init(exitCode: Int? = nil,
         stderr: String = "",
         stdout: String = "",
         `continue`: Bool? = nil,
         stopReason: String? = nil,
         decision: HookDecision? = nil,
         reason: String? = nil,
         hookEventName: String? = nil,
         additionalContext: String? = nil,
         systemMessage: String? = nil,
         updatedInput: [String: JSONValue]? = nil) {
        self.exitCode = exitCode
        self.stderr = stderr
        self.stdout = stdout
        self.continue = `continue`
        self.stopReason = stopReason
        self.decision = decision
        self.reason = reason
        self.hookEventName = hookEventName
        self.additionalContext = additionalContext
        self.systemMessage = systemMessage
        self.updatedInput = updatedInput
    }
}

// MARK: - codec（codec.ts 全文）

/// 两方言共用的 hook 进程输出解码（纯函数域）。exit 0 可携带结构化 JSON 或
/// plain stdout；exit 2 以 stderr 为理由阻断；其余退出码=非阻断错误。哪些
/// 识别字段生效由 bridge 决定。
enum HookCodec {
    /// codec.ts:11——hook 表示阻断错误的退出码（stderr → model）。
    static let blockingExitCode = 2

    /// codec.ts:59-89——把进程输出解码为方言中性 outcome。全函数（total）：
    /// malformed JSON 保持 plain stdout。`expectedEventName`（触发事件）非 nil
    /// 时，hookSpecificOutput 缺名或异名只丢弃其事件域字段（顶层字段与声称的
    /// 判别名保留）；nil = 关闭守卫（阻断照常生效）。
    static func parseHookOutput(exitCode: Int?,
                                stdout: String,
                                stderr: String,
                                expectedEventName: String? = nil) -> HookOutput {
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // 非 JSON 的 plain stdout 仍可用（codec.ts:62）。
        var output = HookOutput(exitCode: exitCode, stderr: trimmedErr, stdout: trimmedOut)

        // 两方言都把 exit 2 视为以 stderr 为理由的阻断（codec.ts:66-69）。
        if exitCode == blockingExitCode {
            output.decision = .block
            if !trimmedErr.isEmpty { output.reason = trimmedErr }
        }

        // 结构化 stdout 只在干净退出时有效（codec.ts:72-86）：仅当 stdout 以
        // '{' 开头才尝试 JSON——与参照引擎一致，其余 stdout 是纯文本不是错误。
        if exitCode == 0, trimmedOut.hasPrefix("{") {
            // 干净退出上的 malformed JSON = 无结构化输出（宽容；plain stdout
            // 仍归 bridge 使用）。
            let parsed: JSONValue?
            if let any = try? JSONSerialization.jsonObject(
                with: Data(trimmedOut.utf8), options: []) {
                parsed = JSONValue(any: any)
            } else {
                parsed = nil
            }
            if let fields = parsed?.objectFields {
                applyStructured(&output, parsed: fields,
                                expectedEventName: expectedEventName)
            }
        }
        return output
    }

    /// codec.ts:97-134——把解析出的结构化 stdout 折入 output。
    /// expectedEventName 门控 hookSpecificOutput 块：hookEventName 缺名或异名
    /// → 事件域字段丢弃（在场判别名仍记录——codec.ts:120，日志应显示坏块声称了什么）。
    private static func applyStructured(_ output: inout HookOutput,
                                        parsed: [String: JSONValue],
                                        expectedEventName: String?) {
        // 顶层 continue/stopReason/systemMessage 直取（:98-103）。
        if let cont = parsed["continue"]?.boolValue { output.continue = cont }
        if let stopReason = parsed["stopReason"]?.stringValue { output.stopReason = stopReason }
        if let sysMsg = parsed["systemMessage"]?.stringValue { output.systemMessage = sysMsg }

        // 顶层 legacy decision（仅 approve/block——allow/deny/ask 在此为两 schema
        // 皆无效）+ 其 reason（:107-110）。
        if let topDecision = topLevelDecision(of: parsed["decision"]?.stringValue) {
            output.decision = topDecision
        }
        if let topReason = parsed["reason"]?.stringValue { output.reason = topReason }

        // hookSpecificOutput：按 hookEventName 键控的每事件通道。permissionDecision
        // （allow/deny/ask）覆盖 legacy 顶层 decision；additionalContext 与
        // updatedInput 也在此块（:115-132）。
        guard let hso = parsed["hookSpecificOutput"]?.objectFields else { return }
        let eventName = hso["hookEventName"]?.stringValue
        // 判别名恒浮出（供日志/诊断），异名也记录（:120）。
        if let eventName { output.hookEventName = eventName }
        // 缺名或异名的块不能影响触发事件（:122-124）。
        if let expectedEventName, eventName != expectedEventName {
            return
        }
        if let permission = permissionDecision(of: hso["permissionDecision"]?.stringValue) {
            output.decision = permission
        }
        if let permissionReason = hso["permissionDecisionReason"]?.stringValue {
            output.reason = permissionReason
        }
        if let addCtx = hso["additionalContext"]?.stringValue {
            output.additionalContext = addCtx
        }
        if let updated = hso["updatedInput"]?.objectFields {
            output.updatedInput = updated
        }
    }

    /// codec.ts:38-40——顶层 legacy decision 仅 approve/block（allow/deny/ask 为
    /// permissionDecision 保留；越界的 {"decision":"deny"} 无效忽略）。
    private static func topLevelDecision(of value: String?) -> HookDecision? {
        guard let value else { return nil }
        return value == HookDecision.approve.rawValue || value == HookDecision.block.rawValue
            ? HookDecision(rawValue: value) : nil
    }

    /// codec.ts:43-45——permissionDecision 仅 allow/deny/ask。
    private static func permissionDecision(of value: String?) -> HookDecision? {
        guard let value else { return nil }
        return value == HookDecision.allow.rawValue || value == HookDecision.deny.rawValue
            || value == HookDecision.ask.rawValue
            ? HookDecision(rawValue: value) : nil
    }
}

// MARK: - merge（merge.ts 全文）

/// merge.ts:12——一个 hook point 折叠后的单一 decision。
enum MergedDecision: String, Equatable, Sendable {
    case allow
    case ask
    case deny
    case none
}

/// merge.ts:15-32——一个 point 上全部匹配 hooks 的折叠 outcome。
struct MergedHookOutcome: Equatable, Sendable {
    /// 全部 hooks 中最严的 permission decision（deny > ask > allow），无表达时
    /// none。block/deny 都折为 deny；approve/allow 都折为 allow。
    var decision: MergedDecision
    /// 阻断/拒绝 hooks 的理由以 '\n\n' 连接（无则 nil）。
    var reason: String?
    /// 任一 hook 请求中止（continue:false）时 true。
    var stop: Bool
    /// 首个中止 hook 的 stopReason（有中止时）。
    var stopReason: String?
    /// 每个 hook 的 additionalContext（按 hook 序，不连接——由 bridge 决定）。
    var additionalContext: [String]
    /// 每个 hook 的 systemMessage（按 hook 序）。
    var systemMessages: [String]
}

enum HookMerge {
    /// merge.ts:35-42——deny>ask>allow 优先级的单 hook 决策 rank（高=更严）。
    private static func rank(_ decision: HookDecision?) -> Int {
        switch decision {
        case .deny, .block: return 3
        case .ask: return 2
        case .approve, .allow: return 1
        case nil: return 0
        }
    }

    /// merge.ts:45-52——rank 收敛回合并枚举。
    private static func decisionForRank(_ maxRank: Int) -> MergedDecision {
        switch maxRank {
        case 3: return .deny
        case 2: return .ask
        case 1: return .allow
        default: return .none
        }
    }

    /// merge.ts:62-100——把匹配同一 point 的全部 outputs（按 hook 序）按上述
    /// 优先级折为一个 MergedHookOutcome。空输入=中性 outcome（decision:none/
    /// 无 stop/空数组——调用方视为「没有 hook 有话说」）。
    static func mergeHookOutputs(_ outputs: [HookOutput]) -> MergedHookOutcome {
        var maxRank = 0
        // 按 rank 分桶保留 reasons——只有解释胜出决策的反对意见浮出（:64-77）。
        var reasonsByRank: [Int: [String]] = [:]
        var stop = false
        var stopReason: String?
        var additionalContext: [String] = []
        var systemMessages: [String] = []

        for out in outputs {
            let r = rank(out.decision)
            if r > maxRank { maxRank = r }
            if (r == 3 || r == 2), let reason = out.reason, !reason.isEmpty {
                reasonsByRank[r, default: []].append(reason)
            }
            // 首个 continue:false sticky（:79-82）。
            if out.continue == false, !stop {
                stop = true
                if let reason = out.stopReason { stopReason = reason }
            }
            if let ctx = out.additionalContext, !ctx.isEmpty {
                additionalContext.append(ctx)
            }
            if let sysMsg = out.systemMessage, !sysMsg.isEmpty {
                systemMessages.append(sysMsg)
            }
        }

        let reasons = reasonsByRank[maxRank] ?? []
        return MergedHookOutcome(
            decision: decisionForRank(maxRank),
            reason: reasons.isEmpty ? nil : reasons.joined(separator: "\n\n"),
            stop: stop,
            stopReason: stopReason,
            additionalContext: additionalContext,
            systemMessages: systemMessages)
    }
}

// MARK: - matcher（matcher.ts 全文）

/// 两方言共用的 matcher（纯函数域）。Claude 把纯字母/数字/下划线/pipe 模式视为
/// literal 备选，其余视为 regex；Codex 把一切非空模式视为 unanchored regex。
/// 缺省/空/'*' 全匹配。运行时把无效 regex 收容为非匹配；config 解析器用
/// matcherDiagnostic 在接受配置组前带诊断拒绝。
enum HookMatcher {
    /// matcher.ts:13-15——absent/''/'*' 三哨兵 = 全匹配。
    static func isMatchAll(_ matcher: String?) -> Bool {
        return matcher == nil || matcher == "" || matcher == "*"
    }

    /// matcher.ts:18——Claude-literal 判别式：纯 word 字符 + '|'。
    private static let claudeLiteral = try? NSRegularExpression(
        pattern: "^[A-Za-z0-9_|]+$")

    /// matcher.ts:21-29——编译 unanchored matcher regex；无效模式返回 nil
    /// （构造是 try 的唯一操作，模式语法错是唯一预期失败）。
    private static func compileRegex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    /// matcher.ts:37-44——bridge 接受配置组前校验单个 matcher：全匹配哨兵恒
    /// valid；claude-code literal 恒 valid；其余编译失败 → 稳定诊断串
    /// `invalid ${mode} regex matcher ${JSON.stringify(pattern)}`。
    static func matcherDiagnostic(_ matcher: String?, mode: MatcherMode) -> String? {
        if isMatchAll(matcher) { return nil }
        let pattern = matcher!
        if mode == .claudeCode, isClaudeLiteral(pattern) { return nil }
        return compileRegex(pattern) == nil
            ? "invalid \(mode.rawValue) regex matcher \(jsonQuoted(pattern))"
            : nil
    }

    /// matcher.ts:57-65——matcher 是否选中 query。Claude literal 按精确匹配
    /// pipe 备选；其余为 unanchored regex。无效 regex 返回 false 而非抛出
    /// （bridge config 解析器先经 matcherDiagnostic 浮出）。
    static func matchesMatcher(_ matcher: String?, query: String, mode: MatcherMode) -> Bool {
        if isMatchAll(matcher) { return true }
        let pattern = matcher!
        if mode == .claudeCode, isClaudeLiteral(pattern) {
            // JS String.split("|") 保留空段（omittingEmptySubsequences:false 同义）。
            return pattern.split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init).contains(query)
        }
        // JS 无 flag RegExp.test() = unanchored 存在性判定；NSRegularExpression
        // 默认（无 anchored）firstMatch != nil 同义。无效 regex → false 不抛。
        guard let regex = compileRegex(pattern) else { return false }
        return regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil
    }

    // MARK: 私有工具

    /// matcher.ts:18 判别式的 NSRegularExpression 实现（纯 word+pipe 模式）。
    private static func isClaudeLiteral(_ pattern: String) -> Bool {
        guard let literal = claudeLiteral else { return false }
        let range = NSRange(pattern.startIndex..., in: pattern)
        return literal.firstMatch(in: pattern, range: range) != nil
    }

    /// matcher.ts:42 JSON.stringify(pattern) 的最小等价（加引号；对 hook
    /// matcher 常见的 ASCII 无引号模式与 JS 逐字节等价——含引号/反斜杠模式的
    /// 转义形态差异登记于 E1 呈报③，诊断面非语义面）。
    private static func jsonQuoted(_ pattern: String) -> String {
        let escaped = pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
