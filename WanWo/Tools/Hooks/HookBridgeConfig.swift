//
//  HookBridgeConfig.swift
//  WanWo
//
//  【M4-E 批 E4 · config 双桥解析】出处（逐行亲读，file:line 对拍）：
//    - packages/hooks/hooks-claude-code/src/config.ts 全文 123 行
//    - packages/hooks/hooks-codex/src/config.ts 全文 86 行
//  两桥把各自的 hooks.json（事件→matcher 组→command hooks）解析为共享
//  MatcherGroup 形状；只有 command hooks 运行，其余记录为 skipped 供桥 warn。
//  解析容错（malformed 忽略不炸启动）与「invalid regex 抛错拒绝整配置」
//  两级语义逐行保真。
//
//  方言差异（dsh 有意保持 dialect-local，codex config.ts:52-53 注释原文：
//  "Matcher-group parsing remains dialect-local because the supported hook
//  shapes and skip reasons differ from Claude Code's"——Swift 侧同构双实现）：
//    · CC：${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PROJECT_DIR} 解析期全替换
//      （split-join 全替换，token 未设值 verbatim 保留 :57-62）；skipped
//      形态 {event,type}；无 async 概念。
//    · Codex：零替换（:16-23 spec 原文 "no substitution"）；skipped 形态
//      {event,reason}；async===true → skipped 'async hook'；timeout 或
//      timeoutSec 别名（:70-71）。
//  共同点：type 缺省 'command'；command 非串跳；UserPromptSubmit/Stop 的
//  matcher 字段丢弃（无 matcher 主语）；commands 空的组不入、组空的
//  事件不入 config；matcherDiagnostic 非 nil → 抛 SyntaxError 拒整配置。
//
//  WanWo 支持面（拍板项④）：CC 七常量中支持前五（SessionStart/
//  UserPromptSubmit/PreToolUse/PostToolUse/Stop）；SubagentStart/SubagentStop
//  按不支持事件处理——dsh 循环只遍历支持事件集（config.ts:86/:50），不支持
//  事件的 group 在解析前被忽略（连 invalid regex 也不抛，spec:85-94 实证）。
//
//  JS→Swift 差异登记：
//    · 事件集遍历序 → Dictionary 无序：config 键序不可观察（E5 消费面是
//      per-point 查表 groups[point]，与键序无关）。
//    · JS number → JSONValue .int/.double：timeout 小数秒截断为 Int（runner
//      ×1000 后仍为毫秒整；分数秒现实配置不存在，登记备查）。
//    · SyntaxError → HookConfigSyntaxError（message 形态逐字保真，含
//      jsonQuoted 事件名）。
//

import Foundation

// MARK: - 错误（dsh SyntaxError 等价物）

/// invalid regex matcher 抛出——桥拒绝**整份**配置（零监听注册），message
/// 形态与 dsh 逐字保真：`invalid <mode> regex matcher "…" on event "…"`。
struct HookConfigSyntaxError: Error, Equatable {
    let message: String
}

// MARK: - skipped 形态（两桥各异，dsh 有意不同构）

/// CC 桥 skipped（config.ts:25-28）：事件名 + hook type（warn 文案由
/// HookBridgeWarnings.claudeSkip 逐字生成）。
struct SkippedClaudeHook: Equatable, Sendable {
    let event: String
    let type: String
}

/// Codex 桥 skipped（config.ts:17-20）：事件名 + 跳过理由。
struct SkippedCodexHook: Equatable, Sendable {
    let event: String
    let reason: String
}

// MARK: - 解析产物

/// CC 解析产物（config.ts:31-34）。
struct ParsedClaudeConfig: Equatable, Sendable {
    var config: [String: [MatcherGroup]]
    var skipped: [SkippedClaudeHook]
}

/// Codex 解析产物（config.ts:23-26）。
struct ParsedCodexConfig: Equatable, Sendable {
    var config: [String: [MatcherGroup]]
    var skipped: [SkippedCodexHook]
}

// MARK: - 替换变量（CC config.ts:37-42）

/// 解析期施加到每条 command 的替换变量；token 对应变量未设值时 verbatim
/// 保留（config.ts:59-60 条件替换语义）。
struct SubstitutionVars: Equatable, Sendable {
    /// 替换 `${CLAUDE_PLUGIN_ROOT}`（WanWo 无插件机制 → 不设）。
    var pluginRoot: String?
    /// 替换 `${CLAUDE_PROJECT_DIR}`（WanWo = 会话工作区 guest 视角常量）。
    var projectDir: String?
}

// MARK: - 双桥解析器

enum HookBridgeConfig {
    /// CC 桥支持事件（config.ts:11-19 CLAUDE_EVENTS 七常量的 WanWo 支持面
    /// =前五，拍板项④；SubagentStart/Stop 不入循环=按不支持事件忽略）。
    /// 顺序保真 dsh CLAUDE_EVENTS 前 five。
    static let claudeEvents = ["SessionStart", "UserPromptSubmit",
                               "PreToolUse", "PostToolUse", "Stop"]

    /// Codex 桥五事件（config.ts:11 CODEX_EVENTS，顺序保真）。
    static let codexEvents = ["PreToolUse", "PostToolUse",
                              "SessionStart", "UserPromptSubmit", "Stop"]

    // MARK: substituteCommand（CC config.ts:57-62）

    /// 对 command 串施加 `${CLAUDE_PLUGIN_ROOT}` / `${CLAUDE_PROJECT_DIR}`
    /// 替换——split-join 全替换（replacingOccurrences 全量等价）；token
    /// 对应变量未设值时 verbatim 保留。
    static func substituteCommand(_ command: String, vars: SubstitutionVars) -> String {
        var out = command
        if let pluginRoot = vars.pluginRoot {
            out = out.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot)
        }
        if let projectDir = vars.projectDir {
            out = out.replacingOccurrences(of: "${CLAUDE_PROJECT_DIR}", with: projectDir)
        }
        return out
    }

    // MARK: parseClaudeCodeConfig（CC config.ts:78-123）

    /// 解析 settings `{hooks:…}` 包装或裸事件 map。malformed 条目忽略不炸
    /// 启动；不支持事件在 group 解析前忽略；非 command hooks 记入 skipped；
    /// 替换施加到每条存活 command；UserPromptSubmit/Stop 丢 matcher；带
    /// matcher 的可运行组 invalid regex → 抛 HookConfigSyntaxError（桥据此
    /// 拒整配置、零监听注册）。
    static func parseClaudeCodeConfig(
        _ raw: JSONValue,
        vars: SubstitutionVars = SubstitutionVars()
    ) throws -> ParsedClaudeConfig {
        var config: [String: [MatcherGroup]] = [:]
        var skipped: [SkippedClaudeHook] = []
        // :82-84——{hooks:…}（settings 文件）或裸事件 map 二选一。
        guard let root = asObject(raw) else {
            return ParsedClaudeConfig(config: config, skipped: skipped)
        }
        let hooksMap: [String: JSONValue]
        if let hooksValue = root["hooks"], let wrapped = asObject(hooksValue) {
            hooksMap = wrapped
        } else {
            hooksMap = root
        }

        for event in claudeEvents {
            // :87-88——值非数组的支持事件直接跳过。
            guard let rawGroupsValue = hooksMap[event],
                  case .array(let rawGroups) = rawGroupsValue else { continue }
            var groups: [MatcherGroup] = []
            for rawGroup in rawGroups {
                // :91-92——非 object 组 / hooks 非数组跳。
                guard let group = asObject(rawGroup),
                      let hooksValue = group["hooks"],
                      case .array(let rawHooks) = hooksValue else { continue }
                var commands: [CommandHook] = []
                for rawHook in rawHooks {
                    // :95-96——非 object hook 跳。
                    guard let hook = asObject(rawHook) else { continue }
                    // :97——type 缺省 'command'（非串/缺/null 同）。
                    let type = asString(hook["type"]) ?? "command"
                    if type != "command" {
                        // :98-101——非 command → skipped {event,type}。
                        skipped.append(SkippedClaudeHook(event: event, type: type))
                        continue
                    }
                    // :102——command 非串跳。
                    guard let command = asString(hook["command"]) else { continue }
                    // :105——timeout number → timeoutSec（缺省省略键）。
                    let timeoutSec = numberInt(hook["timeout"])
                    // :104——替换施加到每条存活 command。
                    commands.append(CommandHook(
                        command: substituteCommand(command, vars: vars),
                        timeoutSec: timeoutSec))
                }
                // :108——commands 空的组不入。
                if commands.isEmpty { continue }
                // :109-111——UserPromptSubmit/Stop 丢 matcher（无 matcher 主语）。
                let matcher: String?
                if event == "UserPromptSubmit" || event == "Stop" {
                    matcher = nil
                } else {
                    matcher = asString(group["matcher"])
                }
                // :112-113——invalid regex 抛错拒整配置。
                if let diagnostic = HookMatcher.matcherDiagnostic(matcher, mode: .claudeCode) {
                    throw HookConfigSyntaxError(
                        message: "\(diagnostic) on event \(jsonQuoted(event))")
                }
                // :114-117——matcher 缺省 = match-all（nil）。
                groups.append(MatcherGroup(matcher: matcher, hooks: commands))
            }
            // :119——组空的事件不入 config。
            if !groups.isEmpty { config[event] = groups }
        }
        return ParsedClaudeConfig(config: config, skipped: skipped)
    }

    // MARK: parseCodexConfig（Codex config.ts:43-86）

    /// 解析包装或裸 Codex 事件 map。未知事件与 malformed 条目忽略不炸启动；
    /// 非 command / async:true hooks 记入 skipped；零替换（Codex 语义：shell
    /// 展开延后）；UserPromptSubmit/Stop 丢 matcher；invalid regex 抛错拒
    /// 整配置。
    static func parseCodexConfig(_ raw: JSONValue) throws -> ParsedCodexConfig {
        var config: [String: [MatcherGroup]] = [:]
        var skipped: [SkippedCodexHook] = []
        // :46-48——{hooks:…} 包装或裸事件 map。
        guard let root = asObject(raw) else {
            return ParsedCodexConfig(config: config, skipped: skipped)
        }
        let hooksMap: [String: JSONValue]
        if let hooksValue = root["hooks"], let wrapped = asObject(hooksValue) {
            hooksMap = wrapped
        } else {
            hooksMap = root
        }

        for event in codexEvents {
            guard let rawGroupsValue = hooksMap[event],
                  case .array(let rawGroups) = rawGroupsValue else { continue }
            var groups: [MatcherGroup] = []
            for rawGroup in rawGroups {
                guard let group = asObject(rawGroup),
                      let hooksValue = group["hooks"],
                      case .array(let rawHooks) = hooksValue else { continue }
                var commands: [CommandHook] = []
                for rawHook in rawHooks {
                    guard let hook = asObject(rawHook) else { continue }
                    // :64-65——type 缺省 'command'；非 command → skipped
                    // reason=`unsupported "<type>" hook`。
                    let type = asString(hook["type"]) ?? "command"
                    if type != "command" {
                        skipped.append(SkippedCodexHook(
                            event: event, reason: "unsupported \"\(type)\" hook"))
                        continue
                    }
                    // :67——async === true → skipped 'async hook'（严格 ===）。
                    if case .bool(true) = hook["async"] {
                        skipped.append(SkippedCodexHook(event: event, reason: "async hook"))
                        continue
                    }
                    // :68——command 非串跳。
                    guard let command = asString(hook["command"]) else { continue }
                    // :70-71——timeout 或 timeoutSec 别名（首个 number 胜出）。
                    let timeoutSec = numberInt(hook["timeout"])
                        ?? numberInt(hook["timeoutSec"])
                    // :72——零替换（Codex 无 config 期替换）。
                    commands.append(CommandHook(command: command, timeoutSec: timeoutSec))
                }
                if commands.isEmpty { continue }
                // :75-77——UserPromptSubmit/Stop 丢 matcher。
                let matcher: String?
                if event == "UserPromptSubmit" || event == "Stop" {
                    matcher = nil
                } else {
                    matcher = asString(group["matcher"])
                }
                // :78-79——invalid regex 抛错拒整配置。
                if let diagnostic = HookMatcher.matcherDiagnostic(matcher, mode: .codex) {
                    throw HookConfigSyntaxError(
                        message: "\(diagnostic) on event \(jsonQuoted(event))")
                }
                groups.append(MatcherGroup(matcher: matcher, hooks: commands))
            }
            if !groups.isEmpty { config[event] = groups }
        }
        return ParsedCodexConfig(config: config, skipped: skipped)
    }

    // MARK: - 私有取值助手（dsh asObject/asArray/asString/number 语义）

    /// config.ts:45-49 asObject——object（非 null 非数组）才成立。
    private static func asObject(_ value: JSONValue) -> [String: JSONValue]? {
        if case .object(let dict) = value { return dict }
        return nil
    }

    private static func asString(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value { return s }
        return nil
    }

    /// JS `typeof x === 'number'`——JSONValue .int/.double 同为 number；
    /// 小数秒截断为 Int（差异登记见文件头）。
    private static func numberInt(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    /// 事件名的 JSON.stringify 等价（事件集为常量标识符，无转义字符；
    /// 引号包裹即逐字等价——与 HookMatcher.jsonQuoted 同形）。
    private static func jsonQuoted(_ event: String) -> String {
        "\"\(event)\""
    }
}
