//
//  RemoteSandboxProviderTests.swift
//  WanWoTests
//
//  【M5-B 批 S2 测试 · 远程沙箱 provider 接口 + 连通验证】
//    1. confine 三 mode 全抛 SANDBOX_UNAVAILABLE + detail 文案（fail-closed）
//    2. validateConnection 200 → ok 报告（请求形状对拍：GET /v2/sandboxes +
//       X-API-Key 头；endpoint 无凭据成分——apiKey 永不落报告）
//    3. 401 → 结构化失败（ok=false, httpStatus=401，不抛）
//    4. 网络错误 → 结构化失败（ok=false, httpStatus=nil，不抛）
//    5. 缺 apiKey 拒绝（dsh-e2b validate 文案逐字）+ cwd/timeoutMs 文案逐字
//    6. 缺省值/解析面（cwd/timeoutMs dsh :80-81；resolveAPIKey 两层优先级；
//       resolveEndpoint api-url.ts:21-26 四层推导）
//    7. SandboxProviderRegistry 装配纪律：validateConnection 通过才挂远程
//  传输经 performRequest 闭包缝桩注入，不走真网络。
//

import XCTest
@testable import WanWo

final class RemoteSandboxProviderTests: XCTestCase {

    /// 请求捕获桩容器（闭包内写、断言处读；Sendable 防线用类锁语义豁免）。
    private final class RequestBox: @unchecked Sendable {
        var request: URLRequest?
    }

    /// 构造带注入桩的 provider（status/error 二选一驱动响应形态）。
    private func makeProvider(apiKey: String = "e2b_test_key",
                              status: Int? = 200,
                              error: Error? = nil
    ) throws -> (RemoteSandboxProvider, RequestBox) {
        var provider = try RemoteSandboxProvider(
            config: RemoteSandboxConfig(apiKey: apiKey),
            endpoint: "https://api.e2b.app")
        let box = RequestBox()
        provider.performRequest = { request in
            box.request = request
            if let error { throw error }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status!,
                httpVersion: nil, headerFields: nil)!
            return (Data("[]".utf8), response)
        }
        return (provider, box)
    }

    // MARK: 1. confine fail closed（三 mode 全抛）

    func testConfineFailsClosedForAllModes() throws {
        let provider = try makeProvider().0
        for mode in SandboxMode.all {
            let policy = SandboxExecutionPolicy(
                mode: mode, workspaceRoot: SandboxPolicy.workspaceRoot,
                sessionId: "s1")
            XCTAssertThrowsError(try provider.confine(
                policy: policy, command: "echo hi")) { failure in
                guard let unavailable = failure as? SandboxUnavailableError else {
                    return XCTFail("expected SandboxUnavailableError, got \(failure)")
                }
                // 错误码 + mode 词汇 + 派单指定 detail 文案三对拍。
                XCTAssertEqual(SandboxUnavailableError.code, "SANDBOX_UNAVAILABLE")
                XCTAssertTrue(unavailable.message.contains(mode.rawValue))
                XCTAssertTrue(unavailable.message.contains(
                    "remote sandbox execution is not wired in this milestone"))
            }
        }
    }

    // MARK: 2. validateConnection 200 → ok 报告 + 请求形状对拍

    func testValidateConnectionSuccessReportAndRequestShape() async throws {
        let (provider, box) = try makeProvider()
        let report = await provider.validateConnection()
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.httpStatus, 200)
        XCTAssertGreaterThanOrEqual(report.latencyMs, 0)
        XCTAssertEqual(report.endpoint, "https://api.e2b.app")

        // 请求形状（REST 取证锚点对拍）：GET {endpoint}/v2/sandboxes +
        // X-API-Key 头；报告/端点零凭据成分。
        let request = try XCTUnwrap(box.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.e2b.app/v2/sandboxes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"),
                       "e2b_test_key")
        XCTAssertFalse(report.endpoint.contains("e2b_test_key"))
    }

    // MARK: 3. 401 → 结构化失败（不抛）

    func testValidateConnectionUnauthorizedIsStructuredFailure() async throws {
        let (provider, _) = try makeProvider(status: 401)
        let report = await provider.validateConnection()
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.httpStatus, 401)
        XCTAssertEqual(report.endpoint, "https://api.e2b.app")
    }

    // MARK: 4. 网络错误 → 结构化失败（不抛）

    func testValidateConnectionNetworkErrorIsStructuredFailure() async throws {
        let (provider, _) = try makeProvider(
            error: URLError(.notConnectedToInternet))
        let report = await provider.validateConnection()
        XCTAssertFalse(report.ok)
        XCTAssertNil(report.httpStatus)
        XCTAssertGreaterThanOrEqual(report.latencyMs, 0)
        XCTAssertEqual(report.endpoint, "https://api.e2b.app")
    }

    // MARK: 5. 配置校验文案逐字（dsh index.ts:142-152）

    func testMissingAPIKeyRejectedWithVerbatimMessage() {
        // dsh :143-145——空串 = 未配置（缺省解析 nil 归一空串同语义）。
        let config = RemoteSandboxConfig(apiKey: "")
        XCTAssertThrowsError(try config.validate()) { failure in
            XCTAssertEqual(
                (failure as? RemoteSandboxConfigError)?.message,
                "dsh-e2b: configure apiKey or set E2B_API_KEY")
        }
        // provider 构造期同位拒绝（dsh E2BRuntime init→validate 同序）。
        XCTAssertThrowsError(try RemoteSandboxProvider(
            config: RemoteSandboxConfig(apiKey: ""),
            endpoint: "https://api.e2b.app")) { failure in
            XCTAssertEqual(
                (failure as? RemoteSandboxConfigError)?.message,
                "dsh-e2b: configure apiKey or set E2B_API_KEY")
        }
    }

    func testCwdAndTimeoutValidationMessagesVerbatim() {
        // dsh :146-148。
        let badCwd = RemoteSandboxConfig(apiKey: "k", cwd: "relative/path")
        XCTAssertThrowsError(try badCwd.validate()) { failure in
            XCTAssertEqual(
                (failure as? RemoteSandboxConfigError)?.message,
                "dsh-e2b: cwd must be an absolute Linux path: relative/path")
        }
        // dsh :149-151（Int 量纲 finite 查 vacuously 成立——适配登记）。
        let badTimeout = RemoteSandboxConfig(apiKey: "k", timeoutMs: 0)
        XCTAssertThrowsError(try badTimeout.validate()) { failure in
            XCTAssertEqual(
                (failure as? RemoteSandboxConfigError)?.message,
                "dsh-e2b: timeoutMs must be a positive finite number")
        }
    }

    // MARK: 6. 缺省值 / 解析面

    func testConfigDefaultsMatchDsh() {
        // dsh index.ts:80-81。
        let config = RemoteSandboxConfig(apiKey: "k")
        XCTAssertEqual(config.cwd, "/home/user/workspace")
        XCTAssertEqual(config.timeoutMs, 300_000)
    }

    func testResolveAPIKeyLayerPriority() {
        // 第一层 env 胜出；env 缺省回落 Info.plist；两层皆缺 = nil。
        XCTAssertEqual(RemoteSandboxConfig.resolveAPIKey(
            env: ["E2B_API_KEY": "e2b_env"],
            infoPlist: ["E2BAPIKey": "e2b_plist"]), "e2b_env")
        XCTAssertEqual(RemoteSandboxConfig.resolveAPIKey(
            env: [:], infoPlist: ["E2BAPIKey": "e2b_plist"]), "e2b_plist")
        XCTAssertNil(RemoteSandboxConfig.resolveAPIKey(env: [:], infoPlist: nil))
        // 空串按缺省处理（dsh :143 length===0 判空同语义）。
        XCTAssertNil(RemoteSandboxConfig.resolveAPIKey(
            env: ["E2B_API_KEY": ""], infoPlist: nil))
    }

    func testResolveEndpointDerivation() {
        // api-url.ts:21-26 四层 1:1。
        XCTAssertEqual(RemoteSandboxConfig.resolveEndpoint(
            env: ["E2B_API_URL": "https://api.custom"]),
            "https://api.custom")                       // 显式 URL 最优先
        XCTAssertEqual(RemoteSandboxConfig.resolveEndpoint(
            env: ["E2B_DEBUG": "true"]), "http://localhost:3000")
        XCTAssertEqual(RemoteSandboxConfig.resolveEndpoint(
            env: ["E2B_DOMAIN": "example.dev"]),
            "https://api.example.dev")
        XCTAssertEqual(RemoteSandboxConfig.resolveEndpoint(env: [:]),
                       "https://api.e2b.app")            // 域缺省
        // E2B_API_URL 空串不遮蔽后续层（:23 显式 !== '' 判空同语义）。
        XCTAssertEqual(RemoteSandboxConfig.resolveEndpoint(
            env: ["E2B_API_URL": "", "E2B_DOMAIN": "example.dev"]),
            "https://api.example.dev")
    }

    // MARK: 7. 注册表装配纪律

    func testRegistryAssembleAttachesRemoteOnlyAfterPassingValidate() async throws {
        // 200 → 远程挂入，消费缝优先远程（preferredProvider 落远程类型）。
        let (okProvider, _) = try makeProvider()
        let okRegistry = await SandboxProviderRegistry.assemble(remote: okProvider)
        XCTAssertNotNil(okRegistry.remote)
        XCTAssertEqual(okRegistry.remote?.endpoint, okProvider.endpoint)
        XCTAssertTrue(type(of: okRegistry.preferredProvider())
                      == RemoteSandboxProvider.self)

        // 401 → 结构化失败，远程不挂（回落本地唯一候选）。
        let (rejectedProvider, _) = try makeProvider(status: 401)
        let rejectedRegistry = await SandboxProviderRegistry.assemble(
            remote: rejectedProvider)
        XCTAssertNil(rejectedRegistry.remote)

        // 无远程 config → 本地默认（S1 LocalSandboxProvider 唯一候选）。
        let localOnly = await SandboxProviderRegistry.assemble(remote: nil)
        XCTAssertNil(localOnly.remote)
    }
}
