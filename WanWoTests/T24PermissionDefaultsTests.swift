//
//  T24PermissionDefaultsTests.swift
//  WanWoTests
//
//  【T2.4 P1-4 · 回归测试】设置·新会话默认权限行即时刷新机制：
//  PermissionDefaultStore.setDefault → objectWillChange 广播 → 订阅方
//  （PermissionDefaultsView @ObservedObject）即时联动（dsh PermissionRow
//  读 host settings 响应式，settings-store.ts:131-161 select() 写入即广播）。
//

import Combine
import XCTest
@testable import WanWo

final class T24PermissionDefaultsTests: XCTestCase {

    @MainActor
    func testSetDefaultPublishesAndPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("t24-pd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("defaults.json")
        let store = PermissionDefaultStore(fileURL: fileURL)
        XCTAssertEqual(store.defaultPreset, PermissionDefaultStore.fallbackPreset)

        // 订阅 objectWillChange：写入口必须广播（视图即时刷新的机制面）。
        var changeCount = 0
        let cancellable = store.objectWillChange.sink { changeCount += 1 }

        XCTAssertTrue(store.setDefault(named: "read-only"))
        XCTAssertEqual(store.defaultPreset, "read-only")
        XCTAssertEqual(changeCount, 1)

        // 同值写入仍广播（幂等写由调用方挡——dsh onSelect :78-87 同值直接返回；
        // store 层不挡，广播无害）。
        _ = store.setDefault(named: "read-only")
        XCTAssertEqual(changeCount, 2)

        // 非法名拒绝：零副作用、零广播（fail closed）。
        XCTAssertFalse(store.setDefault(named: "nonexistent-preset"))
        XCTAssertEqual(store.defaultPreset, "read-only")
        XCTAssertEqual(changeCount, 2)

        // 持久化：新实例读回写入值。
        let reloaded = PermissionDefaultStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.defaultPreset, "read-only")

        cancellable.cancel()
    }

    /// 后台读侧线程模型不回归：newSessionKnobs 从非主线程读折叠值
    /// （PermissionCoordinator 的 @Sendable newSessionDefaults 缝）。
    func testNewSessionKnobsReadableOffMain() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("t24-pd-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PermissionDefaultStore(fileURL: dir.appendingPathComponent("d.json"))
        let knobs = await Task.detached {
            store.newSessionKnobs()
        }.value
        XCTAssertEqual(knobs.sandbox, .workspaceWrite)
        XCTAssertEqual(knobs.approval, .ask)
    }
}
