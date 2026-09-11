//
//  MCPEnvScrubTests.swift
//  WanWoTests
//
//  【M4-A 件12】件7 锚点：凭据擦除 scrub 全族（MCPEnvScrub.swift，dsh
//  subprocess index.ts:56/75-89 直译）——SENSITIVE_ENV_PATTERN
//  /KEY|PASSWORD|SECRET|TOKEN/i 无锚点子串、WANWO_ 管理前缀全删（前缀
//  比对先转大写——**wanwo_ 小写变体必须被擦**，index.ts:64-67 注释语义）、
//  正常变量保留、scrubbedParentEnv 只清 ambient（显式覆盖保留=合并侧）。
//

import XCTest
@testable import WanWo

final class MCPEnvScrubTests: XCTestCase {

    // MARK: 规则 1：敏感子串（大小写混合变体全擦）

    func testSensitiveSubstringsAreScrubbed() {
        for name in ["API_KEY", "api_key", "MyPassword", "client_secret",
                     "ACCESS_TOKEN", "OPENAI_API_KEY", "key", "SECRET"] {
            XCTAssertTrue(MCPEnvScrub.isSensitiveEnvName(name),
                          "\(name) must be scrubbed")
        }
    }

    /// 无词边界：MONKEY/tokenize 过擦属 dsh fail-closed 设计语义（index.ts:78
    /// 循环体 1:1——不修上游行为）。
    func testSubstringWithoutWordBoundaryOverscrubsByDesign() {
        XCTAssertTrue(MCPEnvScrub.isSensitiveEnvName("MONKEY"))
        XCTAssertTrue(MCPEnvScrub.isSensitiveEnvName("tokenize"))
        XCTAssertTrue(MCPEnvScrub.isSensitiveEnvName("passwords"))
    }

    // MARK: 规则 2：管理前缀（大小写不敏感——先 uppercased 再比前缀）

    func testManagedPrefixIsScrubbedCaseInsensitively() {
        XCTAssertTrue(MCPEnvScrub.isScrubbed("WANWO_STATE"))
        // 关键锚点：小写前缀必须被擦（dsh index.ts:64-67——否则父进程小写
        // 键幸存并在子进程读回，POSIX 上刻意小写命名不可信）。
        XCTAssertTrue(MCPEnvScrub.isScrubbed("wanwo_test"))
        XCTAssertTrue(MCPEnvScrub.isScrubbed("Wanwo_Thing"))
        XCTAssertEqual(MCPEnvScrub.managedNamespacePrefix, "WANWO_")
    }

    // MARK: 正常变量保留

    func testNormalVariablesSurvive() {
        for name in ["PATH", "HOME", "LANG", "EDITOR", "TERM", "SHELL",
                     "LC_ALL", "TMPDIR"] {
            XCTAssertFalse(MCPEnvScrub.isScrubbed(name),
                           "\(name) must survive the scrub")
        }
    }

    /// 敏感子串是独立规则：无前缀、纯敏感词也擦。
    func testTwoRulesAreIndependent() {
        // 有前缀无敏感词 → 前缀规则擦。
        XCTAssertTrue(MCPEnvScrub.isScrubbed("WANWO_DEBUG"))
        // 无前缀有敏感词 → 子串规则擦。
        XCTAssertTrue(MCPEnvScrub.isScrubbed("DATABASE_URL_TOKEN"))
        // 两者皆无 → 保留。
        XCTAssertFalse(MCPEnvScrub.isScrubbed("WANDERING"))
    }

    // MARK: scrubbedParentEnv（index.ts:75-89 循环体 1:1）

    func testScrubbedParentEnvFiltersBothRules() {
        let scrubbed = MCPEnvScrub.scrubbedParentEnv([
            "PATH": "/usr/bin",
            "HOME": "/root",
            "AWS_SECRET_ACCESS_KEY": "x",
            "WANWO_STATE": "internal",
            "wanwo_cache": "internal",
            "GITHUB_TOKEN": "y",
        ])
        XCTAssertEqual(scrubbed, ["PATH": "/usr/bin", "HOME": "/root"])
    }

    func testScrubbedParentEnvEmptyInput() {
        XCTAssertEqual(MCPEnvScrub.scrubbedParentEnv([:]), [:])
    }

    /// scrub 只清 ambient：显式 env 覆盖在合并侧保留（transport.ts:21-23
    /// buildChildEnv 形态——本函数不做合并，测试只锁「入参即全量 ambient」）。
    func testExplicitOverlayNotPartOfScrubContract() {
        let ambient = MCPEnvScrub.scrubbedParentEnv(["TOKEN": "leak", "PATH": "/bin"])
        let merged = ambient.merging(["TOKEN": "explicit"]) { _, explicit in explicit }
        XCTAssertEqual(merged["TOKEN"], "explicit")
        XCTAssertEqual(merged["PATH"], "/bin")
    }
}
