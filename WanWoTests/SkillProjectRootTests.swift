//
//  SkillProjectRootTests.swift
//  WanWoTests
//
//  【M4-E+ P3 测试 · 技能 workspace 根升格分组级】：
//    · resolve 双通道分叉（Swift 侧 write/edit 读面）：project 资源（绝对+
//      相对形态）→ 分组技能根；普通 workspace 文件/前缀边界 → 照旧会话桶
//    · writeAt 失效链实测（隐蔽关键点）：写分组技能根内 SKILL.md →
//      noteHostMutation 前缀命中失效重扫；写会话桶普通文件 → 不误伤
//    · recursiveFiles 遍历面并集（会话桶 + 分组技能根）
//    · FsContextRouter 正向特判：.agents/skills 前缀命中分组桶（无 sid 层）/
//      不含该前缀的 workspace 路径照旧会话桶（两种都断言）+ 前缀边界
//    · groupSkillsProjectRoot 形状 + guest 前缀形状不变（dsh 心智保真）
//

import XCTest
@testable import WanWo

final class SkillProjectRootTests: XCTestCase {

    // MARK: fixture

    private var workDir: URL!
    private var projectRoot: URL!
    private var skillsRoot: URL!
    private var sid: String!
    private var workspace: WorkspaceFileAccess!

    override func setUp() async throws {
        sid = "p3-\(UUID().uuidString)"
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4e-p3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
        // M4-E 验收修复：翻译粒度=.agents 整树（projectRoot=.agents 根）；
        // registry 扫描粒度仍=.agents/skills（skillsRoot）——两粒度分离。
        projectRoot = workDir.appendingPathComponent("project-agent", isDirectory: true)
        skillsRoot = projectRoot.appendingPathComponent("skills", isDirectory: true)
        workspace = WorkspaceFileAccess(sessionId: sid, projectSkillsRoot: projectRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
        // 清理真实 persistentBase 下的测试 sid 残留（WorkspaceFileAccess init
        // 会建会话桶目录）。
        try? FileManager.default.removeItem(
            at: WanWoPaths.groupRoot(base: WanWoPaths.persistentBase,
                                     groupID: WanWoPaths.defaultGroupID)
                .appendingPathComponent(sid, isDirectory: true))
    }

    private func makeSkill(_ name: String, in root: URL) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: test\n---\nBody"
            .write(to: dir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
    }

    // MARK: resolve 双通道分叉（project 资源 vs 会话 workspace）

    func testResolveSplitsProjectSkillsFromSessionWorkspace() {
        let sessionBucket = WanWoPaths.sessionPersistentDir(for: sid, bucket: "workspace")

        // project 资源（绝对 guest 路径）→ 分组 agent 资源根（.agents 整树）。
        XCTAssertEqual(
            workspace.resolve("/var/wanwo/workspace/.agents/skills/alpha/SKILL.md")?
                .standardizedFileURL.path,
            projectRoot.appendingPathComponent("skills/alpha/SKILL.md")
                .standardizedFileURL.path)
        // project 根自身（目录列出场景）。
        XCTAssertEqual(
            workspace.resolve("/var/wanwo/workspace/.agents/skills")?
                .standardizedFileURL.path,
            projectRoot.appendingPathComponent("skills").standardizedFileURL.path)
        // 相对路径形态同样命中。
        XCTAssertEqual(
            workspace.resolve(".agents/skills/alpha/SKILL.md")?
                .standardizedFileURL.path,
            projectRoot.appendingPathComponent("skills/alpha/SKILL.md")
                .standardizedFileURL.path)
        // 前缀边界（新语义）：.agents 整树归分组桶——skillsX 也在 .agents 下。
        XCTAssertEqual(
            workspace.resolve("/var/wanwo/workspace/.agents/skillsX/a.txt")?
                .standardizedFileURL.path,
            projectRoot.appendingPathComponent("skillsX/a.txt")
                .standardizedFileURL.path)
        // 普通 workspace 文件照旧会话桶。
        XCTAssertEqual(
            workspace.resolve("/var/wanwo/workspace/notes.txt")?
                .standardizedFileURL.path,
            sessionBucket.appendingPathComponent("notes.txt")
                .standardizedFileURL.path)
        // `..` 逃逸防护在特判分支同样生效（fail closed）。
        XCTAssertNil(workspace.resolve("/var/wanwo/workspace/.agents/skills/../../escape.txt"))
        // 默认注入（不传 projectSkillsRoot）= WanWoPaths 分组桶单一事实源派生。
        XCTAssertEqual(
            WorkspaceFileAccess(sessionId: sid)
                .resolve("/var/wanwo/workspace/.agents/skills/x.md")?
                .standardizedFileURL.path,
            WanWoPaths.groupAgentResourcesRoot(base: WanWoPaths.persistentBase,
                                               groupID: WanWoPaths.defaultGroupID)
                .appendingPathComponent("skills/x.md").standardizedFileURL.path)
    }

    // MARK: writeAt 失效链（隐蔽关键点：命中失效 + 不误伤）

    func testWriteAtInvalidationHitsProjectRootOnly() throws {
        // registry 扫描粒度=.agents/skills（skillsRoot）——resolve 翻译粒度
        // =.agents 整树，两粒度分离（见 setUp）。
        let registry = SkillRegistry(roots: [
            .init(source: .project, baseURL: skillsRoot)])
        workspace.onMutation = { [weak registry] url in
            registry?.noteHostMutation(url)
        }
        func hasSkill(_ name: String) -> Bool {
            registry.snapshot().summaries.contains { $0.name == name }
        }

        // 预热快照（回填缓存；此刻根内无技能）。
        XCTAssertFalse(hasSkill("external-after-warmup"))
        // 缓存有效后，直接在根内落一个技能文件（绕过 writeAt——模拟外部出现）。
        try makeSkill("external-after-warmup", in: skillsRoot)
        // 写会话桶普通文件 → 若误伤失效，下一次 snapshot 重扫会看到 external；
        // 断言「不可见」= 未误伤（缓存未被错误置脏）。
        try workspace.writeText("notes.txt", content: "hi", mode: .workspaceWrite)
        XCTAssertFalse(hasSkill("external-after-warmup"),
                       "写会话桶普通文件不应触发技能根失效重扫")

        // 写分组技能根内 SKILL.md → 失效命中 → 重扫可见。
        try workspace.writeText(".agents/skills/late/SKILL.md",
                                content: "---\nname: late\ndescription: L\n---\nBody",
                                mode: .workspaceWrite)
        XCTAssertTrue(hasSkill("late"), "写技能根内文件必须触发失效重扫")
    }

    // MARK: recursiveFiles 遍历面并集

    func testRecursiveFilesCoversSessionAndProjectRoots() throws {
        try workspace.writeText("ws-file.txt", content: "w", mode: .workspaceWrite)
        try workspace.writeText(".agents/skills/sk/SKILL.md",
                                content: "---\nname: sk\ndescription: S\n---\nB",
                                mode: .workspaceWrite)
        let names = Set(workspace.recursiveFiles().map(\.lastPathComponent))
        XCTAssertTrue(names.contains("ws-file.txt"), "会话桶文件必须在遍历面内")
        XCTAssertTrue(names.contains("SKILL.md"), "分组技能根文件必须在遍历面内")
    }

    // MARK: FsContextRouter 正向特判（最长前缀优先）

    func testFsContextRouterProjectSkillsPrefixWinsOverSessionBucket() {
        let router = FsContextRouter.shared
        // 验收修复：翻译粒度=.agents 整树（groupAgentResourcesRoot）。
        let projectAgentHost = WanWoPaths.groupAgentResourcesRoot(
            base: WanWoPaths.persistentBase, groupID: WanWoPaths.defaultGroupID)
        let sessionBucket = WanWoPaths.sessionPersistentDir(for: sid, bucket: "workspace")

        // project 资源 → 分组 agent 资源根（无 sid 层）。
        XCTAssertEqual(
            router.hostURL(forGuest: "/var/wanwo/workspace/.agents/skills/a/b.md",
                           sid: sid)?.path,
            projectAgentHost.appendingPathComponent("skills/a/b.md").path)
        // project 根自身（.agents 目录）。
        XCTAssertEqual(
            router.hostURL(forGuest: "/var/wanwo/workspace/.agents",
                           sid: sid)?.path,
            projectAgentHost.path)
        // 不含 .agents 前缀的 workspace 路径照旧会话桶（两种都断言）。
        XCTAssertEqual(
            router.hostURL(forGuest: "/var/wanwo/workspace/plain.txt", sid: sid)?.path,
            sessionBucket.appendingPathComponent("plain.txt").path)
        // 前缀边界（新语义）：.agents 整树归分组桶——skillsX 亦然。
        XCTAssertEqual(
            router.hostURL(forGuest: "/var/wanwo/workspace/.agents/skillsX/a",
                           sid: sid)?.path,
            projectAgentHost.appendingPathComponent("skillsX/a").path)
    }

    // MARK: 派生形状与 guest 心智保真

    func testGroupSkillsProjectRootShapeAndGuestPrefix() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-shape-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(
            WanWoPaths.groupSkillsProjectRoot(base: base, groupID: "g").path,
            base.appendingPathComponent("groups", isDirectory: true)
                .appendingPathComponent("g", isDirectory: true)
                .appendingPathComponent("workspace", isDirectory: true)
                .appendingPathComponent(".agents/skills", isDirectory: true).path)
        // guest 路径形状一字不变（dsh project 根心智保真——brief §5.3）。
        XCTAssertEqual(WanWoPaths.projectSkillsLinuxDir,
                       "/var/wanwo/workspace/.agents/skills")
        XCTAssertEqual(WanWoPaths.projectSkillsGroupTail, "workspace/.agents/skills")
        // 验收修复：.agents 整树粒度（fakefs/Swift 翻译统一）。
        XCTAssertEqual(
            WanWoPaths.groupAgentResourcesRoot(base: base, groupID: "g").path,
            base.appendingPathComponent("groups", isDirectory: true)
                .appendingPathComponent("g", isDirectory: true)
                .appendingPathComponent("workspace", isDirectory: true)
                .appendingPathComponent(".agents", isDirectory: true).path)
        let agentPrefix = WanWoPaths.workspaceLinuxDir + "/.agents"
        XCTAssertEqual(agentPrefix, "/var/wanwo/workspace/.agents")
    }
}
