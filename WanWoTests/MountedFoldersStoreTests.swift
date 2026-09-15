//
//  MountedFoldersStoreTests.swift
//  WanWoTests
//
//  【M6.4（B3）测试 · 外挂载存储面】MountedFolderEntry Codable 往返（旧版字段
//  缺省兼容）/ isValidMountName 校验矩阵 / MountedFoldersManager 注入 storeURL
//  的持久化往返 + 名称唯一性校验（真机 FS fixture——临时目录；书签/探测走
//  NSFileCoordinator 真实通道）/ probeWritable 判定（可写目录成功、不存在目录
//  coordinate 失败→false）。
//

import XCTest
@testable import WanWo

final class MountedFoldersStoreTests: XCTestCase {

    // MARK: - fixture

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m6-mounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeEntry(name: String = "vault",
                           isWritable: Bool = true,
                           userAllowWrite: Bool = true) -> MountedFolderEntry {
        MountedFolderEntry(
            id: UUID(), name: name,
            sourceDisplayName: "obsidian › Documents",
            bookmark: Data([0x62, 0x6f, 0x6f, 0x6b]),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isWritable: isWritable, userAllowWrite: userAllowWrite)
    }

    // MARK: - Codable 往返

    func testEntryCodableRoundtripPreservesAllFields() throws {
        let entry = makeEntry(isWritable: false, userAllowWrite: false)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(MountedFolderEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }

    /// 旧版条目（isWritable/userAllowWrite 字段出现前）解码缺省 true——既有挂载
    /// 升级后继续可用（原件兼容语义）。
    func testEntryDecodingDefaultsNewFieldsToTrue() throws {
        let legacyJSON = """
        {
          "id": "C65A1B37-0000-4000-8000-AAAAAAAAAAAA",
          "name": "vault",
          "sourceDisplayName": "obsidian",
          "bookmark": "Ym9vaw==",
          "createdAt": 1700000000
        }
        """
        let decoded = try JSONDecoder().decode(
            MountedFolderEntry.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.isWritable)
        XCTAssertTrue(decoded.userAllowWrite)
        XCTAssertTrue(decoded.effectiveWritable)
    }

    /// effectiveWritable 双层开关（事故纪律②）：OS 层 ∧ 用户意图。
    func testEffectiveWritableIsTwoLayerSwitch() {
        XCTAssertTrue(makeEntry(isWritable: true, userAllowWrite: true).effectiveWritable)
        XCTAssertFalse(makeEntry(isWritable: false, userAllowWrite: true).effectiveWritable)
        XCTAssertFalse(makeEntry(isWritable: true, userAllowWrite: false).effectiveWritable)
        XCTAssertFalse(makeEntry(isWritable: false, userAllowWrite: false).effectiveWritable)
    }

    // MARK: - 名称校验矩阵

    func testIsValidMountNameMatrix() {
        XCTAssertTrue(MountedFolderEntry.isValidMountName("vault"))
        XCTAssertTrue(MountedFolderEntry.isValidMountName("  vault  ")) // trim 后有效
        XCTAssertFalse(MountedFolderEntry.isValidMountName(""))
        XCTAssertFalse(MountedFolderEntry.isValidMountName("   "))
        XCTAssertFalse(MountedFolderEntry.isValidMountName("."))
        XCTAssertFalse(MountedFolderEntry.isValidMountName(".."))
        XCTAssertFalse(MountedFolderEntry.isValidMountName("a/b"))
        XCTAssertFalse(MountedFolderEntry.isValidMountName("a\0b"))
    }

    // MARK: - Manager 持久化往返（注入 storeURL）

    /// add → 新 manager 同 storeURL 加载：条目完整往返（书签/名称/双层写开关）。
    @MainActor
    func testManagerStoreRoundtripViaInjectedStoreURL() throws {
        let storeURL = workDir.appendingPathComponent("mounted-folders.json")
        let sourceDir = workDir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let manager = MountedFoldersManager(storeURL: storeURL)
        let added = try manager.add(pickedURL: sourceDir, customName: "  vault  ",
                                    userAllowWrite: false)
        XCTAssertEqual(added.name, "vault")
        XCTAssertFalse(added.userAllowWrite)
        // probeWritable 在真实临时目录上应判可写。
        XCTAssertTrue(added.isWritable)
        XCTAssertEqual(manager.entries.count, 1)

        // 二次 manager（同存储）= 重启加载路径。
        let reloaded = MountedFoldersManager(storeURL: storeURL)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.id, added.id)
        XCTAssertEqual(reloaded.entries.first?.name, "vault")
        XCTAssertEqual(reloaded.entries.first?.bookmark, added.bookmark)
        XCTAssertFalse(reloaded.entries.first!.userAllowWrite)

        // 名称唯一性（含 excludingId 例外）。
        XCTAssertFalse(manager.isNameAvailable("vault"))
        XCTAssertTrue(manager.isNameAvailable("vault", excludingId: added.id))
        // 重名校验先于书签面——nameTaken 在 add 抛出。
        XCTAssertThrowsError(try manager.add(pickedURL: sourceDir,
                                             customName: "vault",
                                             userAllowWrite: true)) { error in
            guard case MountedFoldersManager.AddError.nameTaken = error else {
                return XCTFail("expected nameTaken, got \(error)")
            }
        }
    }

    @MainActor
    func testManagerRenameValidationAndPersistedEffect() throws {
        let storeURL = workDir.appendingPathComponent("mounted-folders.json")
        let sourceDir = workDir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let manager = MountedFoldersManager(storeURL: storeURL)
        let added = try manager.add(pickedURL: sourceDir, customName: "old",
                                    userAllowWrite: true)
        // 非法名 / 重名拒绝（校验先于任何写）。
        XCTAssertThrowsError(try manager.rename(id: added.id, to: "../escape"))
        XCTAssertThrowsError(try manager.rename(id: added.id, to: "old"))
        // 合法重命名持久化。
        try manager.rename(id: added.id, to: "new")
        XCTAssertEqual(MountedFoldersManager(storeURL: storeURL).entries.first?.name, "new")
    }

    @MainActor
    func testManagerRemovePersistsDeletion() throws {
        let storeURL = workDir.appendingPathComponent("mounted-folders.json")
        let sourceDir = workDir.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let manager = MountedFoldersManager(storeURL: storeURL)
        let added = try manager.add(pickedURL: sourceDir, customName: "gone",
                                    userAllowWrite: true)
        manager.remove(id: added.id)
        XCTAssertTrue(manager.entries.isEmpty)
        XCTAssertTrue(MountedFoldersManager(storeURL: storeURL).entries.isEmpty)
    }

    // MARK: - probeWritable 判定

    func testProbeWritablePositiveOnRealDirectory() {
        let dir = workDir.appendingPathComponent("probe-ok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(MountedFoldersManager.probeWritable(at: dir))
        // 探测不留残留 probe 文件。
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testProbeWritableNegativeOnMissingDirectory() {
        let missing = workDir.appendingPathComponent("no-such-dir", isDirectory: true)
        XCTAssertFalse(MountedFoldersManager.probeWritable(at: missing))
    }

    // MARK: - 默认挂载名建议（iCloud Documents 反推）

    func testDefaultMountNameFromiCloudDocuments() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/"
            + "iCloud~com~nssurge~inc/Documents")
        XCTAssertEqual(MountedFoldersSettingsView.defaultMountName(for: url), "nssurge")
    }

    func testDefaultMountNamePlainFolder() {
        let url = URL(fileURLWithPath: "/tmp/My Vault")
        XCTAssertEqual(MountedFoldersSettingsView.defaultMountName(for: url), "My Vault")
    }

    // MARK: - humanReadableSourceName（iCloud 面包屑）

    func testHumanReadableSourceNameBreadcrumb() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/"
            + "iCloud~md~obsidian/Documents/vault")
        XCTAssertEqual(MountedFoldersManager.humanReadableSourceName(for: url),
                       "obsidian › Documents › vault")
    }
}
