//
//  T24ModelSelectionTests.swift
//  WanWoTests
//
//  【T2.4 P1-3 · 回归测试】会话级模型选择：值宿主隔离性（per-session 语义）
//  + EndpointStore.resolve(selection:) 解析覆盖（会话选择优先/缺省回落/
//  effort 覆盖端点级废弃字段/失效端点回落）。
//

import XCTest
@testable import WanWo

final class T24ModelSelectionTests: XCTestCase {

    // MARK: - 值宿主隔离（dsh ModelSelect state.current per-session 语义）

    @MainActor
    func testSessionModelSelectionHolderIsolation() {
        let a = SessionModelSelection()
        let b = SessionModelSelection()
        XCTAssertNil(a.get())
        XCTAssertNil(b.get())
        let idA = UUID()
        a.set(.init(endpointID: idA, reasoningEffort: "high"))
        // 会话隔离：a 的选择不泄漏到 b。
        XCTAssertEqual(a.get(), .init(endpointID: idA, reasoningEffort: "high"))
        XCTAssertNil(b.get())
        // b 独立选择 + a 覆盖写。
        let idB = UUID()
        b.set(.init(endpointID: idB, reasoningEffort: nil))
        a.set(.init(endpointID: idA, reasoningEffort: "off"))
        XCTAssertEqual(b.get()?.endpointID, idB)
        XCTAssertEqual(a.get()?.reasoningEffort, "off")
    }

    // MARK: - EndpointStore.resolve(selection:)

    @MainActor
    func testResolveSelectionOverridesEndpointLevelEffort() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("t24-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EndpointStore(
            fileURL: dir.appendingPathComponent("endpoints.json"))
        // 出厂播种默认端点（init 文件缺失时播种——M3 有意演进）为目录基线。
        let seeded = store.endpoints[0]
        let first = EndpointConfig(name: "DeepSeek",
                                   baseURL: "https://api.deepseek.com",
                                   model: "deepseek-v4-flash",
                                   reasoningEffort: "high") // 旧端点级值（废弃）
        let second = EndpointConfig(name: "Other",
                                    baseURL: "https://other.example",
                                    model: "other-model")
        store.add(first)
        store.add(second)

        // 无选择 → 活动端点（首启用项 = 播种默认端点）。
        XCTAssertEqual(store.resolve(selection: nil)?.id, seeded.id)
        // 会话选择 second → 解析为 second 且 effort=provider default（nil）。
        let plain = store.resolve(selection: .init(endpointID: second.id,
                                                   reasoningEffort: nil))
        XCTAssertEqual(plain?.id, second.id)
        XCTAssertNil(plain?.reasoningEffort)
        // 会话 effort 覆盖端点级废弃字段（first 的 "high" 不再生效）。
        let overridden = store.resolve(selection: .init(endpointID: first.id,
                                                        reasoningEffort: "low"))
        XCTAssertEqual(overridden?.id, first.id)
        XCTAssertEqual(overridden?.reasoningEffort, "low")
    }

    @MainActor
    func testResolveFallsBackWhenSelectedEndpointMissingOrDisabled() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("t24-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EndpointStore(
            fileURL: dir.appendingPathComponent("endpoints.json"))
        // 出厂播种默认端点（init 文件缺失时播种——M3 有意演进）为目录基线。
        let seeded = store.endpoints[0]
        let only = EndpointConfig(name: "DeepSeek",
                                  baseURL: "https://api.deepseek.com",
                                  model: "deepseek-v4-flash")
        store.add(only)
        // 选择指向不存在的端点 → 回落活动端点（首启用项 = 播种默认端点）。
        XCTAssertEqual(store.resolve(selection: .init(endpointID: UUID(),
                                                      reasoningEffort: "low"))?.id,
                       seeded.id)
        // 选择指向已停用的端点 → 回落活动端点（仍是可用的播种默认端点）。
        store.setEnabled(false, for: only)
        XCTAssertEqual(store.resolve(selection: .init(endpointID: only.id,
                                                      reasoningEffort: nil))?.id,
                       seeded.id)
        // 可用目录全空（播种默认也停用）→ nil（fail closed 到空）。
        store.setEnabled(false, for: seeded)
        XCTAssertNil(store.resolve(selection: nil))
    }
}
