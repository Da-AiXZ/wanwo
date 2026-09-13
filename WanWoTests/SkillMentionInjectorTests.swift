//
//  SkillMentionInjectorTests.swift
//  WanWoTests
//
//  【M4-D 件 D6 测试】提取（mentions.rs 逐式：裸名/链接/env 排除/六类名字符/
//  畸形回退）→ 选择（selection.rs WanWo 形态：路径三形态匹配/歧义保护）→
//  投影（真用户消息识别/去重/正文注入形态+8KB 截断/user-only 显式提及）。
//

import XCTest
@testable import WanWo

final class SkillMentionInjectorTests: XCTestCase {

    // MARK: fixture

    private func summary(_ name: String,
                         source: SkillSource = .user,
                         invocation: SkillInvocation = .default,
                         bodyPath: String? = nil,
                         resourceBase: String? = nil) -> SkillSummary {
        // Swift 默认参数禁引用同函数其他参数——bodyPath/resourceBase 缺省在
        // 方法体内按 name 派生（M4-C 同款笔误族的修正形态）。
        SkillSummary(name: name, description: "desc \(name)", whenToUse: nil,
                     invocation: invocation, source: source,
                     resourceBase: resourceBase ?? "/tmp/skills/\(name)",
                     bodyPath: bodyPath ?? "/tmp/skills/\(name)/SKILL.md")
    }

    private func event(_ seq: Int, _ text: String) -> SessionEvent {
        SessionEvent(seq: seq, timeMs: 0, payload: .userMessage(text: text))
    }

    /// 写临时技能正文文件，返回其路径。
    private func writeBody(_ name: String, _ content: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4d-d6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: 提取（mentions.rs 逐式）

    func testExtractPlainMention() {
        let mentions = SkillMentionInjector.extractToolMentions("use $foo please")
        XCTAssertEqual(mentions.names, ["foo"])
        XCTAssertEqual(mentions.plainNames, ["foo"])
        XCTAssertTrue(mentions.paths.isEmpty)
    }

    func testExtractNameCharsAndBoundaries() {
        // 六类字符（a-zA-Z0-9_-:）连续；标点/空白截断。
        let mentions = SkillMentionInjector.extractToolMentions("$foo-bar_baz:qux.")
        XCTAssertEqual(mentions.plainNames, ["foo-bar_baz:qux"])
        // 非名字字符开头（sigil 后空白）不触发。
        XCTAssertTrue(SkillMentionInjector.extractToolMentions("$ x").names.isEmpty)
        // 行尾 sigil（无名字）不崩不出。
        XCTAssertTrue(SkillMentionInjector.extractToolMentions("end $").isEmpty)
        // sigil 后空白。
        XCTAssertTrue(SkillMentionInjector.extractToolMentions("$ ").isEmpty)
    }

    func testExtractExcludesCommonEnvVars() {
        // 11 个 env var 全排除（大小写不敏感——PATH/HOME/USER/SHELL/PWD/
        // TMPDIR/TEMP/TMP/LANG/TERM/XDG_CONFIG_HOME）。
        let mentions = SkillMentionInjector.extractToolMentions(
            "$PATH $HOME $USER $SHELL $PWD $TMPDIR $TEMP $TMP $LANG $TERM "
            + "$XDG_CONFIG_HOME $path $home")
        XCTAssertTrue(mentions.isEmpty)
    }

    func testExtractLinkedMention() {
        let mentions = SkillMentionInjector.extractToolMentions(
            "see [$alpha](skill:///skills/alpha/SKILL.md) end")
        XCTAssertEqual(mentions.names, ["alpha"])
        XCTAssertEqual(mentions.paths, ["skill:///skills/alpha/SKILL.md"])
        // 链接形态不进 plain_names（mentions.rs:136 仅裸名插入）。
        XCTAssertTrue(mentions.plainNames.isEmpty)
    }

    func testExtractLinkedOptionalWhitespace() {
        // ']' 与 '(' 之间可选 ASCII 空白（mentions.rs:176-181）。
        let mentions = SkillMentionInjector.extractToolMentions(
            "[$a]  (skill:///x)")
        XCTAssertEqual(mentions.names, ["a"])
        XCTAssertEqual(mentions.paths, ["skill:///x"])
    }

    func testExtractLinkedNonSkillKinds() {
        // App/Mcp/Plugin kind：不入 names 但入 paths（mentions.rs:99-105）。
        let mentions = SkillMentionInjector.extractToolMentions(
            "[$a](mcp://srv) [$b](app://x) [$c](plugin://p)")
        XCTAssertTrue(mentions.names.isEmpty)
        XCTAssertEqual(mentions.paths, ["mcp://srv", "app://x", "plugin://p"])
    }

    func testExtractLinkedSkillKindAndOtherKindEnterNames() {
        // skill:// 与无 scheme（Other）都进 names。
        let mentions = SkillMentionInjector.extractToolMentions(
            "[$a](skill:///x) [$b](/plain/path)")
        XCTAssertEqual(mentions.names, ["a", "b"])
    }

    func testExtractLinkedEnvVarNameExcluded() {
        XCTAssertTrue(SkillMentionInjector.extractToolMentions(
            "[$PATH](skill:///x)").isEmpty)
    }

    func testExtractLinkFallbackToPlainOnMalformed() {
        // 畸形链接（无 '(' 段）→ '[$abc]' 退化：'$' 处按裸名继续（Rust 字节
        // 扫描链接失败后 index+1 前进的同款语义）。
        let noParens = SkillMentionInjector.extractToolMentions("[$abc] no parens")
        XCTAssertEqual(noParens.plainNames, ["abc"])
        XCTAssertTrue(noParens.paths.isEmpty)
        // 空路径拒绝（mentions.rs:197-199——'()' 内 trim 后为空 → 链接面不
        // 成立，'[$a]' 退化出裸名）。
        let emptyPath = SkillMentionInjector.extractToolMentions("[$a]()")
        XCTAssertTrue(emptyPath.paths.isEmpty)
        XCTAssertEqual(emptyPath.plainNames, ["a"])
        // skill:// 前缀本身非空路径 → 链接面成立（skill kind，入 names+paths）。
        let schemeOnly = SkillMentionInjector.extractToolMentions("[$a](skill://)")
        XCTAssertEqual(schemeOnly.names, ["a"])
        XCTAssertEqual(schemeOnly.paths, ["skill://"])
        // 缺 ']' → 链接面不成立，同退化。
        let missingBracket = SkillMentionInjector.extractToolMentions("[$a (skill://x)")
        XCTAssertTrue(missingBracket.paths.isEmpty)
        XCTAssertEqual(missingBracket.plainNames, ["a"])
    }

    func testSkillFilenameAndNormalize() {
        XCTAssertTrue(SkillMentionInjector.isSkillFilename("/a/b/Skill.MD"))
        XCTAssertTrue(SkillMentionInjector.isSkillFilename("skill.md"))
        XCTAssertFalse(SkillMentionInjector.isSkillFilename("/a/b/other.md"))
        XCTAssertEqual(SkillMentionInjector.normalizeSkillPath("skill:///x/y"),
                       "/x/y")
        XCTAssertEqual(SkillMentionInjector.normalizeSkillPath("/raw"), "/raw")
    }

    // MARK: 选择（selection.rs WanWo 形态）

    func testSelectSkillsByPathThreeForms() {
        let snapshot = SkillSnapshot(
            summaries: [summary("foo", bodyPath: "/s/foo/SKILL.md",
                                resourceBase: "/s/foo")],
            errors: [])
        // 正文路径（skill:// 归一后 = canonical bodyPath）。
        let byBody = SkillMentionInjector.selectSkills(
            mentions: SkillMentionInjector.extractToolMentions(
                "[$foo](skill:///s/foo/SKILL.md)"), from: snapshot)
        XCTAssertEqual(byBody.map(\.name), ["foo"])
        // bundle 目录路径（= resourceBase，WanWo 发现路径等价）。
        let byDir = SkillMentionInjector.selectSkills(
            mentions: SkillMentionInjector.extractToolMentions(
                "[$foo](skill:///s/foo)"), from: snapshot)
        XCTAssertEqual(byDir.map(\.name), ["foo"])
        // 平铺形态（resourceBase + /SKILL.md）。
        let flat = SkillSummary(name: "bar", description: "d", whenToUse: nil,
                                invocation: .default, source: .user,
                                resourceBase: "/s",
                                bodyPath: "/s/bar.md")
        let flatSnapshot = SkillSnapshot(summaries: [flat], errors: [])
        let byFlat = SkillMentionInjector.selectSkills(
            mentions: SkillMentionInjector.extractToolMentions(
                "[$bar](/s/bar.md)"), from: flatSnapshot)
        XCTAssertEqual(byFlat.map(\.name), ["bar"])
    }

    func testSelectSkillsPlainNameUnambiguousOnly() {
        let snapshot = SkillSnapshot(summaries: [summary("foo")], errors: [])
        let selected = SkillMentionInjector.selectSkills(
            mentions: SkillMentionInjector.extractToolMentions("try $foo"),
            from: snapshot)
        XCTAssertEqual(selected.map(\.name), ["foo"])
    }

    func testSelectSkillsAmbiguousNameSkipped() {
        // 重名（防御性构造——registry 同名先见者胜正常不产出）：skill_count
        // != 1 → 跳过（selection.rs:178-190 歧义保护）。
        let snapshot = SkillSnapshot(summaries: [
            summary("foo", bodyPath: "/a/SKILL.md", resourceBase: "/a"),
            summary("foo", bodyPath: "/b/SKILL.md", resourceBase: "/b"),
        ], errors: [])
        let selected = SkillMentionInjector.selectSkills(
            mentions: SkillMentionInjector.extractToolMentions("try $foo"),
            from: snapshot)
        XCTAssertTrue(selected.isEmpty)
    }

    func testBuildSkillNameCounts() {
        let counts = SkillMentionInjector.buildSkillNameCounts([
            summary("a"), summary("b"), summary("a")])
        XCTAssertEqual(counts["a"], 2)
        XCTAssertEqual(counts["b"], 1)
        XCTAssertNil(counts["c"])
    }

    // MARK: 投影（真用户消息识别 / 去重 / 正文注入）

    func testProjectInjectsBodyBlock() throws {
        let bodyPath = try writeBody("foo", "hello body")
        let snapshot = SkillSnapshot(
            summaries: [summary("foo", bodyPath: bodyPath,
                                resourceBase: (bodyPath as NSString).deletingLastPathComponent)],
            errors: [])
        let injection = SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "please use $foo")])
        XCTAssertNotNil(injection)
        XCTAssertTrue(injection?.contains("<skill name=\"foo\">\nhello body\n</skill>") ?? false)
    }

    func testProjectTruncatesLargeBodyWithWarning() throws {
        let bodyPath = try writeBody("big", String(repeating: "x", count: 12_000))
        let snapshot = SkillSnapshot(
            summaries: [summary("big", bodyPath: bodyPath)], errors: [])
        guard let injection = SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "$big")]) else {
            return XCTFail("mention injection expected")
        }
        // 8KB=8000 字节截断 + 告警文案（extension.rs:472 逐字复用 D5 常量）。
        XCTAssertTrue(injection.contains(
            SkillTool.truncationWarningPrefix + "big"
                + SkillTool.truncationWarningSuffix))
        // 正文主体恰好 8000 字节（全 'x' 载体——截断点精确断言）。
        XCTAssertEqual(injection.filter { $0 == "x" }.count, 8000)
    }

    func testProjectDeduplicatesWhenMarkerLater() throws {
        let bodyPath = try writeBody("foo", "body")
        let snapshot = SkillSnapshot(
            summaries: [summary("foo", bodyPath: bodyPath)], errors: [])
        let injection = SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "use $foo")])!
        // 注入落盘后：派生面已有 marker 且晚于该消息 → nil（幂等）。
        let events: [SessionEvent] = [
            event(0, "use $foo"),
            event(1, injection),
        ]
        XCTAssertNil(SkillMentionInjector.project(snapshot: snapshot, events: events))
    }

    func testProjectRescansOnLaterMessage() throws {
        // 第二条消息再次提及 → 前次注入早于该消息 → 重新注入。
        let bodyPath = try writeBody("foo", "body")
        let snapshot = SkillSnapshot(
            summaries: [summary("foo", bodyPath: bodyPath)], errors: [])
        let injection = SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "use $foo")])!
        let events: [SessionEvent] = [
            event(0, "use $foo"),
            event(1, injection),
            event(2, "again $foo please"),
        ]
        XCTAssertNotNil(SkillMentionInjector.project(snapshot: snapshot, events: events))
    }

    func testProjectSkipsNonRealUserMessages() throws {
        let bodyPath = try writeBody("foo", "body")
        let snapshot = SkillSnapshot(
            summaries: [summary("foo", bodyPath: bodyPath)], errors: [])
        // 目录消息（<system-reminder>）与本件注入产物（<skill ）不扫——防自吞。
        let events: [SessionEvent] = [
            event(0, "<system-reminder>\ncatalog mentions $foo\n</system-reminder>"),
            event(1, "<skill name=\"other\">\nbody refs $foo\n</skill>"),
        ]
        XCTAssertNil(SkillMentionInjector.project(snapshot: snapshot, events: events))
    }

    func testProjectUnknownNameSilent() {
        let snapshot = SkillSnapshot(summaries: [summary("foo")], errors: [])
        XCTAssertNil(SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "$ghost not found")]))
    }

    func testProjectUserOnlySkillStillInjects() throws {
        // disable-model-invocation 技能：显式提及=用户调用通道，照常注入
        // （dsh 四象限——user-only 只挡模型自发调用）。
        let bodyPath = try writeBody("usronly", "user body")
        let snapshot = SkillSnapshot(summaries: [
            summary("usronly", bodyPath: bodyPath,
                    invocation: SkillInvocation(modelInvocable: false,
                                                userInvocable: true)),
        ], errors: [])
        let injection = SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "$usronly")])
        XCTAssertNotNil(injection)
        XCTAssertTrue(injection?.contains("user body") ?? false)
    }

    func testProjectMultipleMentionsSingleMessage() throws {
        let pathA = try writeBody("aaa", "A body")
        let pathB = try writeBody("bbb", "B body")
        let snapshot = SkillSnapshot(summaries: [
            summary("aaa", bodyPath: pathA), summary("bbb", bodyPath: pathB),
        ], errors: [])
        let injection = SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "use $aaa and $bbb")])
        XCTAssertNotNil(injection)
        XCTAssertTrue(injection?.contains("<skill name=\"aaa\">") ?? false)
        XCTAssertTrue(injection?.contains("<skill name=\"bbb\">") ?? false)
        // 单消息多块，"\n\n" 连接（实现选择，登记）。
        XCTAssertTrue(injection?.contains("</skill>\n\n<skill name=\"bbb\">") ?? false)
    }

    func testProjectMissingBodyFileSkipsGracefully() {
        // TOCTOU：正文文件在快照后消失 → 该技能跳过，不抛不崩（fail open）。
        let snapshot = SkillSnapshot(
            summaries: [summary("gone", bodyPath: "/nonexistent/gone.md")],
            errors: [])
        XCTAssertNil(SkillMentionInjector.project(
            snapshot: snapshot, events: [event(0, "$gone")]))
    }
}

// MARK: - 测试辅助（SkillToolMentions.isEmpty 的取反表述）

private extension SkillToolMentions {
    /// contains(nameAny:)——测试可读性辅助：任一名存在与否。
    func contains(nameAny: Bool) -> Bool {
        nameAny ? !names.isEmpty : names.isEmpty
    }
}
