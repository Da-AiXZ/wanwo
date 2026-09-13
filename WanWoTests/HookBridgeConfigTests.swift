//
//  HookBridgeConfigTests.swift
//  WanWoTests
//
//  【M4-E 批 E4 测试 · config 双桥解析移植】dsh 两桥 tests/config.spec.ts
//  用例一比一移植 + WanWo 拍板项④显式锚定（SubagentStart/Stop 按不支持
//  事件忽略）：包装/裸 map 同构 / 非 command skip / async skip / timeout
//  别名 / matcher 丢弃 / invalid regex 拒整配置 / 变量替换（设值全替换+
//  未设 verbatim）/ 空组空事件不入 / malformed 忽略 / 顶层非 object 空。
//

import XCTest
@testable import WanWo

final class HookBridgeConfigTests: XCTestCase {

    // MARK: - substituteCommand（CC config.spec.ts:4-13）

    func testSubstituteCommandReplacesAllOccurrences() {
        XCTAssertEqual(HookBridgeConfig.substituteCommand(
            "${CLAUDE_PLUGIN_ROOT}/x.sh",
            vars: SubstitutionVars(pluginRoot: "/p")), "/p/x.sh")
        XCTAssertEqual(HookBridgeConfig.substituteCommand(
            "${CLAUDE_PROJECT_DIR}/a ${CLAUDE_PROJECT_DIR}/b",
            vars: SubstitutionVars(projectDir: "/proj")), "/proj/a /proj/b")
        XCTAssertEqual(HookBridgeConfig.substituteCommand(
            "${CLAUDE_PLUGIN_ROOT}-${CLAUDE_PROJECT_DIR}",
            vars: SubstitutionVars(pluginRoot: "/p", projectDir: "/d")), "/p-/d")
    }

    func testSubstituteCommandUntouchedWhenVarsUnset() {
        // token 未设值 verbatim 保留（config.ts:59-60 条件替换）。
        XCTAssertEqual(HookBridgeConfig.substituteCommand(
            "${CLAUDE_PLUGIN_ROOT}/x", vars: SubstitutionVars()),
            "${CLAUDE_PLUGIN_ROOT}/x")
    }

    // MARK: - parseClaudeCodeConfig（CC config.spec.ts:15-95）

    func testClaudeBareMapAndSettingsWrapperIdentical() throws {
        let groups: JSONValue = .object([
            "PreToolUse": .array([.object([
                "matcher": .string("Bash"),
                "hooks": .array([.object(["type": .string("command"),
                                          "command": .string("x.sh")])]),
            ])]),
        ])
        let bare = try HookBridgeConfig.parseClaudeCodeConfig(groups)
        let wrapped = try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["hooks": groups]))
        XCTAssertEqual(bare.config, wrapped.config)
        // spec:21 全形态对拍（type 键被剥——CommandHook 形状）。
        XCTAssertEqual(bare.config["PreToolUse"], [
            MatcherGroup(matcher: "Bash",
                         hooks: [CommandHook(command: "x.sh")]),
        ])
    }

    func testClaudeCarriesTimeoutAndSubstitutes() throws {
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["Stop": .array([.object([
                "hooks": .array([.object([
                    "type": .string("command"),
                    "command": .string("${CLAUDE_PLUGIN_ROOT}/s.sh"),
                    "timeout": .int(30),
                ])])]),
            ])]]),
            vars: SubstitutionVars(pluginRoot: "/p"))
        XCTAssertEqual(parsed.config["Stop"], [
            MatcherGroup(matcher: nil,
                         hooks: [CommandHook(command: "/p/s.sh", timeoutSec: 30)]),
        ])
    }

    func testClaudeSkipsNonCommandHooksRecorded() throws {
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["PreToolUse": .array([.object([
                "hooks": .array([
                    .object(["type": .string("prompt"), "prompt": .string("hi")]),
                    .object(["type": .string("command"), "command": .string("ok.sh")]),
                    .object(["type": .string("http"), "url": .string("http://x")]),
                ]),
            ])])]))
        XCTAssertEqual(parsed.config["PreToolUse"], [
            MatcherGroup(matcher: nil, hooks: [CommandHook(command: "ok.sh")])
        ])
        // spec:41——skip 记录 {event,type}，命令型同组保留。
        XCTAssertEqual(parsed.skipped, [
            SkippedClaudeHook(event: "PreToolUse", type: "prompt"),
            SkippedClaudeHook(event: "PreToolUse", type: "http"),
        ])
    }

    func testClaudeMissingTypeDefaultsToCommand() throws {
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["Stop": .array([.object([
                "hooks": .array([.object(["command": .string("d.sh")])]),
            ])])]))
        XCTAssertEqual(parsed.config["Stop"], [
            MatcherGroup(matcher: nil, hooks: [CommandHook(command: "d.sh")])
        ])
    }

    func testClaudeDropsMalformedEntries() throws {
        // spec:49-54——非数组组/非 object 组或 hook/缺 command/空组全静默丢弃。
        XCTAssertEqual(try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["PreToolUse": .string("nope")])).config, [:])
        XCTAssertEqual(try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["PreToolUse": .array([
                .int(42),
                .object(["hooks": .string("no")]),
                .object(["hooks": .array([
                    .int(7),
                    .object(["type": .string("command")]),
                ])]),
            ])])).config, [:])
        // 唯一 hook 缺 command 串 → 整组（空）丢弃。
        XCTAssertEqual(try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["Stop": .array([.object([
                "hooks": .array([.object(["type": .string("command"),
                                          "command": .int(5)])]),
            ])])])).config, [:])
    }

    func testClaudeNonObjectTopLevelReturnsEmpty() throws {
        XCTAssertEqual(try HookBridgeConfig.parseClaudeCodeConfig(.null).config, [:])
        XCTAssertEqual(try HookBridgeConfig.parseClaudeCodeConfig(.int(42)).config, [:])
        XCTAssertEqual(try HookBridgeConfig.parseClaudeCodeConfig(
            .array([.int(1), .int(2)])).config, [:])
    }

    func testClaudeOmitsMatcherKeyWhenMatchAll() throws {
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["Stop": .array([.object([
                "hooks": .array([.object(["type": .string("command"),
                                          "command": .string("s.sh")])]),
            ])])]))
        // spec:64——match-all 组 matcher 键缺席（nil）。
        XCTAssertNil(try XCTUnwrap(parsed.config["Stop"]?.first).matcher)
    }

    func testClaudeRejectsInvalidRegexMatcherWithEventName() {
        XCTAssertThrowsError(try HookBridgeConfig.parseClaudeCodeConfig(
            .object(["PreToolUse": .array([.object([
                "matcher": .string("("),
                "hooks": .array([.object(["type": .string("command"),
                                          "command": .string("x.sh")])]),
            ])])]))) { error in
            // spec:70——message 逐字（diagnostic + on event "PreToolUse"）。
            XCTAssertEqual(error as? HookConfigSyntaxError, HookConfigSyntaxError(
                message: "invalid claude-code regex matcher \"(\" on event \"PreToolUse\""))
        }
    }

    func testClaudeDiscardsMatcherOnMatcherlessEventsBeforeValidation() throws {
        // spec:73-83——UserPromptSubmit/Stop 的 matcher（含 invalid）先丢后验，
        // 不抛且不出现在产物。
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object([
                "UserPromptSubmit": .array([.object([
                    "matcher": .string("["),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("prompt.sh")])]),
                ])]),
                "Stop": .array([.object([
                    "matcher": .string("("),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("stop.sh")])]),
                ])]),
            ]))
        XCTAssertEqual(parsed.config, [
            "UserPromptSubmit": [MatcherGroup(
                matcher: nil, hooks: [CommandHook(command: "prompt.sh")])],
            "Stop": [MatcherGroup(
                matcher: nil, hooks: [CommandHook(command: "stop.sh")])],
        ])
    }

    func testClaudeIgnoresInvalidMatchersOnUnsupportedEvents() throws {
        // spec:85-94——不支持事件（Setup）连 invalid matcher 也不抛，
        // 支持事件的合法 hook 照常保留。
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object([
                "Setup": .array([.object([
                    "matcher": .string("("),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("ignored.sh")])]),
                ])]),
                "PreToolUse": .array([.object([
                    "matcher": .string("Bash"),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("kept.sh")])]),
                ])]),
            ]))
        XCTAssertEqual(parsed.config, [
            "PreToolUse": [MatcherGroup(
                matcher: "Bash", hooks: [CommandHook(command: "kept.sh")])],
        ])
    }

    func testClaudeSubagentEventsTreatedAsUnsupported() throws {
        // 拍板项④显式锚定：CC 七常量中 SubagentStart/SubagentStop 不在
        // WanWo 支持面（config.ts:86 循环只遍历支持事件集）——按不支持
        // 事件忽略（组解析前，连 invalid matcher 也不抛）。
        let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
            .object([
                "SubagentStart": .array([.object([
                    "matcher": .string("("),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("sub.sh")])]),
                ])]),
                "SubagentStop": .array([.object([
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("sub-stop.sh")])]),
                ])]),
            ]))
        XCTAssertEqual(parsed.config, [:])
        XCTAssertTrue(parsed.skipped.isEmpty)
        // 支持面五事件常量集断言（Subagent* 不在内）。
        XCTAssertEqual(HookBridgeConfig.claudeEvents,
                       ["SessionStart", "UserPromptSubmit",
                        "PreToolUse", "PostToolUse", "Stop"])
    }

    // MARK: - parseCodexConfig（Codex config.spec.ts:3-86）

    func testCodexHonorsOnlyFiveSupportedEvents() throws {
        let parsed = try HookBridgeConfig.parseCodexConfig(
            .object([
                "PreToolUse": .array([.object([
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("a.sh")])]),
                ])]),
                "SubagentStop": .array([.object([   // Codex 现行事件，本桥不支持
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("b.sh")])]),
                ])]),
                "Notification": .array([.object([   // Codex 未知事件
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("c.sh")])]),
                ])]),
            ]))
        // spec:11——只有 PreToolUse 入 config。
        XCTAssertEqual(Set(parsed.config.keys), ["PreToolUse"])
        // CODEX_EVENTS 常量集断言（spec:12-13）。
        XCTAssertEqual(HookBridgeConfig.codexEvents,
                       ["PreToolUse", "PostToolUse",
                        "SessionStart", "UserPromptSubmit", "Stop"])
    }

    func testCodexAcceptsTimeoutAndAliasNoSubstitution() throws {
        let parsed = try HookBridgeConfig.parseCodexConfig(
            .object([
                "Stop": .array([.object([
                    "hooks": .array([.object([
                        "type": .string("command"),
                        "command": .string("${NOT_SUBSTITUTED}/s.sh"),
                        "timeout": .int(10),
                    ])]),
                ])]),
                "UserPromptSubmit": .array([.object([
                    "hooks": .array([.object([
                        "type": .string("command"),
                        "command": .string("u.sh"),
                        "timeoutSec": .int(20),
                    ])]),
                ])]),
            ]))
        // spec:22-23——零替换 + 两别名同收。
        XCTAssertEqual(parsed.config["Stop"], [
            MatcherGroup(matcher: nil, hooks: [
                CommandHook(command: "${NOT_SUBSTITUTED}/s.sh", timeoutSec: 10)])
        ])
        XCTAssertEqual(parsed.config["UserPromptSubmit"], [
            MatcherGroup(matcher: nil, hooks: [
                CommandHook(command: "u.sh", timeoutSec: 20)])
        ])
    }

    func testCodexSkipsNonCommandAndAsyncHooks() throws {
        let parsed = try HookBridgeConfig.parseCodexConfig(
            .object(["PreToolUse": .array([.object([
                "hooks": .array([
                    .object(["type": .string("prompt")]),
                    .object(["type": .string("command"), "command": .string("sync.sh")]),
                    .object(["type": .string("command"), "command": .string("bg.sh"),
                             "async": .bool(true)]),
                ]),
            ])])]))
        XCTAssertEqual(parsed.config["PreToolUse"], [
            MatcherGroup(matcher: nil, hooks: [CommandHook(command: "sync.sh")])
        ])
        // spec:35——reason 文案逐字（unsupported "…" / async hook）。
        XCTAssertEqual(parsed.skipped, [
            SkippedCodexHook(event: "PreToolUse", reason: "unsupported \"prompt\" hook"),
            SkippedCodexHook(event: "PreToolUse", reason: "async hook"),
        ])
    }

    func testCodexWrapperAndBareMapIdentical() throws {
        let groups: JSONValue = .object(["Stop": .array([.object([
            "hooks": .array([.object(["type": .string("command"),
                                      "command": .string("s.sh")])]),
        ])])])
        let bare = try HookBridgeConfig.parseCodexConfig(groups)
        let wrapped = try HookBridgeConfig.parseCodexConfig(.object(["hooks": groups]))
        XCTAssertEqual(bare.config, wrapped.config)
    }

    func testCodexDropsMalformedAndNonObjectTopLevel() throws {
        // spec:43-47。
        XCTAssertEqual(try HookBridgeConfig.parseCodexConfig(.null).config, [:])
        XCTAssertEqual(try HookBridgeConfig.parseCodexConfig(
            .object(["PreToolUse": .string("no")])).config, [:])
        XCTAssertEqual(try HookBridgeConfig.parseCodexConfig(
            .object(["Stop": .array([
                .int(7),
                .object(["hooks": .string("x")]),
                .object(["hooks": .array([.object(["type": .string("command"),
                                                   "command": .int(9)])])]),
            ])])).config, [:])
    }

    func testCodexSkipsNonObjectHookElementKeepingSibling() throws {
        // spec:49-52——hooks 数组内的非 object 元素跳，合法兄弟保留。
        let parsed = try HookBridgeConfig.parseCodexConfig(
            .object(["Stop": .array([.object([
                "hooks": .array([
                    .null,
                    .int(7),
                    .object(["type": .string("command"), "command": .string("s.sh")]),
                ]),
            ])])]))
        XCTAssertEqual(parsed.config["Stop"], [
            MatcherGroup(matcher: nil, hooks: [CommandHook(command: "s.sh")])
        ])
    }

    func testCodexMissingTypeDefaultsToCommandAndMatcherAxes() throws {
        // spec:54-67——无 type 即 command；match-all 省键；有 matcher 保留。
        let matchAll = try HookBridgeConfig.parseCodexConfig(
            .object(["Stop": .array([.object([
                "hooks": .array([.object(["command": .string("s.sh")])]),
            ])])]))
        XCTAssertNil(try XCTUnwrap(matchAll.config["Stop"]?.first).matcher)

        let withMatcher = try HookBridgeConfig.parseCodexConfig(
            .object(["PreToolUse": .array([.object([
                "matcher": .string("^Bash$"),
                "hooks": .array([.object(["type": .string("command"),
                                          "command": .string("b.sh")])]),
            ])])]))
        XCTAssertEqual(try XCTUnwrap(withMatcher.config["PreToolUse"]?.first).matcher,
                       "^Bash$")
    }

    func testCodexRejectsInvalidRegexMatcherWithEventName() {
        XCTAssertThrowsError(try HookBridgeConfig.parseCodexConfig(
            .object(["PreToolUse": .array([.object([
                "matcher": .string("["),
                "hooks": .array([.object(["type": .string("command"),
                                          "command": .string("s.sh")])]),
            ])])]))) { error in
            // spec:72——message 逐字。
            XCTAssertEqual(error as? HookConfigSyntaxError, HookConfigSyntaxError(
                message: "invalid codex regex matcher \"[\" on event \"PreToolUse\""))
        }
    }

    func testCodexDiscardsMatcherOnMatcherlessEventsBeforeValidation() throws {
        // spec:75-85。
        let parsed = try HookBridgeConfig.parseCodexConfig(
            .object([
                "UserPromptSubmit": .array([.object([
                    "matcher": .string("["),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("prompt.sh")])]),
                ])]),
                "Stop": .array([.object([
                    "matcher": .string("("),
                    "hooks": .array([.object(["type": .string("command"),
                                              "command": .string("stop.sh")])]),
                ])]),
            ]))
        XCTAssertEqual(parsed.config, [
            "UserPromptSubmit": [MatcherGroup(
                matcher: nil, hooks: [CommandHook(command: "prompt.sh")])],
            "Stop": [MatcherGroup(
                matcher: nil, hooks: [CommandHook(command: "stop.sh")])],
        ])
    }
}
