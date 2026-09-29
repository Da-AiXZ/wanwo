//
//  CredentialStoreTests.swift
//  WanWoTests
//
//  【M8 批1 件A2 · 单测】CredentialStore 语义：describe/set/unset/configured
//  （读视图永不含值）。后端 = 内存 fake（协议注入；禁真 Keychain 依赖——
//  CI 修 21/23 血训）。纯同步断言、无竞态构造、无重试循环。
//


import XCTest
@testable import WanWo

/// 内存 fake 后端（协议注入；不触 SecItem）。
private final class FakeCredentialBackend: CredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    var sourceName = "fake"
    /// 写失败注入（dsh credential/rejected 面的本地形态）。
    var failWrites = false

    func readValue(_ ref: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[ref]
    }

    func writeValue(_ ref: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites {
            throw CredentialStoreError(message: "backend refused write")
        }
        storage[ref] = value
    }

    func deleteValue(_ ref: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: ref)
    }
}

final class CredentialStoreTests: XCTestCase {

    private func makeStore() -> (CredentialStore, FakeCredentialBackend) {
        let backend = FakeCredentialBackend()
        return (CredentialStore(backend: backend), backend)
    }

    // MARK: - describe（读视图永不含值；dsh credentials.ts:83-90）

    func testDescribeReportsConfiguredWithoutValue() {
        let (store, backend) = makeStore()
        // 未配置：configured=false、source=nil。
        var info = store.describe(refs: ["NOPE_API_KEY"])[0]
        XCTAssertEqual(info, CredentialInfo(configured: false, source: nil, writable: true))
        // 配置后：configured=true、source=后端标签；CredentialInfo 类型本身
        // 无 value 字段——读视图永不含值由类型形状保证（dsh projectCredentialInfo）。
        try? backend.writeValue("K_API_KEY", value: "sk-secret")
        info = store.describe(refs: ["K_API_KEY"])[0]
        XCTAssertEqual(info, CredentialInfo(configured: true, source: "fake", writable: true))
        // 批量：按 refs 顺序逐项回答。
        let batch = store.describe(refs: ["K_API_KEY", "ABSENT", "K_API_KEY"])
        XCTAssertEqual(batch.map(\.configured), [true, false, true])
    }

    // MARK: - set（空值拒绝 = dsh value.min(1)；覆盖写）

    func testSetStoresAndOverwrites() {
        let (store, backend) = makeStore()
        try? store.set(ref: "ROUTE_API_KEY", value: "first")
        XCTAssertEqual(backend.readValue("ROUTE_API_KEY"), "first")
        // 覆盖写（dsh provider set 语义——"输入新值可替换" 数据基础）。
        try? store.set(ref: "ROUTE_API_KEY", value: "second")
        XCTAssertEqual(backend.readValue("ROUTE_API_KEY"), "second")
    }

    func testSetRejectsEmptyValue() {
        let (store, backend) = makeStore()
        XCTAssertThrowsError(try store.set(ref: "ROUTE_API_KEY", value: "")) { error in
            let message = (error as? CredentialStoreError)?.message ?? ""
            XCTAssertTrue(message.contains("must not be empty"))
        }
        // 拒绝后未落任何值。
        XCTAssertNil(backend.readValue("ROUTE_API_KEY"))
    }

    // MARK: - unset（幂等；dsh credentials.ts:113-118）

    func testUnsetIsIdempotent() {
        let (store, _) = makeStore()
        try? store.set(ref: "ROUTE_API_KEY", value: "v")
        store.unset(ref: "ROUTE_API_KEY")
        XCTAssertFalse(store.describe(refs: ["ROUTE_API_KEY"])[0].configured)
        // 二次 unset 不抛不炸（不存在视为成功）。
        store.unset(ref: "ROUTE_API_KEY")
    }

    // MARK: - value(for:)（宿主内读值缝；dsh ctx.credentials.resolve 对拍）

    func testValueReadSeamAndEmptyTolerance() throws {
        let (store, backend) = makeStore()
        // 空（nil）与空串都读为 nil。
        XCTAssertNil(store.value(for: "A"))
        try backend.writeValue("A", value: "")
        XCTAssertNil(store.value(for: "A"))
        // 非空值正常返回（请求路径 bearer 数据源）。
        try store.set(ref: "A", value: "sk-key")
        XCTAssertEqual(store.value(for: "A"), "sk-key")
    }

    // MARK: - 写失败透传（dsh credential/rejected 承载面）

    func testSetSurfacesBackendRefusal() {
        let (store, backend) = makeStore()
        backend.failWrites = true
        XCTAssertThrowsError(try store.set(ref: "ROUTE_API_KEY", value: "v")) { error in
            let message = (error as? CredentialStoreError)?.message ?? ""
            XCTAssertTrue(message.contains("refused"))
        }
    }

    // MARK: - routeApiKeyRef（派生规则另见 ModelCatalogTests；此处覆盖组合消费）

    func testEndpointKeyRoundTripThroughStore() throws {
        let (store, _) = makeStore()
        let endpointID = UUID()
        let ref = CredentialStore.routeApiKeyRef(endpointID.uuidString)
        XCTAssertTrue(ref.hasSuffix("_API_KEY"))
        try store.set(ref: ref, value: "sk-test")
        XCTAssertEqual(store.value(for: ref), "sk-test")
        // describe 面确认已配置（EndpointStore.credentialConfigured 消费口径）。
        XCTAssertTrue(store.describe(refs: [ref])[0].configured)
    }

    // MARK: - unsetCredential 三清（M8 批1 增补；A2 删除流消费的 EndpointStore 缝）

    /// route ref 账目经 fake 后端实证三清主腿；旧 uuid 账目腿为 delete-only
    /// 幂等调用（SecItemDelete 对不存在项静默返回，不影响断言——测试正确性
    /// 不依赖 Keychain 行为，纪律口径内）；文件兜底腿由 setApiKey→unsetCredential
    /// 净零写删自证。
    @MainActor
    func testUnsetCredentialClearsRouteRefAccount() throws {
        let fake = FakeCredentialBackend()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8unset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EndpointStore(fileURL: dir.appendingPathComponent("endpoints.json"),
                                  credentialStore: CredentialStore(backend: fake))
        let endpoint = store.endpoints[0]
        let ref = CredentialStore.routeApiKeyRef(endpoint.id.uuidString)

        try store.setApiKey("sk-test", for: endpoint)
        XCTAssertTrue(store.credentialConfigured(for: endpoint))
        XCTAssertEqual(fake.readValue(ref), "sk-test")

        store.unsetCredential(for: endpoint)
        XCTAssertNil(fake.readValue(ref))
        XCTAssertFalse(store.credentialConfigured(for: endpoint))
        // 二次调用幂等（dsh removeCredential unset 幂等语义）。
        store.unsetCredential(for: endpoint)
        XCTAssertFalse(store.credentialConfigured(for: endpoint))
    }
}
