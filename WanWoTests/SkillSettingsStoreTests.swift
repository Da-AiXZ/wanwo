//
//  SkillSettingsStoreTests.swift
//  WanWoTests
//
//  【M4-D 件 D7 测试】启停覆盖层：skills-settings.json roundtrip / 损坏容忍 /
//  registry 出口过滤（停用→快照消失，恢复→复现，无需 invalidate）/ revision
//  失配重扫（导入新技能跨实例生效）/ snapshotIncludingDisabled 列表面 /
//  SkillImporter 四向（目录/平铺/同名跳过/非 md 拒收）。
//

import XCTest
@testable import WanWo

@MainActor
final class SkillSettingsStoreTests: XCTestCase {

    // MARK: fixture

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4d-d7-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeSkill(_ root: URL, _ name: String,
                           description: String = "test skill") throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = "---\nname: \(name)\ndescription: \(description)\n---\nBody."
        try content.write(to: dir.appendingPathComponent("SKILL.md"),
                          atomically: true, encoding: .utf8)
    }

    // MARK: 持久宿主 roundtrip / 损坏容忍

    func testRoundtrip() {
        let fileURL = workDir.appendingPathComponent("skills-settings.json")
        let store = SkillSettingsStore(fileURL: fileURL)
        store.setDisabled(true, name: "alpha")
        store.setDisabled(true, name: "beta")
        store.setDisabled(false, name: "beta")

        let reloaded = SkillSettingsStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.disabledSkills, ["alpha"])
        XCTAssertTrue(reloaded.isDisabled("alpha"))
        XCTAssertFalse(reloaded.isDisabled("beta"))
    }

    func testSetDisabledIdempotentNoRewrite() {
        let fileURL = workDir.appendingPathComponent("skills-settings.json")
        let store = SkillSettingsStore(fileURL: fileURL)
        store.setDisabled(true, name: "alpha")
        let revision = store.disabledIndex.currentRevision
        // 重复写入同值 → 索引 revision 不动（无变化不落盘）。
        store.setDisabled(true, name: "alpha")
        XCTAssertEqual(store.disabledIndex.currentRevision, revision)
    }

    func testCorruptFileIgnored() throws {
        let fileURL = workDir.appendingPathComponent("skills-settings.json")
        try "not json {{{".data(using: .utf8)!.write(to: fileURL)
        let store = SkillSettingsStore(fileURL: fileURL)
        XCTAssertTrue(store.disabledSkills.isEmpty)
        // 空集起步后可正常启停（不因损坏文件卡死）。
        store.setDisabled(true, name: "gamma")
        XCTAssertTrue(store.isDisabled("gamma"))
    }

    // MARK: registry 覆盖层（出口过滤 + revision 缓存键）

    func testOverlayFiltersSnapshotAndRecovers() throws {
        let userRoot = workDir.appendingPathComponent("skills", isDirectory: true)
        try makeSkill(userRoot, "foo")
        let store = SkillSettingsStore(
            fileURL: workDir.appendingPathComponent("settings.json"))
        let registry = SkillRegistry(
            roots: [.init(source: .user, baseURL: userRoot)],
            settings: store)

        // 未停用 → 在快照中。
        XCTAssertTrue(registry.snapshot().summaries.contains { $0.name == "foo" })

        // 停用 → 出口过滤消失（无需 invalidate——出口逐读过滤）。
        store.setDisabled(true, name: "foo")
        XCTAssertFalse(registry.snapshot().summaries.contains { $0.name == "foo" })

        // 恢复 → 复现。
        store.setDisabled(false, name: "foo")
        XCTAssertTrue(registry.snapshot().summaries.contains { $0.name == "foo" })
    }

    func testOverlayRevisionBumpTriggersRescan() throws {
        let userRoot = workDir.appendingPathComponent("skills", isDirectory: true)
        try makeSkill(userRoot, "foo")
        let store = SkillSettingsStore(
            fileURL: workDir.appendingPathComponent("settings.json"))
        let registry = SkillRegistry(
            roots: [.init(source: .user, baseURL: userRoot)],
            settings: store)
        XCTAssertEqual(registry.snapshot().summaries.count, 1)

        // 导入新技能文件 + noteExternalChange（revision 递增）→ 缓存失配重扫
        // （通道③跨实例：活动会话 registry 无需直接 invalidate）。
        try makeSkill(userRoot, "bar")
        store.noteExternalChange()
        let names = Set(registry.snapshot().summaries.map(\.name))
        XCTAssertEqual(names, ["foo", "bar"])
    }

    func testSnapshotIncludingDisabledKeepsDisabledEntries() throws {
        let userRoot = workDir.appendingPathComponent("skills", isDirectory: true)
        try makeSkill(userRoot, "foo")
        try makeSkill(userRoot, "bar")
        let store = SkillSettingsStore(
            fileURL: workDir.appendingPathComponent("settings.json"))
        store.setDisabled(true, name: "foo")
        let registry = SkillRegistry(
            roots: [.init(source: .user, baseURL: userRoot)],
            settings: store)

        // 消费面（snapshot）：foo 已滤。
        XCTAssertEqual(registry.snapshot().summaries.map(\.name), ["bar"])
        // 设置页列表面（snapshotIncludingDisabled）：foo 保留（可重新启用）。
        XCTAssertEqual(
            Set(registry.snapshotIncludingDisabled().summaries.map(\.name)),
            ["foo", "bar"])
    }

    func testRegistryWithoutOverlayUnchanged() throws {
        // settings=nil 既有形态不变（既有测试/调用点兼容回归）。
        let userRoot = workDir.appendingPathComponent("skills", isDirectory: true)
        try makeSkill(userRoot, "foo")
        let registry = SkillRegistry(
            roots: [.init(source: .user, baseURL: userRoot)])
        XCTAssertEqual(registry.snapshot().summaries.count, 1)
    }

    // MARK: SkillImporter（四向）

    func testImportFolderBundle() throws {
        let sourceRoot = workDir.appendingPathComponent("src", isDirectory: true)
        try makeSkill(sourceRoot, "imported")
        let userRoot = workDir.appendingPathComponent("dest", isDirectory: true)

        let result = SkillImporter.importItems(
            at: [sourceRoot.appendingPathComponent("imported")], into: userRoot)
        XCTAssertEqual(result.imported, ["imported"])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        // 复制产物可被发现面识别（bundle 形态）。
        let registry = SkillRegistry(
            roots: [.init(source: .user, baseURL: userRoot)])
        XCTAssertEqual(registry.snapshot().summaries.first?.name, "imported")
    }

    func testImportFlatMarkdown() throws {
        let sourceRoot = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        let flat = sourceRoot.appendingPathComponent("flat-skill.md")
        try "---\nname: flat-skill\ndescription: d\n---\nB."
            .write(to: flat, atomically: true, encoding: .utf8)
        let userRoot = workDir.appendingPathComponent("dest", isDirectory: true)

        let result = SkillImporter.importItems(at: [flat], into: userRoot)
        XCTAssertEqual(result.imported, ["flat-skill.md"])
        let registry = SkillRegistry(
            roots: [.init(source: .user, baseURL: userRoot)])
        XCTAssertEqual(registry.snapshot().summaries.first?.name, "flat-skill")
    }

    func testImportSameNameSkipped() throws {
        let sourceRoot = workDir.appendingPathComponent("src", isDirectory: true)
        try makeSkill(sourceRoot, "dup")
        let userRoot = workDir.appendingPathComponent("dest", isDirectory: true)
        try makeSkill(userRoot, "dup")  // 预置同名（旧内容）

        let result = SkillImporter.importItems(
            at: [sourceRoot.appendingPathComponent("dup")], into: userRoot)
        XCTAssertEqual(result.skipped, ["dup"])
        XCTAssertTrue(result.imported.isEmpty)
        // 旧内容未被覆盖（同名跳过语义）。
        let old = try String(contentsOf: userRoot
            .appendingPathComponent("dup")
            .appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertTrue(old.contains("test skill"))
    }

    func testImportNonMarkdownRejected() throws {
        let sourceRoot = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot,
                                                withIntermediateDirectories: true)
        let stray = sourceRoot.appendingPathComponent("notes.txt")
        try "hello".write(to: stray, atomically: true, encoding: .utf8)
        let userRoot = workDir.appendingPathComponent("dest", isDirectory: true)

        let result = SkillImporter.importItems(at: [stray], into: userRoot)
        XCTAssertEqual(result.failed, ["notes.txt"])
        XCTAssertTrue(result.imported.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testImportBatchMixed() throws {
        // 批量统一逐项路径：目录 + 平铺 + 拒收混选。
        let sourceRoot = workDir.appendingPathComponent("src", isDirectory: true)
        try makeSkill(sourceRoot, "batch-a")
        let flat = sourceRoot.appendingPathComponent("batch-b.md")
        try "---\nname: batch-b\ndescription: d\n---\nB."
            .write(to: flat, atomically: true, encoding: .utf8)
        let stray = sourceRoot.appendingPathComponent("x.txt")
        try "n".write(to: stray, atomically: true, encoding: .utf8)
        let userRoot = workDir.appendingPathComponent("dest", isDirectory: true)

        let result = SkillImporter.importItems(
            at: [sourceRoot.appendingPathComponent("batch-a"), flat, stray],
            into: userRoot)
        XCTAssertEqual(result.imported, ["batch-a", "batch-b.md"])
        XCTAssertEqual(result.failed, ["x.txt"])
    }
}
