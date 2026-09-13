//
//  SkillRegistryTests.swift
//  WanWoTests
//
//  【M4-D 件 D2+D3 测试】发现装载（双形态/不递归/三根 rank 合并/同根首见/
//  kebab 契约/防御上限截断）+ invocation 两键四组合 + 失效通道（缓存命中/
//  invalidate 重扫/write-edit 命中前缀判定）。发现走临时目录 fixture（真实 FS）。
//  dsh 锚点：skills.md:64-85（发现/rank/失效）、:94-126（invocation/缺省）；
//  codex 常量：discovery.rs:17-18 / loader/mod.rs:31-32。
//

import XCTest
@testable import WanWo

final class SkillRegistryTests: XCTestCase {

    private var tempBase: URL!

    override func setUpWithError() throws {
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempBase)
    }

    // MARK: fixture

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func root(_ source: SkillSource, _ name: String) -> SkillRegistry.Root {
        SkillRegistry.Root(source: source,
                           baseURL: tempBase.appendingPathComponent(name,
                                                                   isDirectory: true))
    }

    // MARK: 发现：双形态 + resourceBase

    func testDiscoversBundleAndFlatForms() throws {
        let project = root(.project, "project")
        try write("---\nname: deploy service\ndescription: Deploy helper\n---\nbody",
                  to: project.appendingPathComponent("deploy-service/SKILL.md"))
        try write("---\ndescription: Quick note taking\n---\n",
                  to: project.appendingPathComponent("quick-note.md"))

        let snapshot = SkillRegistry.scan(roots: [project])

        XCTAssertEqual(snapshot.errors, [])
        XCTAssertEqual(snapshot.summaries.map(\.name),
                       ["deploy service", "quick-note"])  // name 字典序
        let deploy = snapshot.summaries[0]
        XCTAssertEqual(deploy.description, "Deploy helper")
        XCTAssertEqual(deploy.source, .project)
        XCTAssertEqual(deploy.invocation, .default)
        XCTAssertNil(deploy.whenToUse)
        // bundle 形态：resourceBase=技能目录；缺省名回退=目录名（D1 default_name 消费位）
        XCTAssertEqual(deploy.resourceBase,
                       project.appendingPathComponent("deploy-service").path)
        let note = snapshot.summaries[1]
        XCTAssertEqual(note.description, "Quick note taking")
        // 平铺形态：resourceBase=所在根目录
        XCTAssertEqual(note.resourceBase, project.baseURL.path)
    }

    // MARK: 不递归（dsh:85 语义裁定）

    func testNonRecursiveNestedEntriesSkipped() throws {
        let project = root(.project, "project")
        try write("---\nname: nested\ndescription: should not load\n---\n",
                  to: project.appendingPathComponent("outer/inner/SKILL.md"))
        try write("---\nname: sibling\ndescription: should not load\n---\n",
                  to: project.appendingPathComponent("outer/other.md"))

        let snapshot = SkillRegistry.scan(roots: [project])

        // 直接子层只有目录 outer（无 SKILL.md=非技能静默跳过）→ 零技能零错误
        XCTAssertEqual(snapshot.summaries, [])
        XCTAssertEqual(snapshot.errors, [])
    }

    // MARK: rank 合并（跨根同名 rank 小者胜；简报环 4）

    func testCrossRootSameNameRankOrderWins() throws {
        let project = root(.project, "project")
        let user = root(.user, "user")
        let bundled = root(.bundled, "bundled")
        try write("---\ndescription: from project\n---\n",
                  to: project.appendingPathComponent("shared-skill/SKILL.md"))
        try write("---\ndescription: from user\n---\n",
                  to: user.appendingPathComponent("shared-skill/SKILL.md"))
        try write("---\ndescription: from bundled\n---\n",
                  to: bundled.appendingPathComponent("shared-skill/SKILL.md"))
        try write("---\ndescription: user only\n---\n",
                  to: user.appendingPathComponent("user-only/SKILL.md"))

        // 乱序传入 roots——合并按 rank 全序而非入参序
        let snapshot = SkillRegistry.scan(roots: [bundled, user, project])

        XCTAssertEqual(snapshot.summaries.count, 2)
        let shared = snapshot.summaries.first { $0.name == "shared-skill" }
        XCTAssertEqual(shared?.description, "from project")
        XCTAssertEqual(shared?.source, .project)
        let userOnly = snapshot.summaries.first { $0.name == "user-only" }
        XCTAssertEqual(userOnly?.source, .user)
    }

    // MARK: 同根同名首见（扫描序确定性）

    func testSameRootDuplicateFirstSeenWins() throws {
        let project = root(.project, "project")
        // 目录 alpha（frontmatter name=beta）先于平铺 beta.md（同名）——
        // children 按名排序 "alpha" < "beta.md"
        try write("---\nname: beta\ndescription: from dir\n---\n",
                  to: project.appendingPathComponent("alpha/SKILL.md"))
        try write("---\nname: beta\ndescription: from flat\n---\n",
                  to: project.appendingPathComponent("beta.md"))

        let snapshot = SkillRegistry.scan(roots: [project])

        XCTAssertEqual(snapshot.summaries.count, 1)
        XCTAssertEqual(snapshot.summaries.first?.description, "from dir")
    }

    // MARK: invocation 四组合 + 缺省（dsh:94-126）

    func testInvocationFourCombinationsAndDefaults() {
        let cases: [(String, Bool, Bool)] = [
            ("---\ndescription: d\n---\n", true, true),  // 缺省双 true（dsh:126）
            ("---\ndescription: d\ndisable-model-invocation: true\n---\n",
             false, true),
            ("---\ndescription: d\nuser-invocable: false\n---\n",
             true, false),
            ("---\ndescription: d\ndisable-model-invocation: true\n"
                + "user-invocable: false\n---\n", false, false),
            ("---\ndescription: d\ndisable-model-invocation: false\n"
                + "user-invocable: true\n---\n", true, true),
        ]
        for (frontmatter, model, user) in cases {
            let flags = SkillRegistry.invocationFlags(fromFrontmatter: frontmatter)
            XCTAssertEqual(flags.modelInvocable, model, "frontmatter: \(frontmatter)")
            XCTAssertEqual(flags.userInvocable, user, "frontmatter: \(frontmatter)")
        }
    }

    // MARK: invocation 两键值形态（YAML 1.2 core 布尔族；无效值缺省——宽解析登记）

    func testInvocationKeyParsingVariants() {
        XCTAssertEqual(SkillRegistry.parseYAMLBool("true"), true)
        XCTAssertEqual(SkillRegistry.parseYAMLBool("True"), true)
        XCTAssertEqual(SkillRegistry.parseYAMLBool("TRUE"), true)
        XCTAssertEqual(SkillRegistry.parseYAMLBool("false"), false)
        XCTAssertEqual(SkillRegistry.parseYAMLBool("FALSE"), false)
        // 引号包裹=字符串≠布尔；YAML 1.1 族（yes/no）不收——serde_yaml 1.2 core 口径
        XCTAssertNil(SkillRegistry.parseYAMLBool("'true'"))
        XCTAssertNil(SkillRegistry.parseYAMLBool("yes"))
        XCTAssertNil(SkillRegistry.parseYAMLBool(""))
        // 嵌套位置的键被忽略（仅顶层缩进 0 生效）
        let nested = "---\nmetadata:\n  user-invocable: false\ndescription: d\n---\n"
        XCTAssertEqual(
            SkillRegistry.invocationFlags(fromFrontmatter: nested).userInvocable,
            true)
        // 无 frontmatter → 缺省
        XCTAssertEqual(SkillRegistry.invocationFlags(fromFrontmatter: "no frontmatter"),
                       .default)
    }

    // MARK: kebab-case 契约（skills.md:85；发现面校验）

    func testKebabViolationSkippedWithError() throws {
        let project = root(.project, "project")
        try write("---\ndescription: bad name\n---\n",
                  to: project.appendingPathComponent("Bad_Name/SKILL.md"))
        try write("---\ndescription: good\n---\n",
                  to: project.appendingPathComponent("good-one/SKILL.md"))

        let snapshot = SkillRegistry.scan(roots: [project])

        XCTAssertEqual(snapshot.summaries.map(\.name), ["good-one"])
        XCTAssertTrue(snapshot.errors.contains { $0.contains("Bad_Name") })

        // 契约形态逐字：^[a-z0-9]+(?:-[a-z0-9]+)*$
        XCTAssertTrue(SkillRegistry.isKebabCase("a"))
        XCTAssertTrue(SkillRegistry.isKebabCase("hello-wanwo"))
        XCTAssertTrue(SkillRegistry.isKebabCase("a-b-c"))
        XCTAssertFalse(SkillRegistry.isKebabCase(""))
        XCTAssertFalse(SkillRegistry.isKebabCase("Hello"))
        XCTAssertFalse(SkillRegistry.isKebabCase("-lead"))
        XCTAssertFalse(SkillRegistry.isKebabCase("trail-"))
        XCTAssertFalse(SkillRegistry.isKebabCase("a--b"))
        XCTAssertFalse(SkillRegistry.isKebabCase("a_b"))
    }

    // MARK: R5 fail closed：解析失败技能跳过不崩发现

    func testParseFailureSkippedOthersStillLoad() throws {
        let project = root(.project, "project")
        try write("---\nname: broken\n---\n",  // 缺 description
                  to: project.appendingPathComponent("broken/SKILL.md"))
        try write("---\ndescription: ok\n---\n",
                  to: project.appendingPathComponent("works/SKILL.md"))

        let snapshot = SkillRegistry.scan(roots: [project])

        XCTAssertEqual(snapshot.summaries.map(\.name), ["works"])
        XCTAssertTrue(snapshot.errors.contains {
            $0.contains("broken") && $0.contains("missing field `description`")
        })
    }

    // MARK: 根缺失 = 空集非错误

    func testMissingRootIsEmptyNotError() {
        let missing = root(.user, "does-not-exist")
        let snapshot = SkillRegistry.scan(roots: [missing])
        XCTAssertEqual(snapshot, SkillSnapshot(summaries: [], errors: []))
    }

    // MARK: 防御上限截断（codex discovery.rs:17-18 / loader/mod.rs:31-32）

    func testProductionLimitsMatchCodexConstants() {
        XCTAssertEqual(SkillRegistry.maxDirsPerRoot, 2000)
        XCTAssertEqual(SkillRegistry.maxEntriesPerRoot, 20_000)
    }

    func testLimitsTruncateWithErrors() throws {
        let project = root(.project, "project")
        for name in ["aaa", "bbb", "ccc"] {
            try write("---\ndescription: \(name)\n---\n",
                      to: project.appendingPathComponent("\(name)/SKILL.md"))
        }
        // 目录上限：maxDirs=2 → 第三个目录处截断 + error
        let byDirs = SkillRegistry.scan(roots: [project],
                                        limits: .init(maxDirs: 2, maxEntries: 100))
        XCTAssertEqual(byDirs.summaries.map(\.name).sorted(), ["aaa", "bbb"])
        XCTAssertTrue(byDirs.errors.contains { $0.contains("directory limit 2") })

        // 条目上限：maxEntries=1 → 首条之后截断 + error
        let byEntries = SkillRegistry.scan(roots: [project],
                                           limits: .init(maxDirs: 100, maxEntries: 1))
        XCTAssertEqual(byEntries.summaries.map(\.name), ["aaa"])
        XCTAssertTrue(byEntries.errors.contains { $0.contains("entry limit 1") })
    }

    // MARK: 失效通道（缓存命中/invalidate/组装期 refresh）

    func testInvalidationTriggersRescan() throws {
        let project = root(.project, "project")
        let registry = SkillRegistry(roots: [project])
        try write("---\ndescription: one\n---\n",
                  to: project.appendingPathComponent("one/SKILL.md"))

        let first = registry.snapshot()
        XCTAssertEqual(first.summaries.count, 1)

        // 未失效：缓存命中，新增技能不出现（快照值等价）
        try write("---\ndescription: two\n---\n",
                  to: project.appendingPathComponent("two/SKILL.md"))
        XCTAssertEqual(registry.snapshot(), first)
        // 组装期 refresh（通道①）：缓存仍有效即幂等不重扫
        registry.refresh()
        XCTAssertEqual(registry.snapshot(), first)

        // 通道③预留入口：置脏 → 重扫
        registry.invalidate()
        XCTAssertEqual(registry.snapshot().summaries.count, 2)
    }

    // MARK: write/edit 命中判定（dsh:81；前缀匹配）

    func testNoteHostMutationPrefixJudge() throws {
        let project = root(.project, "project")
        let outside = tempBase.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: true)
        let registry = SkillRegistry(roots: [project])
        _ = registry.snapshot()  // 预热（此时根空——fixture 唯一技能 late 尚未写入）

        // 根内路径 → 失效：重扫可见（write 本身不经过观测缝——测试用
        // noteHostMutation 模拟根内变更触发失效，dsh:81）
        try write("---\ndescription: late\n---\n",
                  to: project.appendingPathComponent("late/SKILL.md"))
        registry.noteHostMutation(project.appendingPathComponent("late/SKILL.md"))
        XCTAssertEqual(registry.snapshot().summaries.count, 1)

        // 根外路径 → 不失效：缓存保持（原版时序错位：预热在 write 前、期望值
        // 按"预热后已可见"错位 +1——CI 第七轮实证，时序对齐重写）
        registry.noteHostMutation(outside.appendingPathComponent("unrelated.md"))
        XCTAssertEqual(registry.snapshot().summaries.count, 1)

        // 根路径本身也算命中；删除后重扫回落
        registry.noteHostMutation(project.baseURL)
        try FileManager.default.removeItem(
            at: project.appendingPathComponent("late"))
        XCTAssertEqual(registry.snapshot().summaries.count, 0)
    }
}

/// Root 的路径算术便利（测试断言用；生产代码经 baseURL 直取——Root 为纯
/// 数据对，路径派生属测试断言的读面）。
private extension SkillRegistry.Root {
    func appendingPathComponent(_ component: String) -> URL {
        baseURL.appendingPathComponent(component)
    }
}
