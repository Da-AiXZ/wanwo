//
//  BrowserUseEngineTests.swift
//  WanWoTests
//
//  【M6.3 B2 单测】派单【验证】四项：
//    · 24 动作枚举完整性 —— 实测 OpenMinis BrowserUseActions.swift:5-28
//      enum 为 22 case（简报 §3 的"24 case"与自身列举名单 22 个不符，
//      以源码实数为准，呈报勘误）；rawValue wire 名逐字核对；
//    · maxTabs=3（BrowserTabPool.swift:193 原文常量）；
//    · OriginPolicy 判定矩阵（缺省档=06-gap5:117 codex 缺省 1:1 +
//      per-origin 前缀覆盖 + ask 无缝 fail closed + askHandler 放行/拒绝）；
//    · cookie backup 存储往返（注入临时目录：Netscape 渲染/解析往返 +
//      JSON Codable 往返 + noteVisit 落盘位置注入生效）。
//  WKWebView 依赖面（导航/截图/下载 delegate）不强测——CI 模拟器跑
//  （派单口径）；引擎原装解析器（BrowserActionInput.parse）纯文本面随测。
//

import XCTest
@testable import WanWo

@MainActor
final class BrowserUseEngineTests: XCTestCase {

    // MARK: - 1. 动作枚举完整性（源=BrowserUseActions.swift:5-28）

    func testBrowserActionEnumCompleteness() {
        // wire 名 1:1（rawValue 与 OpenMinis 源码字面同序同值）。
        let expectedWireNames: [String] = [
            "navigate", "screenshot", "click", "type", "get_text", "scroll",
            "get_page_info", "execute_js", "find_elements", "hover",
            "get_readable", "set_user_agent", "set_viewport", "get_backbone",
            "fetch", "new_tab", "close_tab", "list_tabs", "get_cookies",
            "set_cookies", "scroll_and_collect", "wait_for_dom_stable",
        ]
        XCTAssertEqual(BrowserAction.allCases.count, expectedWireNames.count,
                       "BrowserAction case 数与 OpenMinis 源码实数不符")
        XCTAssertEqual(BrowserAction.allCases.map(\.rawValue), expectedWireNames,
                       "BrowserAction wire 名与 OpenMinis 源码逐字不符")
    }

    /// 工具 schema 的 action enumValues 与引擎枚举同源同序。
    /// 【终验修】真实嵌套 = schemaObject 根 {type, properties, required,
    /// additionalProperties}，action 在根["properties"] 下——断言路径对齐
    /// JSONValue.schemaObject 的实际产物。
    func testToolSchemaActionEnumMatchesEngine() {
        let tool = BrowserUseTool()
        guard case .object(let root) = tool.parameters,
              case .object(let props) = root["properties"],
              case .object(let actionSchema) = props["action"],
              case .array(let enumValues) = actionSchema["enum"] else {
            return XCTFail("browser_use schema 缺 action.enum")
        }
        XCTAssertEqual(enumValues.compactMap { $0.stringValue },
                       BrowserAction.allCases.map(\.rawValue))
    }

    // MARK: - 2. 标签池上限（源=BrowserTabPool.swift:193）

    func testMaxTabsIsThree() {
        XCTAssertEqual(BrowserTabPool.maxTabs, 3)
    }

    // MARK: - 3. OriginPolicy 判定矩阵

    /// 缺省档 = codex default_origin_policy 1:1（06-gap5:117）：
    /// access=allow / downloads=ask / uploads=deny / full_cdp_access=deny。
    func testDefaultRuleMatchesCodexDefault() {
        let rule = OriginPolicyRule.default
        XCTAssertEqual(rule.access, .allow)
        XCTAssertEqual(rule.downloads, .ask)
        XCTAssertEqual(rule.uploads, .deny)
        XCTAssertEqual(rule.fullCDPAccess, .deny)
    }

    /// 共享单例复位缺省档（矩阵测试前置；用后恢复，防串测）。
    /// 【终验修·B1】originOverrides 同入保存/恢复面——此前只复位
    /// defaultRule/askHandler，前面用例写入的 per-origin 覆盖（如
    /// testLongestPrefixOverrideWins 的 a.com uploads=.allow）残留到
    /// testUploadsDeniedByDefault，把缺省 deny 判成 allow（跨用例单例污染）。
    private func withResetPolicy(_ body: () async throws -> Void) async rethrows {
        let savedDefault = OriginPolicy.shared.defaultRule
        let savedHandler = OriginPolicy.shared.askHandler
        let savedOverrides = OriginPolicy.shared.originOverrides
        OriginPolicy.shared.defaultRule = .default
        OriginPolicy.shared.askHandler = nil
        OriginPolicy.shared.originOverrides = [:]
        defer {
            OriginPolicy.shared.defaultRule = savedDefault
            OriginPolicy.shared.askHandler = savedHandler
            OriginPolicy.shared.originOverrides = savedOverrides
        }
        try await body()
    }

    func testAccessDecisionMatrix() async {
        await withResetPolicy {
            // access：缺省 allow（含任意 origin）。
            XCTAssertEqual(OriginPolicy.shared.decide(\.access, for: "https://a.com"), .allow)
            XCTAssertEqual(OriginPolicy.shared.allowsAccess(for: "https://a.com"), true)
            // access：per-origin 覆盖 deny 生效（最长前缀胜出）。
            OriginPolicy.shared.originOverrides = [
                "https://a.com": OriginPolicyRule(access: .deny, downloads: .ask,
                                                  uploads: .deny, fullCDPAccess: .deny),
            ]
            XCTAssertEqual(OriginPolicy.shared.decide(\.access, for: "https://a.com/x"), .deny)
            XCTAssertEqual(OriginPolicy.shared.allowsAccess(for: "https://a.com/x"), false)
            // 非覆盖 origin 不受影响。
            XCTAssertEqual(OriginPolicy.shared.decide(\.access, for: "https://b.com"), .allow)
            // nil origin（无页面上下文）走缺省档。
            XCTAssertEqual(OriginPolicy.shared.decide(\.access, for: nil), .allow)
        }
    }

    /// 最长前缀匹配：更深前缀覆盖胜出（codex origins 前缀语义本地近似）。
    func testLongestPrefixOverrideWins() async {
        await withResetPolicy {
            OriginPolicy.shared.originOverrides = [
                "https://a.com": OriginPolicyRule(access: .allow, downloads: .allow,
                                                  uploads: .allow, fullCDPAccess: .deny),
                "https://a.com/private": OriginPolicyRule(access: .deny, downloads: .ask,
                                                          uploads: .deny, fullCDPAccess: .deny),
            ]
            XCTAssertEqual(OriginPolicy.shared.decide(\.access, for: "https://a.com/private/x"), .deny)
            XCTAssertEqual(OriginPolicy.shared.decide(\.access, for: "https://a.com/public"), .allow)
        }
    }

    /// downloads：ask + 无审批缝 → fail closed（authorizeDownloads=false）。
    func testDownloadsAskFailsClosedWithoutHandler() async {
        await withResetPolicy {
            OriginPolicy.shared.askHandler = nil
            let allowed = await OriginPolicy.shared.authorizeDownloads(for: "https://a.com")
            XCTAssertFalse(allowed, "ask 档无审批缝必须 fail closed")
        }
    }

    /// downloads：ask + 审批缝 → 审批结果透传（reason 随行）。
    func testDownloadsAskRoutesThroughHandler() async {
        await withResetPolicy {
            var receivedReason: String?
            OriginPolicy.shared.askHandler = { reason in
                receivedReason = reason
                return true
            }
            let allowed = await OriginPolicy.shared.authorizeDownloads(for: "https://a.com")
            XCTAssertTrue(allowed)
            XCTAssertEqual(receivedReason?.contains("downloads"), true,
                           "审批 reason 须携带维度名")
            // 拒绝路径。
            OriginPolicy.shared.askHandler = { _ in false }
            let denied = await OriginPolicy.shared.authorizeDownloads(for: "https://a.com")
            XCTAssertFalse(denied)
        }
    }

    /// uploads：缺省 deny（结构性——引擎无文件选取入口；判定函数在位）。
    func testUploadsDeniedByDefault() async {
        await withResetPolicy {
            OriginPolicy.shared.askHandler = { _ in true } // 即便审批放行也不可达 deny
            let allowed = await OriginPolicy.shared.authorizeUploads(for: "https://a.com")
            XCTAssertFalse(allowed)
        }
    }

    // MARK: - 4. cookie backup 存储往返（可注入存储）

    private func makeTempBackupDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookiebackup-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Netscape cookies.txt 渲染 → 解析往返无损（含 HttpOnly # 前缀、
    /// includeSubdomains、secure、expires、排序稳定性）。
    func testNetscapeRenderParseRoundTrip() throws {
        let cookies = [
            CookieBackupStore.BackupCookie(
                name: "sid", value: "abc-123", domain: ".example.com", path: "/",
                expires: 1_893_456_000, secure: true, httpOnly: true),
            CookieBackupStore.BackupCookie(
                name: "prefs", value: "dark", domain: "api.example.com", path: "/v2",
                expires: nil, secure: false, httpOnly: false),
        ]
        let rendered = CookieBackupStore.renderNetscape(cookies)
        let parsed = CookieBackupStore.parseNetscape(rendered)
        XCTAssertEqual(parsed.count, 2)
        // httpOnly cookie：#HttpOnly_ 前缀往返 + 字段全等。
        let sid = try XCTUnwrap(parsed.first { $0.name == "sid" })
        XCTAssertEqual(sid.value, "abc-123")
        XCTAssertEqual(sid.domain, ".example.com")
        XCTAssertEqual(sid.path, "/")
        XCTAssertEqual(sid.expires, 1_893_456_000)
        XCTAssertTrue(sid.secure)
        XCTAssertTrue(sid.httpOnly)
        // session cookie：expires nil 往返（0 → nil）。
        let prefs = try XCTUnwrap(parsed.first { $0.name == "prefs" })
        XCTAssertNil(prefs.expires)
        XCTAssertFalse(prefs.httpOnly)
        XCTAssertEqual(prefs.path, "/v2")
    }

    /// BackupCookie JSON Codable 往返（备份文件持久化载体）。
    func testBackupCookieJSONRoundTrip() throws {
        let original = CookieBackupStore.BackupCookie(
            name: "token", value: "v\"{with, specials}", domain: ".x.com", path: "/",
            expires: 1_900_000_000, secure: true, httpOnly: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CookieBackupStore.BackupCookie.self, from: data)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.value, original.value)
        XCTAssertEqual(decoded.domain, original.domain)
        XCTAssertEqual(decoded.path, original.path)
        XCTAssertEqual(decoded.expires, original.expires)
        XCTAssertEqual(decoded.secure, original.secure)
        XCTAssertEqual(decoded.httpOnly, original.httpOnly)
        XCTAssertEqual(decoded.key, ".x.com|/|token")
    }

    /// 注入目录生效：noteVisit 把 .lastVisit.json 落进临时目录（而非
    /// Application Support 默认位）——注入缝的文件级验证。
    func testBackupDirectoryOverrideHonored() throws {
        let dir = try makeTempBackupDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CookieBackupStore()
        store.backupDirectoryOverride = dir
        store.noteVisit(url: URL(string: "https://www.example.com/page")!)
        let visitFile = dir.appendingPathComponent(".lastVisit.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: visitFile.path),
                      "noteVisit 应把访问图落进注入目录")
        // 落盘内容可解析回 visit map（registrableDomain 归一 www.example.com→example.com）。
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: visitFile))
            as? [String: Double])
        XCTAssertEqual(json.keys.sorted(), ["example.com"])
    }

    // MARK: - 5. 引擎原装解析器（纯文本面，无 WKWebView）

    /// BrowserActionInput.parse：cookies 以 JSON 编码 STRING 形态到达时
    /// 仍可解析（schema-faithful 模型形态——BrowserUseActions.swift:113-128）。
    func testActionInputParsesStringFormCookies() throws {
        let json = """
        {"action":"set_cookies","tab_id":2,
         "cookies":"[{\\"name\\":\\"sid\\",\\"value\\":\\"v\\",\\"domain\\":\\".x.com\\"}]"}
        """
        let input = try XCTUnwrap(BrowserActionInput.parse(from: json))
        XCTAssertEqual(input.action, .setCookies)
        XCTAssertEqual(input.tabId, 2)
        let cookies = try XCTUnwrap(input.cookies)
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0]["name"] as? String, "sid")
    }

    /// 非法动作名 → parse 返回 nil（工具层合成结构化失败的判据）。
    func testActionInputRejectsUnknownAction() {
        XCTAssertNil(BrowserActionInput.parse(from: #"{"action":"nope"}"#))
        XCTAssertNil(BrowserActionInput.parse(from: "not json"))
    }
}
