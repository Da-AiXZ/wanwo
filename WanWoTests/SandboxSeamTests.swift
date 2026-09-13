//
//  SandboxSeamTests.swift
//  WanWoTests
//
//  【M5-B 批 S1 测试 · 沙箱执行缝（词汇 + provider + 匹配函数）】
//    1. ConfinedCommand 形态 + enforcement 两值词汇
//    2. LocalSandboxProvider confine：policy 载体透传 / enforcement 判定
//       （confined=partial、danger=full）/ 拒绝方言与证据规则数据源锚点 /
//       SANDBOX_UNAVAILABLE 文案逐字
//    3. 匹配函数（helpers.ts 移植面）：matchesSignature 大小写不敏感子串 /
//       classifyRunnerFailure（fatal 命中/allowedExitCodes 门/informational
//       全行剥除/空白签名忽略/\r\n 切分）——对拍 pwsh-sandbox 与
//       bash-sandbox 既有 spec 用例形态
//  消费面接线（ShellTool/执行链）S2 批次内部件——本件只立缝，行为零变化。
//

import XCTest
@testable import WanWo

final class SandboxSeamTests: XCTestCase {

    private func makePolicy(mode: SandboxMode,
                            sessionId: String? = "s1") -> SandboxExecutionPolicy {
        SandboxExecutionPolicy(mode: mode,
                               workspaceRoot: SandboxPolicy.workspaceRoot,
                               sessionId: sessionId)
    }

    // MARK: 1. 词汇形态

    func testEnforcementVocabulary() {
        // dsh :58-62 两值闭集。
        XCTAssertEqual(Set(SandboxEnforcement.allCases),
                       [.full, .partial])
        XCTAssertEqual(SandboxEnforcement.full.rawValue, "full")
        XCTAssertEqual(SandboxEnforcement.partial.rawValue, "partial")
    }

    func testConfinedCommandShape() {
        let rule = RunnerFailureRule(allowedExitCodes: [127],
                                     fatalSignatures: ["runner: "],
                                     informationalLines: ["runner: partial enforcement"])
        let confined = ConfinedCommand(command: "echo hi", enforcement: .partial,
                                       denialSignatures: ["permission denied"],
                                       runnerFailureRules: [rule])
        XCTAssertEqual(confined.command, "echo hi")
        XCTAssertEqual(confined.enforcement, .partial)
        XCTAssertEqual(confined.runnerFailureRules.first?.allowedExitCodes, [127])
        // RunnerFailureRule 缺省语义：nil 门 = 任何非零退出均可（dsh :82-83）。
        let openRule = RunnerFailureRule(fatalSignatures: ["x"])
        XCTAssertNil(openRule.allowedExitCodes)
        XCTAssertNil(openRule.informationalLines)
    }

    // MARK: 2. LocalSandboxProvider confine

    func testConfinePassesPolicyAndCommandThrough() throws {
        let provider = LocalSandboxProvider()
        // 命令行原样透传（iSH 无进程级 wrapper——围栏在 gate/fakefs 层）。
        let confined = try provider.confine(
            policy: makePolicy(mode: .readOnly), command: "ls -la /var/wanwo/workspace")
        XCTAssertEqual(confined.command, "ls -la /var/wanwo/workspace")
        // per-call 载体语义由 provider 不持状态承载：两次调用互不污染。
        let a = try provider.confine(policy: makePolicy(mode: .readOnly,
                                                        sessionId: "s1"),
                                     command: "echo a")
        let b = try provider.confine(policy: makePolicy(mode: .workspaceWrite,
                                                        sessionId: "s2"),
                                     command: "echo b")
        XCTAssertEqual(a.command, "echo a")
        XCTAssertEqual(b.command, "echo b")
        XCTAssertEqual(b.enforcement, .partial)
    }

    func testConfineEnforcementJudgment() throws {
        let provider = LocalSandboxProvider()
        // confined 模式 = partial（头注论证：启发式近似不满足 absolute boundary）。
        XCTAssertEqual(try provider.confine(
            policy: makePolicy(mode: .readOnly), command: "ls").enforcement, .partial)
        XCTAssertEqual(try provider.confine(
            policy: makePolicy(mode: .workspaceWrite), command: "ls").enforcement, .partial)
        // danger-full-access = full（承诺=无限制，透传即完整兑现）+ 空方言。
        let danger = try provider.confine(
            policy: makePolicy(mode: .dangerFullAccess), command: "ls")
        XCTAssertEqual(danger.enforcement, .full)
        XCTAssertTrue(danger.denialSignatures.isEmpty)
        XCTAssertTrue(danger.runnerFailureRules.isEmpty)
    }

    func testDenialDialectDataSources() {
        // 方言 = 本后端产出的拒绝文案，恰两源（并集纪律：通用 errno 不入表）。
        let dialect = LocalSandboxProvider.denialSignatures
        XCTAssertEqual(dialect.count, 2)
        // 源①：WorkspaceFileAccess.WorkspaceError.pathOutsideRoot（:351）。
        XCTAssertTrue(dialect.contains("path escapes the session workspace root: "))
        // 源②：sandboxDenialMarker 前缀（SandboxEscalation.swift:55）。
        XCTAssertTrue(dialect.contains("[sandbox: file access denied under "))
        // 方言与 marker 实际产物一致（模式内插不破前缀匹配）。
        for mode in SandboxMode.all {
            XCTAssertTrue(
                sandboxDenialMarker(mode).hasPrefix("[sandbox: file access denied under "),
                "方言签名须匹配 marker 实际输出（\(mode.rawValue)）")
        }
    }

    func testRunnerFailureRulesDataSources() {
        // 证据规则 = iSH 执行链 spawn 前失败面 errorDescription 原文
        // （IshExecutorBridge.swift:154-160）。
        let rules = LocalSandboxProvider.runnerFailureRules
        XCTAssertEqual(rules.count, 1)
        let signatures = rules[0].fatalSignatures
        XCTAssertTrue(signatures.contains("iSH kernel is not booted"))
        XCTAssertTrue(signatures.contains("Failed to spawn long-lived process"))
        // 与 ISHCoordinatorError 实际文案对拍（锚点防漂移）。
        XCTAssertEqual(ISHCoordinatorError.kernelNotBooted.errorDescription,
                       "iSH kernel is not booted")
        XCTAssertEqual(ISHCoordinatorError.spawnFailed.errorDescription,
                       "Failed to spawn long-lived process")
        XCTAssertNil(rules[0].allowedExitCodes, "WanWo runner 失败非退出码驱动")
    }

    func testSandboxUnavailableErrorVerbatim() {
        // dsh :131-144 文案逐字（无 detail 后缀）。
        let error = SandboxUnavailableError(mode: .workspaceWrite)
        XCTAssertEqual(SandboxUnavailableError.code, "SANDBOX_UNAVAILABLE")
        XCTAssertTrue(error.message.contains(
            "sandbox mode \"workspace-write\" is requested but no sandbox backend is usable on this host; "
                + "refusing to run the command unconfined."), error.message)
        XCTAssertTrue(error.message.contains(
            "otherwise switch the consumer to danger-full-access."), error.message)
        XCTAssertFalse(error.message.contains("Runner failure:"))
        // detail 后缀形态。
        let withDetail = SandboxUnavailableError(mode: .readOnly, detail: "probe failed")
        XCTAssertTrue(withDetail.message.hasSuffix(" Runner failure: probe failed"))
    }

    // MARK: 3. 匹配函数（helpers.ts 移植面）

    func testMatchesSignature() {
        // 非零退出 + 大小写不敏感子串。
        XCTAssertTrue(SandboxSeamMatcher.matchesSignature(
            exitCode: 1, stderr: "EROFS: READ-ONLY FILE SYSTEM",
            signatures: ["read-only file system"]))
        XCTAssertFalse(SandboxSeamMatcher.matchesSignature(
            exitCode: 1, stderr: "all good", signatures: ["read-only file system"]))
        // 退出码 0 / 信号终止（nil）永不匹配（helpers.ts:113 守卫）。
        XCTAssertFalse(SandboxSeamMatcher.matchesSignature(
            exitCode: 0, stderr: "read-only file system", signatures: ["read-only file system"]))
        XCTAssertFalse(SandboxSeamMatcher.matchesSignature(
            exitCode: nil, stderr: "read-only file system", signatures: ["read-only file system"]))
    }

    func testClassifyDenialDelegatesToMatchesSignature() {
        let dialect = LocalSandboxProvider.denialSignatures
        // 命中本后端方言。
        XCTAssertTrue(SandboxSeamMatcher.classifyDenial(
            exitCode: 1, stderr: "write failed: path escapes the session workspace root: /etc/x",
            signatures: dialect))
        // 退出码 0 不算拒绝（围栏生效且命令成功的形态不存在）。
        XCTAssertFalse(SandboxSeamMatcher.classifyDenial(
            exitCode: 0, stderr: "path escapes the session workspace root: /etc/x",
            signatures: dialect))
    }

    func testClassifyRunnerFailureFatalHit() {
        let rules = [RunnerFailureRule(fatalSignatures: ["fake-runner: "])]
        // pwsh-sandbox spec :118 形态：fatal 行命中返回原始行。
        let match = SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 1, stderr: "starting...\nfake-runner: something bad\n", rules: rules)
        XCTAssertEqual(match?.detail, "fake-runner: something bad")
        // 退出 0 / nil → 永不判定 runner 失败（仅退出码永不证明——:79 注释）。
        XCTAssertNil(SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 0, stderr: "fake-runner: x", rules: rules))
        XCTAssertNil(SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: nil, stderr: "fake-runner: x", rules: rules))
        // 无命中 → nil。
        XCTAssertNil(SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 1, stderr: "ordinary command error", rules: rules))
    }

    func testClassifyRunnerFailureAllowedExitCodesGate() {
        // bash-sandbox spec :463 / windows-acl :136 形态：退出码门外
        // 的规则整条跳过。
        let rules = [RunnerFailureRule(allowedExitCodes: [125],
                                       fatalSignatures: ["landlock-run: "])]
        XCTAssertNil(SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 127, stderr: "landlock-run: boom", rules: rules),
            "退出码门外不匹配")
        XCTAssertEqual(
            SandboxSeamMatcher.classifyRunnerFailure(
                exitCode: 125, stderr: "landlock-run: boom", rules: rules)?.detail,
            "landlock-run: boom")
    }

    func testClassifyRunnerFailureInformationalExclusion() {
        // pwsh-sandbox spec :118-119 / bash-sandbox spec :473-474 形态：
        // informational 全行等值剥除（大小写不敏感）后 fatal 才判。
        let rules = [RunnerFailureRule(
            fatalSignatures: ["fake-runner: "],
            informationalLines: ["fake-runner: partial enforcement"])]
        // 全行等值（大小写不敏感）→ 剥除。
        XCTAssertNil(SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 1, stderr: "FAKE-RUNNER: partial enforcement", rules: rules))
        // 仅子串包含不算全行等值 → 不剥除，fatal 照判。
        XCTAssertEqual(
            SandboxSeamMatcher.classifyRunnerFailure(
                exitCode: 1,
                stderr: "prefix fake-runner: partial enforcement suffix",
                rules: rules)?.detail,
            "prefix fake-runner: partial enforcement suffix")
    }

    func testClassifyRunnerFailureIgnoresBlankSignatures() {
        // pwsh-sandbox spec :132 / bash-sandbox spec :463 形态：空串与纯空白
        // 子串忽略，同规则内其余合法签名保持活跃。
        let blankOnly = [RunnerFailureRule(fatalSignatures: ["", "  ", "\t"])]
        XCTAssertNil(SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 127, stderr: "fake-runner: x", rules: blankOnly))
        let mixed = [RunnerFailureRule(fatalSignatures: ["", " ", "fake-runner:"])]
        XCTAssertEqual(
            SandboxSeamMatcher.classifyRunnerFailure(
                exitCode: 127, stderr: "fake-runner: x", rules: mixed)?.detail,
            "fake-runner: x")
    }

    func testClassifyRunnerFailureCrlfSplitting() {
        // \r\n 折一切分（dsh split(/\r?\n/)）。
        let rules = [RunnerFailureRule(fatalSignatures: ["fake-runner: "])]
        let match = SandboxSeamMatcher.classifyRunnerFailure(
            exitCode: 1, stderr: "ok\r\nfake-runner: crlf hit\r\ntail", rules: rules)
        XCTAssertEqual(match?.detail, "fake-runner: crlf hit")
    }
}
