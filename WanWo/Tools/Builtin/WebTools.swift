//
//  WebTools.swift
//  WanWo
//
//  【按设计新写】出处：10-design §十一 M2.6（F015：web_search/web_fetch）+
//  附录 B #42（DeepSeek 搜索 + HTTP fetch）。
//  M2 形态：
//    · web_fetch：URLSession GET；文本响应净化截断回注；非文本响应只回元信息。
//    · web_search：经 ToolExecutionContext.completeLLM 缝（M2 占位语义——搜索
//      编排走模型直调，真检索后端随 M8 TokenMeter/Providers 层接入；偏差记交付报告）。
//  工具失败一律合成错误结果（管线兜底），本文件不向 loop 抛错。
//

import Foundation

// MARK: - web_fetch

struct WebFetchTool: AgentTool {
    let name = "web_fetch"
    let description = "Fetch a URL over HTTP(S) and return the response body as sanitized text "
        + "(non-text responses return metadata only)."
    let parameters = JSONValue.schemaObject(
        properties: [
            "url": .stringSchema(description: "The http(s) URL to fetch."),
            "max_bytes": .numberSchema(description: "Maximum response bytes to consume. Defaults to 200000."),
        ],
        required: ["url"])

    /// 结果字符上限（§5.4 输出卫生口径）。
    static let maxChars = 15_000

    /// 网络策略（M5-B N1 · F028：逐连接裁决前置——deny 优先，SSRF 恒开）。
    let policy: NetworkPolicy
    /// 出站会话缝（测试注入 URLProtocol 桩；生产缺省 .shared 不变）。
    let session: URLSession

    init(policy: NetworkPolicy = .unrestricted, session: URLSession = .shared) {
        self.policy = policy
        self.session = session
    }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    // MARK: B⑤ 孤立 % 预编码（批2）

    /// 【批2 B⑤】孤立 %（后随非两位十六进制）预编码为 %25——`URL(string:)`
    /// 对 "%l:+%c" 等非法转义序列返回 nil（wttr.in 天气格式串实证），模型拿到
    /// 的 URL 语法上无害、只是不含 RFC 合法转义，直接 INVALID_ARGS 拒绝过严。
    /// 规则：`%` 后随两位十六进制 → 原样保留（合法转义 %20 等不动）；
    /// 否则（含结尾孤 %、%后仅一位 hex）→ 编码为 %25。编码失败仍走原
    /// INVALID_ARGS 错误（修法不改变最终失败面）。
    /// 锚点：批2 简报 2A B⑤；WebTools.swift 原 :43-47 判定点。
    static func encodeLonePercent(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        // ASCII hex 判定（Unicode.Scalar 无 isHexDigit；手写区间最直白）。
        func isHex(_ s: Unicode.Scalar) -> Bool {
            (s >= "0" && s <= "9") || (s >= "A" && s <= "F") || (s >= "a" && s <= "f")
        }
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "%",
               !(i + 2 < scalars.count && isHex(scalars[i + 1]) && isHex(scalars[i + 2])) {
                // 孤立 %：后随不足两位或非 hex → 编码。
                out.append(contentsOf: "%25".unicodeScalars)
            } else {
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let urlText = args.objectValue?["url"]?.stringValue else {
            return .failure("invalid or non-http(s) url", code: "INVALID_ARGS")
        }
        // 【批2 B⑤】孤立 % 预编码后再解析（合法转义原样保留；仍解析失败
        // 走原错误——错误面零变化）。
        guard let url = URL(string: Self.encodeLonePercent(urlText)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure("invalid or non-http(s) url", code: "INVALID_ARGS")
        }
        // M5-B N1（F028）：逐连接裁决前置（NetworkPolicy.judge——scheme 面 →
        // SSRF 恒开 → 域名白名单，deny 优先）。拒绝为结构化失败回模型
        //（codex network_policy_decision.rs:46 文案逐字形态），不抛穿管线。
        switch policy.judge(url: url) {
        case .deny(let reason):
            let blockedHost = url.host ?? urlText
            return .failure(NetworkPolicy.blockedMessage(host: blockedHost, reason: reason),
                            code: "NETWORK_BLOCKED", name: "NetworkPolicyError")
        case .allow:
            break
        }
        let maxBytes = args.objectValue?["max_bytes"]?.intValue ?? 200_000
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("WanWo/0.1 (agent)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("no HTTP response", code: "WEB_ERROR")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure("HTTP \(http.statusCode) from \(urlText)", code: "HTTP_\(http.statusCode)")
            }
            let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let isText = mime.contains("text") || mime.contains("json")
                || mime.contains("xml") || mime.contains("javascript")
            guard isText else {
                return .success("Fetched \(urlText): HTTP \(http.statusCode), "
                                    + "content-type \(mime), \(data.count) bytes (binary content not inlined).")
            }
            let body = String(decoding: data.prefix(maxBytes), as: UTF8.self)
            var text = "Fetched \(urlText) (HTTP \(http.statusCode)):\n\n"
                + OutputSanitizer.sanitize(body)
            if data.count > maxBytes {
                text += "\n\n[... response truncated at \(maxBytes) of \(data.count) bytes]"
            }
            return .success(text)
        } catch {
            return .failure("fetch failed: \(String(describing: error))", code: "WEB_ERROR")
        }
    }
}

// MARK: - web_search

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Search the web for the query. Returns a synthesized summary with source "
        + "URLs and snippets (backend: model-mediated search seam in M2)."
    let parameters = JSONValue.schemaObject(
        properties: [
            "query": .stringSchema(description: "The search query."),
        ],
        required: ["query"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = args.objectValue?["query"]?.stringValue, !query.isEmpty else {
            return .failure("missing required parameter \"query\"", code: "INVALID_ARGS")
        }
        let system = "You are a web search assistant. Given a search query, produce a compact "
            + "result list: 3-6 items, each with a plausible source name, URL, and a one-line "
            + "snippet. If you cannot browse, clearly mark items as UNVERIFIED. Answer in the "
            + "language of the query."
        do {
            let answer = try await ctx.completeLLM(
                "Search the web for: \(query)", system)
            return .success(OutputSanitizer.sanitize(answer))
        } catch {
            return .failure("search failed: \(String(describing: error))", code: "SEARCH_ERROR")
        }
    }
}

// MARK: - 注册器

enum WebTools {
    /// M5-B N1：web_fetch 挂接网络策略（缺省不受限——生产装配经
    /// AppEnvironment 装配常量传入；web_search 走 completeLLM 缝不受限）。
    static func registerAll(into registry: ToolRegistry,
                            policy: NetworkPolicy = .unrestricted) {
        registry.register(WebFetchTool(policy: policy))
        registry.register(WebSearchTool())
    }
}
