//
//  WorkspaceAdoptionTests.swift
//  WanWoTests
//
//  【工作区模型修正测试 · 添加工作区=iSH 内建项目目录】：
//    · sanitizeName 清洗矩阵（trim / 闭集外替换 - / 空・"."・".." 拒绝）；
//    · guestPath 形状（/var/wanwo/projects/<名字>）；
//    · projectsHostRoot 映射（dataPath/<guest>；非项目路径 fail closed）；
//    · ensureProjectDirectory 建目录 + 幂等（复用不报错、不重建）；
//    · adopt 幂等语义的目录半边（registry.create 幂等已由
//      WorkspaceRegistryTests 覆盖；AppEnvironment 级集成面因测试宿主会
//      触发内核 boot Task，不做单测——遗留项报告登记）。
//

import XCTest
@testable import WanWo

final class WorkspaceAdoptionTests: XCTestCase {

    // MARK: - 清洗矩阵

    func testSanitizeNameTrimsAndKeepsClosedSet() {
        XCTAssertEqual(WorkspaceAdoption.sanitizeName("  我的项目  "), "我的项目")
        XCTAssertEqual(WorkspaceAdoption.sanitizeName("abc-123_X.Y"), "abc-123_X.Y")
        XCTAssertEqual(WorkspaceAdoption.sanitizeName("中文 ABC"), "中文-ABC")
    }

    func testSanitizeNameReplacesOutsideCharacters() {
        XCTAssertEqual(WorkspaceAdoption.sanitizeName("my project!"), "my-project-")
        XCTAssertEqual(WorkspaceAdoption.sanitizeName("a/b\\c:d"), "a-b-c-d")
        XCTAssertEqual(WorkspaceAdoption.sanitizeName("tab\there"), "tab-here")
    }

    func testSanitizeNameRejectsEmptyAndDotForms() {
        XCTAssertNil(WorkspaceAdoption.sanitizeName(""))
        XCTAssertNil(WorkspaceAdoption.sanitizeName("   "))
        XCTAssertNil(WorkspaceAdoption.sanitizeName("///"))
        XCTAssertNil(WorkspaceAdoption.sanitizeName("."))
        XCTAssertNil(WorkspaceAdoption.sanitizeName(".."))
        XCTAssertNil(WorkspaceAdoption.sanitizeName(" / . / "))
    }

    // MARK: - 路径派生

    func testGuestPathShape() {
        XCTAssertEqual(WorkspaceAdoption.guestPath(for: "demo"),
                       "/var/wanwo/projects/demo")
    }

    func testIsProjectsGuestPath() {
        XCTAssertTrue(WanWoPaths.isProjectsGuestPath("/var/wanwo/projects"))
        XCTAssertTrue(WanWoPaths.isProjectsGuestPath("/var/wanwo/projects/demo"))
        XCTAssertTrue(WanWoPaths.isProjectsGuestPath("/var/wanwo/projects/demo/sub"))
        XCTAssertFalse(WanWoPaths.isProjectsGuestPath("/var/wanwo/projectsX"))
        XCTAssertFalse(WanWoPaths.isProjectsGuestPath("/var/wanwo/workspace"))
        XCTAssertFalse(WanWoPaths.isProjectsGuestPath("/var/wanwo"))
    }

    func testProjectsHostRootMapsToFakefsDataLayer() {
        let host = WanWoPaths.projectsHostRoot(forGuestPath: "/var/wanwo/projects/demo")
        XCTAssertEqual(
            host?.path,
            RootfsInstaller.shared.dataPath
                .appendingPathComponent("var/wanwo/projects/demo", isDirectory: true).path)
        // 非项目路径 fail closed。
        XCTAssertNil(WanWoPaths.projectsHostRoot(forGuestPath: "/var/wanwo/workspace"))
        XCTAssertNil(WanWoPaths.projectsHostRoot(forGuestPath: "relative/path"))
    }

    // MARK: - 建目录 + 幂等（fakefs 持久层真实目录）

    /// 测试脚手架：dataPath + .arch 标签（isInstalled 判定面——见
    /// ensureProjectDirectory 的 rootfsNotReady 守卫）。
    private var createdScaffolding = false

    override func setUp() async throws {
        createdScaffolding = false
        if !RootfsInstaller.shared.isInstalled {
            try FileManager.default.createDirectory(
                at: RootfsInstaller.shared.dataPath,
                withIntermediateDirectories: true)
            // .arch 标签（RootfsInstaller.archTagPath 为 private——同形状构造）。
            try "aarch64".write(
                to: RootfsInstaller.shared.rootfsPath
                    .appendingPathComponent(".arch"), atomically: true,
                encoding: .utf8)
            createdScaffolding = true
        }
    }

    override func tearDown() async throws {
        // 清理测试项目目录（仅本测试创建的 projects 子树）。
        let projectsRoot = RootfsInstaller.shared.dataPath
            .appendingPathComponent("var/wanwo/projects", isDirectory: true)
        try? FileManager.default.removeItem(at: projectsRoot)
        if createdScaffolding {
            try? FileManager.default.removeItem(at: RootfsInstaller.shared.rootfsPath)
        }
    }

    func testEnsureProjectDirectoryCreatesRealDirectoryIdempotently() throws {
        let cleaned = try XCTUnwrap(WorkspaceAdoption.sanitizeName("测试项目"))
        let guestPath = WorkspaceAdoption.guestPath(for: cleaned)

        try WorkspaceAdoption.ensureProjectDirectory(cleanedName: cleaned)
        let host = try XCTUnwrap(WanWoPaths.projectsHostRoot(forGuestPath: guestPath))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.path,
                                                     isDirectory: &isDir),
                      "项目目录必须在 fakefs 持久层真实存在")
        XCTAssertTrue(isDir.boolValue)

        // 幂等：重复调用不报错、目录复用（同一路径仍是目录）。
        try WorkspaceAdoption.ensureProjectDirectory(cleanedName: cleaned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.path,
                                                     isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testEnsureProjectDirectoryThrowsWhenRootfsMissing() throws {
        guard !createdScaffolding else {
            // 宿主真有 rootfs（isInstalled 原生为真）——本用例守卫不可达，跳过。
            throw XCTSkip("rootfs 已安装，rootfsNotReady 守卫不可达")
        }
        // 拆掉脚手架触发守卫。
        try FileManager.default.removeItem(at: RootfsInstaller.shared.rootfsPath)
        XCTAssertThrowsError(
            try WorkspaceAdoption.ensureProjectDirectory(cleanedName: "demo")
        ) { error in
            XCTAssertEqual(error as? WorkspaceAdoption.AddError,
                           .rootfsNotReady)
        }
    }
}
