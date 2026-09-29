//
//  ModelCatalogTests.swift
//  WanWoTests
//
//  【M8 批1 件A1/A4 · 单测】模型目录解析链 + 校验 + 端点目录扩展 +
//  Compactor 65.5k 回归 + 探测解析。
//  测试纪律（CI 修 21/23）：纯同步函数断言、禁 async 竞态构造、禁闸门/
//  重试循环、临时目录唯一命名。
//


import XCTest
@testable import WanWo

final class ModelCatalogTests: XCTestCase {

    // MARK: - 解析链（dsh modelInfoFor：entry ?? 端点缺省 ?? 内置缺省）

    func testResolvedContextWindowChainOverrideInheritDefault() {
        // 条目显式窗口 = 覆盖（dsh configured?.contextWindow 优先）。
        let entry = ModelCatalogEntry(id: "m", contextWindow: 131_072)
        XCTAssertEqual(ModelCatalog.resolvedContextWindow(entry, defaultContextWindow: 262_144), 131_072)
        // 条目缺窗口 = 继承端点缺省。
        let bare = ModelCatalogEntry(id: "m")
        XCTAssertEqual(ModelCatalog.resolvedContextWindow(bare, defaultContextWindow: 262_144), 262_144)
        // 端点缺省也缺 = 内置 1_000_000（dsh DEFAULT_CONTEXT_WINDOW）。
        XCTAssertEqual(ModelCatalog.resolvedContextWindow(bare, defaultContextWindow: nil), 1_000_000)
        // 无条目（未登记模型）= 端点缺省兜底。
        XCTAssertEqual(ModelCatalog.resolvedContextWindow(nil, defaultContextWindow: 8_192), 8_192)
        XCTAssertEqual(ModelCatalog.resolvedContextWindow(nil, defaultContextWindow: nil), 1_000_000)
    }

    func testResolvedMaxTokensChain() {
        let entry = ModelCatalogEntry(id: "m", maxTokens: 8_192)
        XCTAssertEqual(ModelCatalog.resolvedMaxTokens(entry, defaultMaxTokens: 4_096), 8_192)
        XCTAssertEqual(ModelCatalog.resolvedMaxTokens(ModelCatalogEntry(id: "m"), defaultMaxTokens: 4_096), 4_096)
        XCTAssertEqual(ModelCatalog.resolvedMaxTokens(ModelCatalogEntry(id: "m"), defaultMaxTokens: nil), 256_000)
    }

    func testResolvedInfoExactIDMatchAndUncataloguedFallback() {
        var endpoint = EndpointConfig(name: "DS", baseURL: "https://api.example.com",
                                      model: "deepseek-v4-flash")
        endpoint.models = [
            ModelCatalogEntry(id: "deepseek-v4-pro", contextWindow: 131_072, maxTokens: 8_192),
            ModelCatalogEntry(id: "vision", name: "Vision", inputModalities: ["text", "image"]),
        ]
        endpoint.defaultContextWindow = 262_144
        endpoint.defaultMaxTokens = 4_096

        // 目录项精确 id 匹配 → 条目值。
        let pro = ModelCatalog.resolvedInfo(endpoint: endpoint, modelID: "deepseek-v4-pro")
        XCTAssertEqual(pro.contextWindow, 131_072)
        XCTAssertEqual(pro.defaultMaxTokens, 8_192)
        XCTAssertEqual(pro.inputModalities, ["text"])

        // 条目缺窗口 → 端点缺省。
        let vision = ModelCatalog.resolvedInfo(endpoint: endpoint, modelID: "vision")
        XCTAssertEqual(vision.contextWindow, 262_144)
        XCTAssertEqual(vision.inputModalities, ["text", "image"])

        // 未登记模型 → 端点缺省兜底 + text-only（dsh fail-closed 口径）。
        let unknown = ModelCatalog.resolvedInfo(endpoint: endpoint, modelID: "other-model")
        XCTAssertEqual(unknown.contextWindow, 262_144)
        XCTAssertEqual(unknown.defaultMaxTokens, 4_096)
        XCTAssertEqual(unknown.inputModalities, ["text"])
    }

    // MARK: - resolveModels 归一化（dsh resolveModels index.ts:214-280）

    func testResolveModelsRejectsDuplicateAfterTrim() {
        XCTAssertThrowsError(try ModelCatalog.resolveModels([
            ModelCatalogEntry(id: "model-a"),
            ModelCatalogEntry(id: "model-a "),
        ])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_ID_DUPLICATE")
        }
    }

    func testResolveModelsRejectsEmptyIDAndNameAndCapacities() {
        // 空 id。
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "   ")])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_ID_REQUIRED")
        }
        // 空 name。
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "m", name: "")])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_NAME_INVALID")
        }
        // 负/零窗口。
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "m", contextWindow: -1)])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_CONTEXT_INVALID")
        }
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "m", maxTokens: 0)])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_MAX_TOKENS_INVALID")
        }
        // 模态非法 / 空 / 重复。
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "m", inputModalities: ["audio"])])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_MODALITIES_INVALID")
        }
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "m", inputModalities: [])])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_MODALITIES_EMPTY")
        }
        XCTAssertThrowsError(try ModelCatalog.resolveModels([ModelCatalogEntry(id: "m", inputModalities: ["text", "text"])])) { error in
            XCTAssertEqual((error as? ModelCatalogResolveError)?.code, "MODEL_MODALITIES_DUPLICATE")
        }
    }

    func testResolveModelsDefaultsModalitiesAndReturnsTrimmedIDs() throws {
        let resolved = try ModelCatalog.resolveModels([
            ModelCatalogEntry(id: " model-a "),
            ModelCatalogEntry(id: "model-b", inputModalities: ["image", "text"]),
        ])
        XCTAssertEqual(resolved.map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(resolved[0].inputModalities, ["text"])
        XCTAssertEqual(resolved[1].inputModalities, ["image", "text"])
    }

    // MARK: - EndpointConfig 目录继承-override-重置（dsh DeepSeekModelsEditor 语义）

    func testEndpointCatalogInheritOverrideReset() {
        var endpoint = EndpointConfig(name: "DS", baseURL: "https://api.example.com",
                                      model: "deepseek-v4-flash")
        // 继承（nil）= 单模型行为（万我内置目录空集起步）。
        XCTAssertEqual(endpoint.catalogEntries().map(\.id), ["deepseek-v4-flash"])
        // override：目录生效。
        endpoint.models = [ModelCatalogEntry(id: "m1"), ModelCatalogEntry(id: "m2", name: "M2")]
        XCTAssertEqual(endpoint.catalogEntries().map(\.id), ["m1", "m2"])
        XCTAssertEqual(endpoint.catalogEntries()[1].name, "M2")
        // 重置：置回 nil = 回到继承（单模型现状）。
        endpoint.models = nil
        XCTAssertEqual(endpoint.catalogEntries().map(\.id), ["deepseek-v4-flash"])
        // 显式空数组 = 空目录 → 单模型兜底（dsh 空列表=serve installed 的万我形态）。
        endpoint.models = []
        XCTAssertEqual(endpoint.catalogEntries().map(\.id), ["deepseek-v4-flash"])
    }

    func testResolveSelectionAppliesModelOverride() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m8catalog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EndpointStore(fileURL: dir.appendingPathComponent("endpoints.json"))
        let endpoint = store.endpoints[0]
        store.update(EndpointConfig(
            id: endpoint.id, name: endpoint.name, baseURL: endpoint.baseURL,
            model: "deepseek-v4-flash",
            models: [ModelCatalogEntry(id: "deepseek-v4-pro", contextWindow: 131_072)]))

        // 会话级模型覆盖 → resolved.model 已切换（LlmCallConfig 消费源）。
        let resolved = store.resolve(selection: .init(
            endpointID: endpoint.id, reasoningEffort: nil, modelID: "deepseek-v4-pro"))
        XCTAssertEqual(resolved?.model, "deepseek-v4-pro")
        // modelID nil = 端点原模型。
        let plain = store.resolve(selection: .init(endpointID: endpoint.id, reasoningEffort: "high"))
        XCTAssertEqual(plain?.model, "deepseek-v4-flash")
        XCTAssertEqual(plain?.reasoningEffort, "high")
    }

    // MARK: - routeApiKeyRef（dsh store.ts:111-115 deriveKeyRef）

    func testRouteApiKeyRefDerivation() {
        XCTAssertEqual(CredentialStore.routeApiKeyRef("minimax-cn"), "MINIMAX_CN_API_KEY")
        // 非字母数字段折叠为单个 "_"。
        XCTAssertEqual(CredentialStore.routeApiKeyRef("a--b c"), "A_B_C_API_KEY")
        // UUID（连字符折叠；既有端点 id 迁移路径）。
        let ref = CredentialStore.routeApiKeyRef("8F4C2A1E-1111-2222-3333-444455556666")
        XCTAssertEqual(ref, "8F4C2A1E_1111_2222_3333_444455556666_API_KEY")
        // 空串 = 仅后缀（dsh deriveKeyRef 同式）。
        XCTAssertEqual(CredentialStore.routeApiKeyRef(""), "_API_KEY")
    }

    // MARK: - EndpointCatalogSnapshot + Compactor 65.5k 回归

    @MainActor
    func testSnapshotContextWindowExactMatchAndDefaultFallback() {
        var endpoint = EndpointConfig(name: "DS", baseURL: "https://api.example.com",
                                      model: "deepseek-v4-flash")
        endpoint.models = [ModelCatalogEntry(id: "deepseek-v4-pro", contextWindow: 131_072)]
        endpoint.defaultContextWindow = 262_144
        let snapshot = EndpointCatalogSnapshot()
        snapshot.replace([endpoint])

        // 目录项精确 id。
        XCTAssertEqual(snapshot.contextWindow(for: "deepseek-v4-pro", endpointID: endpoint.id), 131_072)
        // 未登记模型 → 端点缺省窗口（不再落 65_536——65.5k 根因修复）。
        XCTAssertEqual(snapshot.contextWindow(for: "deepseek-v4-flash", endpointID: endpoint.id), 262_144)
        XCTAssertEqual(snapshot.contextWindow(for: "whatever", endpointID: endpoint.id), 262_144)
        // 无连接限定：全目录精确扫描；未命中 = nil。
        XCTAssertEqual(snapshot.contextWindow(for: "deepseek-v4-pro", endpointID: nil), 131_072)
        XCTAssertNil(snapshot.contextWindow(for: "deepseek-v4-flash", endpointID: nil))
    }

    @MainActor
    func testSnapshotIgnoresPrefixMatches() {
        // 65.5k 根因回归：旧前缀 contains 语义（"deepseek-v4" 键命中
        // "deepseek-v4-pro"）必须失效——键只按精确 id 比较。
        var endpoint = EndpointConfig(name: "DS", baseURL: "https://api.example.com",
                                      model: "deepseek-v4-pro")
        endpoint.models = [ModelCatalogEntry(id: "deepseek-v4-pro-longer-name", contextWindow: 999)]
        let snapshot = EndpointCatalogSnapshot()
        snapshot.replace([endpoint])
        XCTAssertNil(snapshot.contextWindow(for: "deepseek-v4-pro", endpointID: nil))
        XCTAssertEqual(snapshot.contextWindow(for: "deepseek-v4-pro-longer-name", endpointID: nil), 999)
    }

    @MainActor
    func testCompactorWindowUsesInjectedResolverAndFallbackBaseline() {
        var endpoint = EndpointConfig(name: "DS", baseURL: "https://api.example.com",
                                      model: "deepseek-v4-flash")
        endpoint.defaultContextWindow = 262_144
        let snapshot = EndpointCatalogSnapshot()
        snapshot.replace([endpoint])
        let compactor = Compactor(
            contextWindowResolver: { model in
                snapshot.contextWindow(for: model, endpointID: endpoint.id)
            }) {
            throw LLMError(message: "unused", code: "TEST")
        }
        // 65.5k 回归：未配置窗口的模型 = 端点缺省窗口，不再落 65_536。
        XCTAssertEqual(compactor.contextWindow(for: "deepseek-v4-flash"), 262_144)
        // 无目录事实（resolver nil / 空 id）= policy 底线。
        let bare = Compactor(policy: .init()) {
            throw LLMError(message: "unused", code: "TEST")
        }
        XCTAssertEqual(bare.contextWindow(for: "anything"), 65_536)
        XCTAssertEqual(bare.contextWindow(for: nil), 65_536)
    }

    // MARK: - ModelDiscovery 解析（纯函数）

    func testDiscoveryParseListingAndURL() throws {
        // listingURL：尾斜杠去除、部署路径段保留（dsh listingUrl 语义）。
        XCTAssertEqual(ModelDiscovery.listingURL(baseURL: "https://gw.example/openai/v1/").absoluteString,
                       "https://gw.example/openai/v1/models")
        let data = Data("""
        {"data":[
          {"id":"m-1","name":"Model One","context_window":131072,"max_output_tokens":8192},
          {"id":"m-2","display_name":"Two","context_length":4096,"max_tokens":2048},
          {"no-id":true},
          {"id":""},
          {"id":"m-3"}
        ]}
        """.utf8)
        let models = try ModelDiscovery.parseListing(data)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].id, "m-1")
        XCTAssertEqual(models[0].name, "Model One")
        XCTAssertEqual(models[0].contextWindow, 131_072)
        XCTAssertEqual(models[0].maxTokens, 8_192)
        XCTAssertEqual(models[1].name, "Two")
        XCTAssertEqual(models[1].contextWindow, 4_096)
        XCTAssertEqual(models[1].maxTokens, 2_048)
        XCTAssertNil(models[2].contextWindow)
        // 无 data 数组 → DISCOVERY_FAILED。
        XCTAssertThrowsError(try ModelDiscovery.parseListing(Data(#"{"object":"list"}"#.utf8))) { error in
            XCTAssertEqual((error as? LLMError)?.code, "DISCOVERY_FAILED")
        }
        // 非 JSON → DISCOVERY_FAILED。
        XCTAssertThrowsError(try ModelDiscovery.parseListing(Data("not json".utf8))) { error in
            XCTAssertEqual((error as? LLMError)?.code, "DISCOVERY_FAILED")
        }
    }
}
