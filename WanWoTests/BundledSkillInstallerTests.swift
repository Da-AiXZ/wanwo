//
//  BundledSkillInstallerTests.swift
//  WanWoTests
//
//  【M4-D 件 D2 附属测试】bundled 指纹 marker 幂等安装：指纹确定性/幂等
//  （marker 匹配→零改动）/版本升级（清子目录重写+陈旧条目清除）/空集收敛/
//  目录直读重载。codex lib.rs marker 思路 + OpenMinis installBundledSkills
//  参照（简报环 11）。
//

import XCTest
@testable import WanWo

final class BundledSkillInstallerTests: XCTestCase {

    private var tempBase: URL!

    override func setUpWithError() throws {
        tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-skills-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempBase)
    }

    // MARK: fixture

    private func files(_ entries: [(String, String)]) -> [BundledSkillFile] {
        entries.map { BundledSkillFile(relativePath: $0.0, data: Data($0.1.utf8)) }
    }

    private var target: URL {
        tempBase.appendingPathComponent(".bundled", isDirectory: true)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: target.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: 指纹

    func testFingerprintIsOrderIndependentDeterministicAndContentSensitive() {
        let a = files([("x/SKILL.md", "one"), ("y/SKILL.md", "two")])
        let b = files([("y/SKILL.md", "two"), ("x/SKILL.md", "one")])
        // 输入序无关 + 确定性
        XCTAssertEqual(BundledSkillInstaller.fingerprint(a),
                       BundledSkillInstaller.fingerprint(b))
        // 内容/路径敏感
        let changed = files([("x/SKILL.md", "changed"), ("y/SKILL.md", "two")])
        XCTAssertNotEqual(BundledSkillInstaller.fingerprint(a),
                          BundledSkillInstaller.fingerprint(changed))
        let renamed = files([("x/SKILL.md", "one"), ("z/SKILL.md", "two")])
        XCTAssertNotEqual(BundledSkillInstaller.fingerprint(a),
                          BundledSkillInstaller.fingerprint(renamed))
    }

    // MARK: 幂等（marker 为安装态唯一真相——外部漂移不修复，登记语义）

    func testInstallIsIdempotentMarkerMatchesNoRewrite() throws {
        let bundle = files([("hello-wanwo/SKILL.md",
                             "---\nname: hello-wanwo\ndescription: hi\n---\n")])
        try BundledSkillInstaller.install(files: bundle, targetRoot: target)

        let marker = try read(".install-marker")
        XCTAssertEqual(marker, BundledSkillInstaller.fingerprint(bundle))
        XCTAssertEqual(try read("hello-wanwo/SKILL.md"),
                       "---\nname: hello-wanwo\ndescription: hi\n---\n")

        // 二次安装：指纹匹配 → 零改动（漂移的文件不被重写）
        try "drift".write(to: target.appendingPathComponent("hello-wanwo/SKILL.md"),
                          atomically: true, encoding: .utf8)
        try BundledSkillInstaller.install(files: bundle, targetRoot: target)
        XCTAssertEqual(try read("hello-wanwo/SKILL.md"), "drift")
        XCTAssertEqual(try read(".install-marker"), marker)
    }

    // MARK: 版本升级 = 指纹不匹配 → 清子目录重写

    func testUpgradeWipesStaleEntriesAndRewrites() throws {
        let v1 = files([("alpha/SKILL.md", "a"), ("beta/SKILL.md", "b")])
        try BundledSkillInstaller.install(files: v1, targetRoot: target)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("alpha").path))

        let v2 = files([("beta/SKILL.md", "b2")])
        try BundledSkillInstaller.install(files: v2, targetRoot: target)

        // 陈旧条目清除 + 内容更新 + marker 换新
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("alpha").path))
        XCTAssertEqual(try read("beta/SKILL.md"), "b2")
        XCTAssertEqual(try read(".install-marker"),
                       BundledSkillInstaller.fingerprint(v2))
    }

    // MARK: 空集收敛（升级到无预装 = 整目录移除）

    func testEmptyFilesWipesTarget() throws {
        try BundledSkillInstaller.install(files: files([("a/SKILL.md", "x")]),
                                          targetRoot: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        try BundledSkillInstaller.install(files: [], targetRoot: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: 目录直读重载（测试注入面；生产走 Bundle folder reference）

    func testBundledFilesInDirectoryReadsRelativePaths() throws {
        let folder = tempBase.appendingPathComponent("bundled-skills",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("hello-wanwo"),
            withIntermediateDirectories: true)
        try Data("one".utf8).write(
            to: folder.appendingPathComponent("hello-wanwo/SKILL.md"))
        try Data("two".utf8).write(
            to: folder.appendingPathComponent("hello-wanwo/notes.md"))

        let loaded = BundledSkillInstaller.bundledFiles(in: folder)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.relativePath)),
                       ["hello-wanwo/SKILL.md", "hello-wanwo/notes.md"])
        XCTAssertTrue(loaded.allSatisfy { !$0.data.isEmpty })
    }
}
