//
//  HookSessionEvents.swift
//  WanWo
//
//  【M4-E 批 E3 · hook/* 会话事件对端口】出处：dsh hook-protocol events.ts
//  1:1 移植（events.ts 模块注释原文语义）——
//    "Append helpers for durable, log-only hook events. They carry no surface
//     intent and must remain turn-enclosed and invoked/result paired. Mid-turn
//     hook points satisfy that boundary; SessionStart records injected context
//     instead and does not append `hook/*` outside a turn."
//  即：hook/* 事件是持久、log-only 的审计记录，不承载表面意图（不进派生
//  历史/聊天流）；必须回合内（turn-enclosed）且 invoked/result 成对。
//  【SessionStart 例外】SessionStart 挂点不落 hook/* 事件——它把 hook 产出的
//  上下文直接注入（additionalContext 通道），回合结构由 E5 挂点接线保证
//  （mid-turn 挂点天然回合内）；本端口不做 turn 结构校验（SessionInvariant
//  对 extensionEvent 无 turn 约束，回合封闭性是调用方契约）。
//
//  dsh 名 → Swift 名映射（camelCase 驼峰化，语义零漂移）：
//    HookInvocation / HookResultRecord      → 同名 struct
//    DEFAULT_STDERR_SUMMARY_MAX_CHARS       → defaultStderrSummaryMaxChars
//    summarizeStderr / appendHookInvoked /
//    appendHookResult                        → HookSessionEvents 同名静态方法
//
//  与 dsh 的两处已登记差异（均为 Swift 惯用等价映射，语义保真）：
//    ① JS `string.length`（UTF-16 码元）→ Swift `String.count`（字素簇）；
//       ASCII 域（hook stderr 摘要）两者一致，截断边界语义同源。
//    ② dsh session.append 不抛（Node 进程内直接写）；Swift 侧 SessionWriter
//       append 为 async throws（E1 写侧门 + 不变量校验 fail closed），错误
//       上抛由调用方（E5 挂点）按 R5 非阻断语义消化。
//

import Foundation

// MARK: - 方言（dsh types.ts:48）

/// hook 桥方言——决定 payload 尾换行 / 匹配器模式等桥轴（E2 runner 已消费）。
enum HookDialect: String, Equatable, Sendable {
    case claudeCode = "claude-code"
    case codex
}

// MARK: - 事件载荷（dsh events.ts:13-24 / 27-45）

/// 一次 hook 调用的身份——invoked/result 配对的关联锚是 handlerId。
struct HookInvocation: Equatable, Sendable {
    /// 调用所属的开放回合。
    var turn: Int
    /// hook 挂点名（PreToolUse、Stop、…）。
    var point: String
    /// 执行它的桥方言。
    var dialect: HookDialect
    /// 跨 invoked/result 对关联该调用的稳定 id。
    var handlerId: String
    /// 选中它的 matcher-group 模式（match-all 时 nil——payload 省略该键，
    /// events.ts:81 条件展开语义）。
    var matcher: String?
}

/// 配对的「结果半」——由 bridge 传入解码 outcome + 摘要帽 + 墙钟时长；
/// decision/exitCode/stderrSummary 派生逻辑集中在本库（events.ts:31-35 注释：
/// 共享事件语义活在声明它的库里，不散落各桥）。
struct HookResultRecord: Equatable, Sendable {
    var turn: Int
    var point: String
    var handlerId: String
    /// 执行产出的解码 outcome（HookRunner.run 返回值）。
    var output: HookOutput
    /// 派生 stderrSummary 的字符帽——归 bridge 所有（其 stderrSummaryMaxChars
    /// 配置）显式传入；defaultStderrSummaryMaxChars 是参考默认。
    var stderrSummaryMaxChars: Int
    /// 执行墙钟时长（来自 runHook 的 now() 差值）——持久审计计时。
    var durationMs: Int
}

// MARK: - 端口

/// hook/* 会话事件对端口（dsh events.ts 的 Swift 移植；落 E1 扩展事件通道）。
enum HookSessionEvents {
    /// wire kind（E1 通道 wireType = "extension/\(kind)"）。
    static let invokedKind = "hook/invoked"
    /// wire kind（同上）。
    static let resultKind = "hook/result"

    /// dsh events.ts:53 DEFAULT_STDERR_SUMMARY_MAX_CHARS——两桥 config 默认
    /// 同源的参考帽（活在截断规则旁边，防止桥间漂移）。
    static let defaultStderrSummaryMaxChars = 500

    // MARK: 注册（E1 通道 schema；装配期由 AppEnvironment 调用）

    /// 注册 hook/invoked 与 hook/result 两个扩展事件 schema（M4-E 批次报批
    /// 项）。幂等（逐 kind guard，与 AppEnvironment 既有注册先例一致）。
    ///
    /// - hook/invoked：开事件，pairing = answeredBy(closeKind: hook/result,
    ///   keyField: handlerId)——SessionInvariant 登记字符串键；matcher 为
    ///   可选键不入 requiredFields（events.ts:81 absent 省略）；dialect 以
    ///   allowedValues 封闭值域——未知 dialect fail closed 拒绝（写侧门 +
    ///   解码侧同规则）。
    /// - hook/result：close 侧，pairing = .none——经 invoked 的 answeredBy
    ///   规则被消费：close 无 open 即 extensionPairViolation（先关后开序、
    ///   result 必须配对到 invoked，dsh invariant 语义天然成立）；
    ///   decision 派生值域 = HookDecision 五值 + stop/pass 两回退值。
    static func registerEventSchemas() {
        let registry = ExtensionEventRegistry.shared
        if !registry.isRegistered(invokedKind) {
            registry.register(ExtensionEventSchema(
                kind: invokedKind,
                requiredFields: [
                    ExtensionFieldSchema("turn", .int),
                    ExtensionFieldSchema("point", .string),
                    ExtensionFieldSchema(
                        "dialect", .string,
                        allowedValues: [.string(HookDialect.claudeCode.rawValue),
                                        .string(HookDialect.codex.rawValue)]),
                    ExtensionFieldSchema("handlerId", .string),
                ],
                projection: .logOnly,
                pairing: .answeredBy(closeKind: resultKind, keyField: "handlerId")))
        }
        if !registry.isRegistered(resultKind) {
            registry.register(ExtensionEventSchema(
                kind: resultKind,
                requiredFields: [
                    ExtensionFieldSchema("turn", .int),
                    ExtensionFieldSchema("point", .string),
                    ExtensionFieldSchema("handlerId", .string),
                    ExtensionFieldSchema("decision", .string, allowedValues: [
                        .string(HookDecision.approve.rawValue),
                        .string(HookDecision.allow.rawValue),
                        .string(HookDecision.block.rawValue),
                        .string(HookDecision.deny.rawValue),
                        .string(HookDecision.ask.rawValue),
                        .string("stop"),
                        .string("pass"),
                    ]),
                    ExtensionFieldSchema("durationMs", .int),
                ],
                projection: .logOnly,
                pairing: .none))
        }
    }

    // MARK: summarizeStderr（dsh events.ts:64-68）

    /// 把 hook 的 stderr 截为 stderrSummary：trim → 空白即 nil → 超帽截断
    /// 加省略号。帽是参数——如 runHook 的 defaultTimeoutMs，各桥自有 config
    /// 默认并显式传入。
    ///
    /// - Parameters:
    ///   - stderr: hook 捕获的原始 stderr。
    ///   - maxChars: 摘要字符帽（桥的 config 值）。
    /// - Returns: trim 后的截断摘要；stderr 空白时 nil（dsh undefined）。
    static func summarizeStderr(_ stderr: String, maxChars: Int) -> String? {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil } // events.ts:66——空白 → undefined
        // events.ts:67——帽为排他边界（恰 maxChars 原样保留，>maxChars 截断加 …）。
        if trimmed.count > maxChars {
            return String(trimmed.prefix(maxChars)) + "…"
        }
        return trimmed
    }

    // MARK: appendHookInvoked（dsh events.ts:75-83）

    /// 向会话追加一条 hook/invoked 事件（命名 handler 与 hook 挂点）。
    /// matcher 缺席时 payload 省略该键（events.ts:81 条件展开）。
    ///
    /// - Returns: 已落盘事件（seq 供归属面使用；dsh 返回 void，Swift 侧
    ///   惯用 discardable 返回——F040 附件引用归属先例同型）。
    @discardableResult
    static func appendHookInvoked(to writer: SessionWriter,
                                  invocation: HookInvocation) async throws -> SessionEvent {
        var fields: [String: JSONValue] = [
            "turn": .int(invocation.turn),
            "point": .string(invocation.point),
            "dialect": .string(invocation.dialect.rawValue),
            "handlerId": .string(invocation.handlerId),
        ]
        if let matcher = invocation.matcher {
            fields["matcher"] = .string(matcher) // absent → 键省略
        }
        return try await writer.append(
            .extensionEvent(kind: invokedKind, payload: .object(fields)))
    }

    // MARK: appendHookResult（dsh events.ts:92-104）

    /// 追加与 hook/invoked 配对的持久结果。记录的 decision 推导链（events.ts:99）：
    /// `output.decision ?? (output.continue === false ? 'stop' : 'pass')`——
    /// 显式 decision 优先；continue:false 回退 stop；其余 pass。stderr trim
    /// 截帽（summarizeStderr）；进程退出码缺席（hook 未能运行）时省略键。
    ///
    /// - Returns: 已落盘事件（同上 discardable）。
    @discardableResult
    static func appendHookResult(to writer: SessionWriter,
                                 record: HookResultRecord) async throws -> SessionEvent {
        let output = record.output
        let stderrSummary = summarizeStderr(output.stderr,
                                            maxChars: record.stderrSummaryMaxChars)
        // events.ts:99——decision 三分支推导。
        let decision = output.decision?.rawValue
            ?? (output.continue == false ? "stop" : "pass")
        var fields: [String: JSONValue] = [
            "turn": .int(record.turn),
            "point": .string(record.point),
            "handlerId": .string(record.handlerId),
            "decision": .string(decision),
        ]
        if let exitCode = output.exitCode {
            fields["exitCode"] = .int(exitCode) // events.ts:100——缺席省略键
        }
        if let stderrSummary {
            fields["stderrSummary"] = .string(stderrSummary) // events.ts:101
        }
        fields["durationMs"] = .int(record.durationMs) // 恒含（审计计时）
        return try await writer.append(
            .extensionEvent(kind: resultKind, payload: .object(fields)))
    }
}
