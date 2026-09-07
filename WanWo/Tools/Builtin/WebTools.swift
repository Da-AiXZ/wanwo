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

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let urlText = args.objectValue?["url"]?.stringValue,
              let url = URL(string: urlText), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure("invalid or non-http(s) url", code: "INVALID_ARGS")
        }
        let maxBytes = args.objectValue?["max_bytes"]?.intValue ?? 200_000
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("WanWo/0.1 (agent)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
    static func registerAll(into registry: ToolRegistry) {
        registry.register(WebFetchTool())
        registry.register(WebSearchTool())
    }
}
