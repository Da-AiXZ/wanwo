//
//  HookConfigLoaderTests.swift
//  WanWoTests
//
//  【M4-E 批 E4 测试 · Documents/hooks/ 装配】dsh 两桥 index.ts 装载语义
//  1:1 断言（临时目录 fixture 注入，勿真读沙盒 Documents）：文件不存在
//  静默零注册（桥未安装，不产出 runtime）/ 坏 JSON warn+零 hooks fail open
//  / invalid regex 解析失败同样 warn+零 hooks（整配置拒绝面）/ 合法双文件
//  双桥 runtime 产出（方言轴常量全量断言）/ skipped warn 文案逐字+计数 /
//  projectDir 装配常量解析期替换实测。
//

import XCTest
@testable import WanWo

final class HookConfigLoaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-loader-\(UUID().uuidString)",
                                     isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// 写一份桥配置文件。
    private func writeConfig(_ name: String, _ content: String) throws {
        try Data(content.utf8).write(to: directory.appendingPathComponent(name))
    }

    // MARK: 文件不存在 = 桥未安装（静默零注册）

    func testMissingFilesProduceNoRuntimes() {
        // 拍板项①口径：不存在静默（非错误），不产出 runtime。
        let runtimes = HookConfigLoader(directory: directory).load()
        XCTAssertTrue(runtimes.isEmpty)
    }

    // MARK: 合法双文件双桥 runtime 产出

    func testValidDualFilesProduceBothRuntimes() throws {
        try writeConfig(HookConfigLoader.claudeConfigFileName, """
        {"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"cc.sh"}]}]}
        """)
        try writeConfig(HookConfigLoader.codexConfigFileName, """
        {"Stop":[{"hooks":[{"type":"command","command":"cx.sh"}]}]}
        """)
        let runtimes = HookConfigLoader(directory: directory).load()
        XCTAssertEqual(runtimes.count, 2)

        let claude = try XCTUnwrap(runtimes.first { $0.dialect == .claudeCode })
        XCTAssertEqual(claude.groups["PreToolUse"], [
            MatcherGroup(matcher: "Bash", hooks: [CommandHook(command: "cc.sh")])
        ])
        XCTAssertTrue(claude.warnings.isEmpty)
        XCTAssertEqual(claude.trailingNewline, true)      // E2 方言轴：CC 有尾换行
        XCTAssertEqual(claude.matcherMode, .claudeCode)
        XCTAssertEqual(claude.stderrSummaryMaxChars, 500) // DEFAULT_STDERR_SUMMARY_MAX_CHARS
        XCTAssertEqual(claude.defaultTimeoutMs, 600_000)  // DEFAULT_HOOK_TIMEOUT_MS
        XCTAssertEqual(claude.model, "")

        let codex = try XCTUnwrap(runtimes.first { $0.dialect == .codex })
        XCTAssertEqual(codex.groups["Stop"], [
            MatcherGroup(matcher: nil, hooks: [CommandHook(command: "cx.sh")])
        ])
        XCTAssertTrue(codex.warnings.isEmpty)
        XCTAssertEqual(codex.trailingNewline, false)      // Codex 无尾换行
        XCTAssertEqual(codex.matcherMode, .codex)
        XCTAssertEqual(codex.stderrSummaryMaxChars, 500)
        XCTAssertEqual(codex.defaultTimeoutMs, 600_000)
        XCTAssertEqual(codex.model, "")                   // 常量空串保形
    }

    // MARK: 坏 JSON = warn + 零 hooks（fail open，CC index.ts:113-116 / codex :94-97）

    func testMalformedJSONYieldsWarnAndZeroHooks() throws {
        try writeConfig(HookConfigLoader.claudeConfigFileName, "{not json")
        try writeConfig(HookConfigLoader.codexConfigFileName, "]]]")
        let runtimes = HookConfigLoader(directory: directory).load()
        // 桥保持已安装态（runtime 在场）但零 hooks。
        XCTAssertEqual(runtimes.count, 2)
        for runtime in runtimes {
            XCTAssertTrue(runtime.groups.isEmpty)
            XCTAssertEqual(runtime.warnings.count, 1)
            // index.ts:114/:95 文案形态逐字（桥前缀 + could not load hook config）。
            let prefix = runtime.dialect == .claudeCode
                ? "hooks-claude-code: could not load hook config \""
                : "hooks-codex: could not load hook config \""
            XCTAssertTrue(runtime.warnings[0].hasPrefix(prefix),
                          "warning=\(runtime.warnings[0])")
            XCTAssertTrue(runtime.warnings[0].hasSuffix("— no hooks registered"),
                          "warning=\(runtime.warnings[0])")
        }
    }

    // MARK: invalid regex = 解析期抛错 → warn + 零 hooks（整配置拒绝面）

    func testInvalidRegexConfigYieldsWarnAndZeroHooks() throws {
        // config.ts:112-113 抛 SyntaxError → 桥 catch → 整配置拒绝。
        try writeConfig(HookConfigLoader.claudeConfigFileName, """
        {"PreToolUse":[{"matcher":"(","hooks":[{"type":"command","command":"x.sh"}]}]}
        """)
        let runtimes = HookConfigLoader(directory: directory).load()
        let claude = try XCTUnwrap(runtimes.first { $0.dialect == .claudeCode })
        XCTAssertTrue(claude.groups.isEmpty)
        XCTAssertEqual(claude.warnings.count, 1)
        XCTAssertTrue(try XCTUnwrap(claude.warnings.first)
            .contains("invalid claude-code regex matcher"))
        // 无 codex 文件 → codex 桥未安装，不产出。
        XCTAssertFalse(runtimes.contains { $0.dialect == .codex })
    }

    // MARK: skipped warn 文案逐字 + 计数

    func testSkippedWarningsVerbatimPerBridge() throws {
        try writeConfig(HookConfigLoader.claudeConfigFileName, """
        {"PreToolUse":[{"hooks":[{"type":"prompt","prompt":"hi"},{"type":"command","command":"ok.sh"},{"type":"http","url":"http://x"}]}]}
        """)
        try writeConfig(HookConfigLoader.codexConfigFileName, """
        {"PreToolUse":[{"hooks":[{"type":"prompt"},{"type":"command","command":"sync.sh"},{"type":"command","command":"bg.sh","async":true}]}]}
        """)
        let runtimes = HookConfigLoader(directory: directory).load()
        let claude = try XCTUnwrap(runtimes.first { $0.dialect == .claudeCode })
        // index.ts:111 文案逐字 × 2。
        XCTAssertEqual(claude.warnings, [
            "hooks-claude-code: skipping unsupported \"prompt\" hook on PreToolUse (only command hooks run)",
            "hooks-claude-code: skipping unsupported \"http\" hook on PreToolUse (only command hooks run)",
        ])
        let codex = try XCTUnwrap(runtimes.first { $0.dialect == .codex })
        // index.ts:92 文案逐字 × 2（unsupported + async）。
        XCTAssertEqual(codex.warnings, [
            "hooks-codex: skipping unsupported \"prompt\" hook on PreToolUse (only sync command hooks run)",
            "hooks-codex: skipping async hook on PreToolUse (only sync command hooks run)",
        ])
    }

    // MARK: projectDir 装配常量解析期替换实测

    func testClaudeProjectDirSubstitutedAtLoad() throws {
        try writeConfig(HookConfigLoader.claudeConfigFileName, """
        {"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/check.sh ${CLAUDE_PLUGIN_ROOT}"}]}]}
        """)
        let runtimes = HookConfigLoader(directory: directory).load()
        let claude = try XCTUnwrap(runtimes.first { $0.dialect == .claudeCode })
        // projectDir=/var/wanwo/workspace（WanWoPaths.workspaceLinuxDir 装配
        // 常量）；pluginRoot 不设 → token verbatim 保留。
        XCTAssertEqual(claude.groups["Stop"], [
            MatcherGroup(matcher: nil, hooks: [CommandHook(
                command: "\(HookConfigLoader.projectDir)/check.sh ${CLAUDE_PLUGIN_ROOT}")])
        ])
        XCTAssertEqual(HookConfigLoader.projectDir, "/var/wanwo/workspace")
    }
}
