//
//  BrowserUseTool.swift
//  WanWo
//
//  【M6.3 B2 · browser_use 工具注册（F033 工具面）】
//  出处：
//    · 工具 schema 全文照搬 OpenMinis src/ios/Agent/Chat/
//      AIChatViewModel+ToolDefinitions.swift:102-132（description 逐字 +
//      23 参数 + required + propertyOrdering；适配仅品牌字符串 minis://→wanwo://、
//      /var/minis/offloads→/var/wanwo/offloads——B2 派单四类之一）；
//    · 执行分发语义照搬 Chat/AIChatViewModel+ConcurrentTools.swift:547-638
//      （BrowserActionInput.parse → pool.execute → 截图/fetch 落盘 → 下载
//      报告随行）与 ChatStore.swift:1546-1564（卡片标题派生）；
//    · WanWo 工具面 = AgentTool 协议（dsh ToolDefinition 形态，ToolRegistry）。
//  适配裁定（详报随 B2 交付报告）：
//    ① OpenMinis 的 AIChatViewModel.browserTabPool（会话 ViewModel 缓存持有）
//       在 WanWo 无对应物 → BrowserUseSessionStore（本文件）承担 per-session
//       池登记/复用；shell CLI（wanwo-browser-use offload 桥）与本工具经同一
//       store 取池——OpenMinis "shell 与 agent 共享一份浏览器状态"语义保持。
//    ② 高风险面审查走既有审批呈现缝（F022 已砍，审批=沙箱提权那套）：
//       OriginPolicy.askHandler 在每次 execute 前接线 ctx.escalationApprover
//       （ApprovalCoordinator.request 同一呈现），execute 后拆除。工具经
//       ToolPipeline exclusive 车道串行（isConcurrencySafe=false），无并发
//       覆写竞态。无缝 → ask fail closed（OriginPolicy 内）。
//    ③ origin 策略工具层落点：fetch 动作=downloads 维前置授权；
//       execute_js=access 维判定；uploads 维无对应动作（22 动作无上传，
//       引擎无文件选取入口——结构性 deny，见 OriginPolicy 头注）。
//    ④ 截图/fetch 产物的 wanwo:// 资源 URL 随 B3 scheme 体系接入后才可
//       解析——本批落盘宿主 browser 桶（=guest /var/wanwo/browser/）并以
//       guest 路径随行，不产 wanwo_url（避免产不可解析引用，B3 接线后补）。
//

import Foundation

// MARK: - BrowserUseSessionStore（per-session 池登记 · 适配缝）

/// per-session 浏览器池登记表（OpenMinis ViewModelCache + BrowserUseOffloadBridge
/// fallbackPools 两级解析的 WanWo 单层适配——WanWo 无 AIChatViewModel 缓存层，
/// agent 工具与 offload 桥同取此表 ⇒ shell/agent 共享同一浏览器状态）。
@MainActor
final class BrowserUseSessionStore {
    static let shared = BrowserUseSessionStore()

    private init() {}

    private var pools: [String: BrowserTabPool] = [:]

    /// 取（惰性建）会话池。OpenMinis 桥在分配 fallback 池前有 ChatStore
    /// 存在性预检（deleted session 拒绝）；WanWo 无跨层会话存在性查询缝
    /// （SessionStore 为装配层 per-app actor）——降级为直接分配，删除会话
    /// 的残留池由 BrowserTabPoolRegistry 空闲驱逐/内存警告回收兜底（登记报告）。
    func pool(for sessionId: String) -> BrowserTabPool {
        if let existing = pools[sessionId] { return existing }
        let pool = BrowserTabPool()
        pool.sessionId = sessionId
        pools[sessionId] = pool
        return pool
    }

    /// 释放会话池（OpenMinis BrowserUseOffloadBridge.releasePool 同语义——
    /// 会话删除路径调用；@objc 供 ObjC 侧随桥触发）。
    @objc func releasePool(forSession sessionId: String) {
        pools.removeValue(forKey: sessionId)
    }

    /// 存活池快照（诊断面；BrowserTabPoolRegistry 之外的本店在册数）。
    var livePoolCount: Int { pools.count }
}

// MARK: - BrowserUseTool（AgentTool 本体）

struct BrowserUseTool: AgentTool {

    let name = "browser_use"

    // OpenMinis AIChatViewModel+ToolDefinitions.swift:104 description 逐字
    //（品牌适配：minis://→wanwo://、/var/minis/offloads→/var/wanwo/offloads）。
    let description = "Control a web browser with up to 3 tabs. Do NOT use this tool for wanwo:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. The browser supports both web URLs and wanwo:// resource URLs. Use wanwo:// URLs to preview session files (e.g. navigate to wanwo://workspace/index.html). Sub-resources (JS, CSS, images, fonts) referenced via wanwo:// absolute paths or relative paths within HTML pages resolve correctly. Use navigate to open URLs, screenshot to see the page (returns an image), click/type to interact with elements, get_text/get_readable to extract content, scroll to navigate long pages, scroll_and_collect to scroll through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and accumulate unique content items across scroll positions in a single call, find_elements to discover interactive elements, get_page_info for page metadata, get_backbone to get a structural overview of the page DOM as a simplified tree, fetch to download files/resources using the page's session (returns metadata and a wanwo:// URL), new_tab to open an additional tab, close_tab to close a tab, and list_tabs to see all open tabs. Use set_viewport with viewport_width + viewport_height to override the viewport for the current session (e.g. before screenshotting a 1920×1080 HTML composition that would otherwise be cropped to the phone viewport); pass reset=true to drop the session override and fall back to the global browser setting. Use get_cookies to retrieve cookies for the current page URL / current site root domain only (including HttpOnly cookies). get_cookies supports optional 'keyword' (filter by cookie name) and 'fuzzy' (true=contains match, false=exact match, default true). It returns only a summary and an offload env file path — raw cookie values are NOT included in the tool response. To reuse cookies in shell commands: `. /var/wanwo/offloads/env_cookies_xxx.sh && command`. You may define alias variables when needed. Use set_cookies to write cookies into the current page's cookie store via the native cookie store (so even HttpOnly cookies, which JS cannot set, land). Pass a 'cookies' array of objects, each with name + value (required) and optional domain (defaults to the current page host), path (defaults to '/'), secure, http_only, and expires (Unix timestamp in seconds; omit for a session cookie). Use wait_for_dom_stable to wait until the page DOM stops changing (useful after navigation or interactions that trigger async data loading — polls every 0.5s, resolves when mutation rate gradient is stable for 3+ intervals, default timeout 10s). Use tab_id to target a specific tab (defaults to the most recently used tab)."

    // 23 参数 schema：与 OpenMinis ToolDefinitions :105-131 逐字对齐
    //（type/description/enum 全同；integer 为 JSON Schema 原生词——OpenMinis
    // AgentToolParam.type=.integer 同值；propertyOrdering 以扩展键随行，
    // 消费端不识别即忽略）。
    let parameters: JSONValue = {
        func integer(_ description: String) -> JSONValue {
            .object(["type": .string("integer"), "description": .string(description)])
        }
        return .schemaObject(
            properties: [
                "tool_title": .stringSchema(description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Open Wikipedia homepage', 'Take screenshot of current page'). Use the same language as the user."),
                "action": .enumSchema(description: "The browser action to perform",
                                      allowedValues: BrowserAction.allCases.map(\.rawValue)),
                "url": .stringSchema(description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                "selector": .stringSchema(description: "CSS selector for targeting elements (click, type, get_text, scroll, hover, find_elements). For scroll: specify a scrollable container to scroll (e.g. 'div.timeline'); if omitted, auto-detects the best scrollable element."),
                "text": .stringSchema(description: "Text to type (for type action)"),
                "coordinate_x": integer("X coordinate for click (alternative to selector)"),
                "coordinate_y": integer("Y coordinate for click (alternative to selector)"),
                "direction": .enumSchema(description: "Scroll direction", allowedValues: ["up", "down"]),
                "amount": integer("Scroll amount in pixels (default: 500)"),
                "script": .stringSchema(description: "JavaScript code to execute (for execute_js action). The script runs inside an async function wrapper — `await` and top-level `return` are both supported (e.g. `var r = await fetch(url); return await r.json()`). DOM values may be returned directly — a DOMRect, Date, Error, element or NodeList is converted to plain JSON before it reaches you."),
                "user_agent": .enumSchema(description: "User agent profile to switch to",
                                          allowedValues: ["desktop_safari", "mobile_safari"]),
                "max_depth": integer("Maximum tree depth for get_backbone (default: 5)"),
                "scroll_count": integer("Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                "item_selector": .stringSchema(description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                "tab_id": integer("Target tab ID (optional, defaults to most recently used tab). Use list_tabs to see available tabs."),
                "keywords": .stringSchema(description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                "fuzzy": .booleanSchema(description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                "cookies": .stringSchema(description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                "timeout": integer("Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                "viewport_width": integer("Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                "viewport_height": integer("Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                "reset": .booleanSchema(description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                "full_page": .booleanSchema(description: "For screenshot: capture the entire scrollable page by temporarily resizing the WebView to document.documentElement.scrollHeight. Default false captures viewport only. Capped at 32768px tall; when capped, result text includes 'Truncated: true' and the original height."),
            ],
            required: ["tool_title", "action"])
        // propertyOrdering（OpenMinis :131 逐字序）以注释锚定：Gemini 专属
        // 排序提示键，WanWo adapter 不透传 provider 专属键——登记差异，参数
        // 语义不受影响。序：tool_title, action, tab_id, url, selector, text,
        // coordinate_x, coordinate_y, direction, amount, scroll_count,
        // item_selector, script, user_agent, max_depth, keywords, fuzzy,
        // cookies, timeout, viewport_width, viewport_height, reset, full_page
    }()

    /// 浏览器为有状态单实例面——恒 exclusive（dsh executionMode fail closed）。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    // MARK: 执行

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // args 回序列化为 JSON 字符串 → 引擎原装解析器（BrowserActionInput.parse，
        // 23 参数全解析含 cookies 双形态）。解析失败文案=OpenMinis 逐字。
        guard let obj = args.objectValue, obj["action"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: args.anyValue),
              let argsJSON = String(data: data, encoding: .utf8) else {
            return .failure("Invalid browser_use input. Required: 'action' parameter.",
                            code: "INVALID_ARGS", name: "BrowserUseError")
        }
        guard let input = BrowserActionInput.parse(from: argsJSON) else {
            return .failure("Invalid browser_use input. Required: 'action' parameter.",
                            code: "INVALID_ARGS", name: "BrowserUseError")
        }

        // ── origin 策略工具层前置判定（裁定③）─────────────────────────
        // fetch = 主动下载 → downloads 维（缺省 ask → 审批缝）；
        // execute_js = 页内代码执行 → access 维（缺省 allow 直通）。
        if input.action == .fetch {
            let allowed = await OriginPolicy.shared.authorizeDownloads(for: input.url)
            if !allowed {
                return .failure("fetch blocked by origin policy (downloads=ask/deny)"
                                    + (input.url.map { " for \($0)" } ?? "")
                                    + ". No approval was granted for this download.",
                                code: "ORIGIN_POLICY_BLOCKED", name: "OriginPolicyError")
            }
        }
        // ── 池解析（先于 execute_js 判定——origin 取自活动页当前 URL）──
        let pool = await MainActor.run {
            BrowserUseSessionStore.shared.pool(for: ctx.sessionId)
        }
        if input.action == .executeJS {
            let accessAllowed = await MainActor.run { () -> Bool in
                let currentOrigin = pool.activeManager?.currentURL
                return OriginPolicy.shared.allowsAccess(for: currentOrigin)
            }
            if !accessAllowed {
                return .failure("execute_js blocked by origin policy (access=deny).",
                                code: "ORIGIN_POLICY_BLOCKED", name: "OriginPolicyError")
            }
        }

        // ── 审批缝接线（裁定②）───────────────────────────────────────
        // downloads/uploads 的 ask 档在引擎 delegate 决策处异步回判；此处把
        // ctx.escalationApprover 适配为 OriginPolicy.askHandler（同一呈现缝：
        // ApprovalCoordinator.request → 审批卡）。execute 后拆除；exclusive
        // 车道保证串行无竞态。nil approver → askHandler 返回 false（fail closed）。
        await MainActor.run {
            OriginPolicy.shared.askHandler = { [approver = ctx.escalationApprover,
                                                callId = ctx.callId] reason in
                guard let approver else { return false }
                let outcome = await approver("browser_use", callId, reason)
                return outcome == .allowedOnce
            }
        }
        defer {
            Task { @MainActor in
                if OriginPolicy.shared.askHandler != nil {
                    OriginPolicy.shared.askHandler = nil
                }
            }
        }

        // ── 引擎执行 ─────────────────────────────────────────────────
        let result: BrowserActionResult
        do {
            // pool 是非隔离类方法（async throws），无需 MainActor.run 包裹。
            result = try await pool.execute(action: input)
        } catch {
            return .failure(error.localizedDescription,
                            code: "BROWSER_ERROR", name: "BrowserUseError")
        }

        var text = result.text
        if !result.success {
            return ToolOutput(text: text, isError: true,
                              errorName: "BrowserActionFailed",
                              errorCode: "BROWSER_ACTION_FAILED", meta: nil)
        }

        // ── 截图 / fetch 产物落盘（ConcurrentTools:582-615 语义）──────
        // 落会话 browser 桶（=guest /var/wanwo/browser/）；wanwo_url 待 B3
        // scheme 体系接入（裁定④），本批以 guest 路径随行。
        let browserDir = WanWoPaths.sessionPersistentDir(for: ctx.sessionId,
                                                         bucket: "browser")
        if let b64 = result.base64Image, let data = Data(base64Encoded: b64) {
            let filename = "screenshot_\(Int(Date().timeIntervalSince1970)).jpg"
            try? FileManager.default.createDirectory(at: browserDir,
                                                     withIntermediateDirectories: true)
            let persistPath = browserDir.appendingPathComponent(filename)
            try? data.write(to: persistPath)
            text += "\nimage_path: \(WanWoPaths.browserLinuxDir)/\(filename)"
        }
        if let fetchData = result.fetchedFileData, let fetchName = result.fetchedFileName {
            try? FileManager.default.createDirectory(at: browserDir,
                                                     withIntermediateDirectories: true)
            let persistPath = browserDir.appendingPathComponent(fetchName)
            try? fetchData.write(to: persistPath)
            text += "\nfetched_path: \(WanWoPaths.browserLinuxDir)/\(fetchName)"
        }

        // 原生 WKDownload 活动报告随行（ConcurrentTools:624-638 语义；
        // 引擎侧 BrowserDownloadCenter 会话范围报告）。
        if let downloadReport = await MainActor.run(body: {
            BrowserDownloadCenter.shared.agentReport(for: ctx.sessionId)
        }) {
            text += "\n\n" + downloadReport
        }

        return .success(text)
    }

    // MARK: 卡片意图（ChatStore.swift:1546-1564 标题派生语义）

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        func str(_ key: String) -> String? {
            guard let v = args.objectValue?[key]?.stringValue else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func cap(_ s: String) -> String {
            s.count > 100 ? String(s.prefix(100)) + "…" : s
        }
        if let title = str("tool_title") { return ToolCardIntent(kind: .web, title: cap(title)) }
        let action = str("action") ?? "browse"
        if let url = str("url") { return ToolCardIntent(kind: .web, title: cap("\(action) \(url)")) }
        return ToolCardIntent(kind: .web, title: cap("browser_use \(action)"))
    }
}
