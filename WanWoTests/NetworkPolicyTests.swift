//
//  NetworkPolicyTests.swift
//  WanWoTests
//
//  【M5-B 批 N1 测试 · F028 沙箱网络隔离（宿主工具面收官件）】面对拍：
//    · judge 全分支：nil 白名单不受限 / scheme 面（dsh SUPPORTED_PROTOCOLS
//      http/https）/ 精确 / `*.` 仅子域（apex 拒）/ `**.` 含 apex / `*` 全局 /
//      deny 优先（SSRF 压过白名单命中）；
//    · SSRF 段表逐段（codex policy.rs:45-98 1:1）：IPv4 私网四段 + loopback
//      全 /8 + 0/8 + 组播/广播 + CGNAT + IETF-assignments + TEST-NET×3 +
//      benchmark + reserved + 前导零拼写；IPv6 loopback/unspecified/
//      link-local/unique-local/组播 + mapped 两拼写 + scope-id；公网对照；
//    · loopback 主机名变体（localhost / `.localhost` 后缀——dsh :259）；
//    · 主机归一化（大小写/尾点/单冒号端口/括号/scope-id 保留——codex
//      normalize_host :101-148 测试面 :468-503 逐条同形）；
//    · WebFetchTool 挂接：受限 deny 结构化拒绝回模型（文案逐字 + code
//      NETWORK_BLOCKED + 零网络请求——URLProtocol 桩计数） / SSRF 恒开
//      （不受限也拒 127.0.0.1）/ 不受限与白名单命中照旧出桩 HTTP。
//

import XCTest
@testable import WanWo

/// 出站 HTTP 桩（URLProtocol 重入；requestCount 供「零网络请求」断言）。
private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    static var requestCount = 0

    static func reset() {
        handler = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let (status, body) = Self.handler?(request) ?? (200, "ok")
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.invalid")!,
            statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NetworkPolicyTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try super.tearDownWithError()
    }

    // MARK: 夹具

    private func makeCtx() -> ToolExecutionContext {
        ToolExecutionContext(
            sessionId: "test", turn: 1, step: 1, callId: "call-1",
            workspace: WorkspaceFileAccess(sessionId: "test"),
            spill: SpillStore(root: FileManager.default.temporaryDirectory),
            onShellLine: { _, _ in },
            completeLLM: { _, _ in "" },
            sandboxMode: .workspaceWrite,
            escalationApprover: nil)
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func allowVerdicts(_ policy: NetworkPolicy, _ hosts: [String]) {
        for host in hosts {
            let verdict = policy.judge(host: host, scheme: "https")
            guard case .allow = verdict else {
                XCTFail("expected allow for \(host), got \(verdict)")
                continue
            }
        }
    }

    private func denyReason(_ policy: NetworkPolicy, _ host: String) -> String {
        guard case .deny(let reason) = policy.judge(host: host, scheme: "https") else {
            XCTFail("expected deny for \(host)")
            return ""
        }
        return reason
    }

    // MARK: judge 全分支

    func testNilWhitelistAllowsPublicHostAndDeniesScheme() {
        let policy = NetworkPolicy.unrestricted
        allowVerdicts(policy, ["example.com", "anything.invalid", "8.8.8.8",
                               "2001:db8::1"])
        // scheme 面（dsh SUPPORTED_PROTOCOLS :57——仅 http/https）。
        XCTAssertEqual(policy.judge(url: URL(string: "ftp://example.com")!),
                       .deny(reason: "not_allowed"))
        XCTAssertEqual(policy.judge(url: URL(string: "file:///etc/passwd")!),
                       .deny(reason: "not_allowed"))
        XCTAssertEqual(policy.judge(host: "example.com", scheme: "socks5"),
                       .deny(reason: "not_allowed"))
        // 空 host 拒。
        XCTAssertEqual(policy.judge(host: "", scheme: "https"),
                       .deny(reason: "not_allowed"))
    }

    func testExactPatternWithNormalization() {
        let policy = NetworkPolicy(allowedDomains: ["Example.COM."])
        allowVerdicts(policy, ["example.com", "EXAMPLE.com", "example.com."])
        XCTAssertEqual(denyReason(policy, "api.example.com"), "not_allowed")
        // 后缀锚必须带点（codex is_subdomain_or_equal :341-348）。
        XCTAssertEqual(denyReason(policy, "badexample.com"), "not_allowed")
        XCTAssertEqual(denyReason(policy, "other.org"), "not_allowed")
    }

    func testSubdomainsOnlyPattern() {
        let policy = NetworkPolicy(allowedDomains: ["*.example.com"])
        allowVerdicts(policy, ["api.example.com", "a.b.example.com",
                               "API.Example.COM"])
        // apex 不在 `*.` 内（codex expand :324-326 → `?*.domain`）。
        XCTAssertEqual(denyReason(policy, "example.com"), "not_allowed")
    }

    func testApexAndSubdomainsPattern() {
        let policy = NetworkPolicy(allowedDomains: ["**.example.com"])
        allowVerdicts(policy, ["example.com", "api.example.com",
                               "deep.a.example.com"])
        XCTAssertEqual(denyReason(policy, "badexample.com"), "not_allowed")
        XCTAssertEqual(denyReason(policy, "example.org"), "not_allowed")
    }

    func testGlobalWildcardPattern() {
        let policy = NetworkPolicy(allowedDomains: ["*"])
        allowVerdicts(policy, ["example.com", "anything.invalid", "8.8.8.8"])
        // deny 优先：`*` 白名单也压不过 SSRF（codex connect_policy.rs:71
        // "resolved IP is non-public → PermissionDenied" 同 invariant）。
        XCTAssertEqual(denyReason(policy, "10.0.0.1"), "not_allowed_local")
        XCTAssertEqual(denyReason(policy, "localhost"), "not_allowed_local")
    }

    func testDenyFirstSSRFOverWhitelistHit() {
        let policy = NetworkPolicy(allowedDomains: ["10.0.0.1", "internal.corp"])
        // 白名单条目本身是私网 IP → SSRF 先于白名单 deny（登记：第一版不做
        // "白名单豁免" 细粒度——codex target_matches_non_public_addr 校验面
        // 留后续件）。
        XCTAssertEqual(denyReason(policy, "10.0.0.1"), "not_allowed_local")
        allowVerdicts(policy, ["internal.corp"])
    }

    // MARK: SSRF · IPv4 段表

    func testSSRFPublicIPLiteralsAllowed() {
        allowVerdicts(NetworkPolicy.unrestricted, [
            "8.8.8.8", "9.9.9.9", "1.1.1.1",
            "172.32.0.1",        // 172.16/12 之外
            "100.128.0.1",       // CGNAT /10 之外
            "198.20.0.1",        // benchmark /15 之外
            "192.0.3.1",         // TEST-NET-1 之外
            "203.0.114.1",       // TEST-NET-3 之外
        ])
    }

    func testSSRFIPv4PrivateSegments() {
        let policy = NetworkPolicy.unrestricted
        let blocked = [
            "127.0.0.1", "127.255.255.254",      // loopback 全 /8
            "10.1.2.3",                          // private 10/8
            "172.16.0.1", "172.31.255.255",      // private 172.16/12
            "192.168.1.1",                       // private 192.168/16
            "169.254.0.1",                       // link-local 169.254/16
            "0.0.0.0", "0.1.2.3",                // unspecified + this-network 0/8
            "100.64.0.1", "100.127.255.255",     // CGNAT 100.64/10
            "192.0.0.1",                         // IETF Protocol Assignments
            "192.0.2.1",                         // TEST-NET-1
            "198.18.0.1", "198.19.255.255",      // benchmark 198.18/15
            "198.51.100.1",                      // TEST-NET-2
            "203.0.113.1",                       // TEST-NET-3
            "240.0.0.1", "250.1.2.3",            // reserved 240/4
            "255.255.255.255",                   // broadcast
            "224.0.0.1",                         // multicast 224/4
            "010.0.0.1",                         // 前导零拼写按十进制 → 私网（登记⑧）
        ]
        for host in blocked {
            XCTAssertEqual(denyReason(policy, host), "not_allowed_local", host)
        }
    }

    // MARK: SSRF · IPv6 段表

    func testSSRFIPv6Segments() {
        let policy = NetworkPolicy.unrestricted
        let blocked = [
            "::1",                       // loopback
            "::",                        // unspecified
            "fe80::1",                   // link-local fe80::/10
            "fc00::1", "fd12:3456::1",   // unique-local fc00::/7
            "ff02::1",                   // multicast
            "::ffff:127.0.0.1",          // IPv4-mapped loopback（dsh :263-265 两拼写面）
            "::ffff:10.0.0.1",           // mapped private
            "fe80::1%lo0",               // scope-id 字面量（登记④）
            "[::1]",                     // 括号拼写（归一化后同判）
            "::0.1.2.3",                 // IPv4-compatible 0/8 面（尾段点分十进制）
        ]
        for host in blocked {
            XCTAssertEqual(denyReason(policy, host), "not_allowed_local", host)
        }
        // mapped 公网照常放行（codex :458-460 对照）。
        allowVerdicts(policy, ["::ffff:8.8.8.8", "2001:db8::1",
                               "2620:0:2d0:200::7"])
    }

    // MARK: loopback 主机名变体

    func testLoopbackHostnameVariants() {
        let policy = NetworkPolicy.unrestricted
        for host in ["localhost", "localhost.", "LOCALHOST", "sub.localhost",
                     "a.b.localhost"] {
            XCTAssertEqual(denyReason(policy, host), "not_allowed_local", host)
        }
        // 非 localhost 后缀不误伤（codex :433 notlocalhost 对照）。
        allowVerdicts(policy, ["notlocalhost", "localhost.example.com"])
    }

    // MARK: 主机归一化（codex normalize_host 测试面 :468-503 逐条同形）

    func testHostNormalizationShapes() {
        XCTAssertEqual(HostNormalization.normalize("  ExAmPlE.CoM  "), "example.com")
        XCTAssertEqual(HostNormalization.normalize("example.com:1234"), "example.com")
        XCTAssertEqual(HostNormalization.normalize("example.com.:443"), "example.com")
        XCTAssertEqual(HostNormalization.normalize("example.com."), "example.com")
        XCTAssertEqual(HostNormalization.normalize("ExAmPlE.CoM."), "example.com")
        XCTAssertEqual(HostNormalization.normalize("[::1]"), "::1")
        XCTAssertEqual(HostNormalization.normalize("[::1]:443"), "::1")
        // 未加括号 IPv6 原样保留（多冒号不做端口剥离）。
        XCTAssertEqual(HostNormalization.normalize("2001:db8::1"), "2001:db8::1")
        // scope-id 保留（%25 转义归一）。
        XCTAssertEqual(HostNormalization.normalize("fe80::1%lo0"), "fe80::1%lo0")
        XCTAssertEqual(HostNormalization.normalize("[fe80::1%lo0]"), "fe80::1%lo0")
        XCTAssertEqual(HostNormalization.normalize("[fe80::1%25lo0]"), "fe80::1%lo0")
    }

    // MARK: IP 字面量解析形态

    func testIPLiteralParseShapes() {
        XCTAssertEqual(IPAddressLiteral.parse("1.2.3.4"),
                       .address(.v4((1 << 24) | (2 << 16) | (3 << 8) | 4)))
        XCTAssertEqual(IPAddressLiteral.parse("1:2:3:4:5:6:7:8"),
                       .address(.v6([1, 2, 3, 4, 5, 6, 7, 8])))
        // 完整形 + 内嵌 IPv4 尾段。
        XCTAssertEqual(IPAddressLiteral.parse("1:2:3:4:5:6:1.2.3.4"),
                       .address(.v6([1, 2, 3, 4, 5, 6, 0x0102, 0x0304])))
        // 压缩形 + mapped。
        XCTAssertEqual(IPAddressLiteral.parse("::ffff:1.2.3.4"),
                       .address(.v6([0, 0, 0, 0, 0, 0xffff, 0x0102, 0x0304])))
        // 非字面量。
        XCTAssertEqual(IPAddressLiteral.parse("example.com"), .notLiteral)
        XCTAssertEqual(IPAddressLiteral.parse("1.2.3.4.5"), .notLiteral)
        XCTAssertEqual(IPAddressLiteral.parse("127.999.1.1"), .notLiteral)
        XCTAssertEqual(IPAddressLiteral.parse("foo%bar"), .notLiteral)
        XCTAssertEqual(IPAddressLiteral.parse("1:2:3:4:5:6:7:8:9"), .notLiteral)
    }

    // MARK: 结构化拒绝文案

    func testBlockedMessageVerbatim() {
        // codex core/src/network_policy_decision.rs:46 形态。
        XCTAssertEqual(
            NetworkPolicy.blockedMessage(host: "example.com", reason: "not_allowed"),
            "Network access to \"example.com\" was blocked: not_allowed")
    }

    // MARK: WebFetchTool 挂接

    func testWebFetchRestrictedDenyStructuredNoNetwork() async throws {
        let tool = WebFetchTool(policy: NetworkPolicy(allowedDomains: ["internal.example"]),
                                session: stubSession())
        StubURLProtocol.handler = { _ in (200, "should not be reached") }
        let output = try await tool.execute(
            .object(["url": .string("https://example.com/page")]), makeCtx())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.text,
            "Error: Network access to \"example.com\" was blocked: not_allowed")
        XCTAssertEqual(output.errorCode, "NETWORK_BLOCKED")
        XCTAssertEqual(output.errorName, "NetworkPolicyError")
        // deny 先于出站：零网络请求。
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testWebFetchSSRFDenyEvenUnrestricted() async throws {
        let tool = WebFetchTool(policy: .unrestricted, session: stubSession())
        let output = try await tool.execute(
            .object(["url": .string("http://127.0.0.1:8080/admin")]), makeCtx())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.text,
            "Error: Network access to \"127.0.0.1\" was blocked: not_allowed_local")
        XCTAssertEqual(output.errorCode, "NETWORK_BLOCKED")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testWebFetchUnrestrictedAndWhitelistedFetchViaStub() async throws {
        StubURLProtocol.handler = { request in
            (200, "body of \(request.url?.host ?? "?")")
        }
        // 不受限：照旧出站（桩 HTTP）。
        let unrestricted = WebFetchTool(policy: .unrestricted, session: stubSession())
        let ok = try await unrestricted.execute(
            .object(["url": .string("https://example.com/doc")]), makeCtx())
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssert(ok.text.contains("body of example.com"), ok.text)
        // 白名单命中：照旧出站。
        let whitelisted = WebFetchTool(
            policy: NetworkPolicy(allowedDomains: ["example.com"]),
            session: stubSession())
        let hit = try await whitelisted.execute(
            .object(["url": .string("https://example.com/doc")]), makeCtx())
        XCTAssertFalse(hit.isError, hit.text)
        // 两次真出站（一次 unrestricted + 一次 whitelisted）。
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testWebFetchSchemeInvalidStillInvalidArgs() async throws {
        // 工具自身的 http(s) 守卫先于策略（INVALID_ARGS 形态保持不变）。
        let tool = WebFetchTool(policy: NetworkPolicy(allowedDomains: []),
                                session: stubSession())
        let output = try await tool.execute(
            .object(["url": .string("ftp://example.com/x")]), makeCtx())
        XCTAssertTrue(output.isError)
        XCTAssertEqual(output.errorCode, "INVALID_ARGS")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }
}
