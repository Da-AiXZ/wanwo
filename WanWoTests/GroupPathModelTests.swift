//
//  GroupPathModelTests.swift
//  WanWoTests
//
//  【M4-E+ P2 测试 · 会话四桶分组维度化】路径形状断言：
//    · sessionPersistentDir 新形状 persistentBase/groups/<gid>/<sid>/<bucket>
//      （四桶 × 默认分组 + 显式 groupID 覆盖）
//    · GroupStore 薄壳转发与 WanWoPaths 同源（单一事实源去重保证）
//    · 三调用方自动跟随（AttachmentStore.root / WorkspaceFileAccess.rootURL /
//      技能 project 根同源派生）
//    · FsContextRouter.hostURL 正向路由到分组维度桶（含嵌套 tail/前缀边界/
//      全局桶不路由）
//    · 迁移器目标形状与新 sessionPersistentDir 一致（零改动验证口径）
//

import XCTest
@testable import WanWo

final class GroupPathModelTests: XCTestCase {

    private var testSID: String!

    override func setUp() async throws {
        testSID = "pathmodel-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        // 清理真实 persistentBase 下的测试 sid 残留（调用方 init 会建目录）。
        try? FileManager.default.removeItem(
            at: WanWoPaths.groupRoot(base: WanWoPaths.persistentBase,
                                     groupID: WanWoPaths.defaultGroupID)
                .appendingPathComponent(testSID, isDirectory: true))
    }

    // MARK: sessionPersistentDir 新形状（brief §5.2）

    func testSessionPersistentDirGroupedShape() {
        let base = WanWoPaths.persistentBase
        for bucket in WanWoPaths.knownSessionBuckets {
            XCTAssertEqual(
                WanWoPaths.sessionPersistentDir(for: testSID, bucket: bucket).path,
                base.appendingPathComponent("groups", isDirectory: true)
                    .appendingPathComponent(WanWoPaths.defaultGroupID, isDirectory: true)
                    .appendingPathComponent(testSID, isDirectory: true)
                    .appendingPathComponent(bucket, isDirectory: true).path,
                bucket)
        }
        // 显式 groupID 覆盖（M9 多分组前的签名就绪面）。
        XCTAssertEqual(
            WanWoPaths.sessionPersistentDir(for: testSID, bucket: "workspace",
                                            groupID: "proj-a").path,
            base.appendingPathComponent("groups", isDirectory: true)
                .appendingPathComponent("proj-a", isDirectory: true)
                .appendingPathComponent(testSID, isDirectory: true)
                .appendingPathComponent("workspace", isDirectory: true).path)
    }

    // MARK: GroupStore 薄壳转发同源（去重保证）

    func testGroupStoreShellDelegatesToWanWoPaths() {
        XCTAssertEqual(GroupStore.defaultGroupID, WanWoPaths.defaultGroupID)
        XCTAssertEqual(GroupStore.defaultGroupName, WanWoPaths.defaultGroupName)
        XCTAssertEqual(GroupStore.knownBuckets, WanWoPaths.knownSessionBuckets)
        let workBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpm-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(GroupStore.groupRoot(base: workBase, groupID: "g").path,
                       WanWoPaths.groupRoot(base: workBase, groupID: "g").path)
        XCTAssertEqual(
            GroupStore.groupSessionsRoot(base: workBase, groupID: "g").path,
            WanWoPaths.groupSessionsRoot(base: workBase, groupID: "g").path)
    }

    // MARK: 三调用方自动跟随（默认参数零改动跟随新形状）

    func testCallersFollowGroupedShape() {
        // AttachmentStore（锚点 AttachmentStore.swift:77）。
        XCTAssertEqual(
            AttachmentStore(sessionId: testSID).root.path,
            WanWoPaths.sessionPersistentDir(for: testSID, bucket: "attachments").path)
        // WorkspaceFileAccess（锚点 WorkspaceFileAccess.swift:45）。
        XCTAssertEqual(
            WorkspaceFileAccess(sessionId: testSID).rootURL.path,
            WanWoPaths.sessionPersistentDir(for: testSID, bucket: "workspace").path)
        // 技能 project 根（锚点 AppEnvironment.swift:431 同源派生，P3 升格前过渡态）。
        XCTAssertEqual(
            WanWoPaths.sessionPersistentDir(for: testSID, bucket: "workspace")
                .appendingPathComponent(".agents/skills", isDirectory: true).path,
            WanWoPaths.groupRoot(base: WanWoPaths.persistentBase,
                                 groupID: WanWoPaths.defaultGroupID)
                .appendingPathComponent(testSID, isDirectory: true)
                .appendingPathComponent("workspace", isDirectory: true)
                .appendingPathComponent(".agents/skills", isDirectory: true).path)
    }

    // MARK: FsContextRouter 正向路由到分组维度桶

    func testFsContextRouterForwardRoutesToGroupedBucket() {
        let router = FsContextRouter.shared
        // 四桶全部路由（嵌套 tail 保真）。
        for bucket in WanWoPaths.knownSessionBuckets {
            let url = router.hostURL(forGuest: "/var/wanwo/\(bucket)/a/b/c.txt",
                                     sid: testSID)
            XCTAssertEqual(
                url?.path,
                WanWoPaths.sessionPersistentDir(for: testSID, bucket: bucket)
                    .appendingPathComponent("a/b/c.txt").path,
                bucket)
        }
        // 前缀边界：workspaceX 不是 workspace（锚点 :105 边界判定语义保留）。
        XCTAssertNil(router.hostURL(forGuest: "/var/wanwo/workspaceX/a",
                                    sid: testSID))
        // 全局桶不路由（memory/skills/shared 落静态挂载表）。
        XCTAssertNil(router.hostURL(forGuest: "/var/wanwo/memory/x", sid: testSID))
        XCTAssertNil(router.hostURL(forGuest: "/var/wanwo/skills/x", sid: testSID))
    }

    // MARK: 迁移器目标形状与新 sessionPersistentDir 一致（零改动验证口径）

    func testMigratorTargetShapeMatchesSessionPersistentDir() {
        for bucket in WanWoPaths.knownSessionBuckets {
            XCTAssertEqual(
                WanWoPaths.sessionPersistentDir(for: testSID, bucket: bucket).path,
                GroupStore.groupRoot(base: WanWoPaths.persistentBase,
                                     groupID: GroupStore.defaultGroupID)
                    .appendingPathComponent(testSID, isDirectory: true)
                    .appendingPathComponent(bucket, isDirectory: true).path,
                bucket)
        }
    }
}
