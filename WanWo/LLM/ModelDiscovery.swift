//
//  ModelDiscovery.swift
//  WanWo
//
//  【语义移植 · dsh · M8 批1 探测后端】OpenAI 兼容 GET /models 列举。
//  出处（dsh 快照 packages/llm/llm-pi-ai/src/discovery.ts）：
//    - :38-41（可列举协议 = OpenAI 形态 GET /models + bearer；Azure/anthropic
//      变体不做——万我仅 OpenAI 兼容，登记）；
//    - :86-88（listingUrl：尾斜杠去除，base 按前缀拼接——部署路径段不丢）；
//    - :50（MAX_RESPONSE_BYTES 4MiB 有界防线；:96-131 读侧执行——万我
//      URLSession.data 全量缓冲后校验，登记为读后拒收的平台差异）；
//    - :264-269（非 2xx → DISCOVERY_FAILED；401/403 提示查 key）；
//    - :138-162（readListing：无 "data" 数组 = DISCOVERY_FAILED；无可用 id
//      的行跳过不整判失败；容量字段 context_window|context_length /
//      max_output_tokens|max_tokens；name/display_name 标签字段）；
//    - :244-246（key 缺省 = 匿名探测，无 authorization 头——网关型端点
//      可免鉴权列举）。
//  候选语义（ModelListEditor.tsx:1-15）：探测结果 = 候选元数据供用户挑选，
//  绝不静默写配置；错误不吞（throws，UI 显示在行旁、手填仍是出路）。
//  登记适配：dsh 的 catalog 路线免网络分支（catalogModels）万我无内置目录
//  （空集起步）→ 恒走网络分支。UI 按钮由 A2 消费，本文件只做后端函数。
//


import Foundation

/// 一条探测候选（dsh LlmDiscoveredModel 词汇）。
struct DiscoveredModel: Equatable, Sendable {
    var id: String
    var name: String?
    var contextWindow: Int?
    var maxTokens: Int?
}

/// 模型探测后端（OpenAI 兼容 GET {baseURL}/models）。
enum ModelDiscovery {

    /// 响应体上限（dsh MAX_RESPONSE_BYTES = 4MiB）。
    static let maxResponseBytes = 4 * 1024 * 1024

    /// 探测端点模型列表。
    /// - Parameters:
    ///   - baseURL: 端点基址（表单当前值，含未保存草稿——dsh「探测用表单
    ///     当前值」语义，ModelListEditor.tsx:8-10）。
    ///   - apiKey: 探测 key（表单已输入未保存的 key 优先；nil = 匿名探测，
    ///     dsh :244-246）。
    ///   - timeout: 请求超时（秒）。
    /// - Returns: 候选模型（端点顺序；无可用 id 的行跳过，dsh :135-137）。
    /// - Throws: LLMError——稳定 code：DISCOVERY_FAILED（不可达/非 2xx/非
    ///   JSON/无 data 数组/超限）；错误不吞（UI 显示在行旁，手填仍是出路）。
    static func discoverModels(baseURL: String,
                               apiKey: String?,
                               timeout: TimeInterval = 30) async throws -> [DiscoveredModel] {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBase.isEmpty {
            throw LLMError(message: "endpoint base URL is required for model discovery",
                           code: "DISCOVERY_FAILED")
        }
        let url = listingURL(baseURL: trimmedBase)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if Task.isCancelled {
                throw LLMError(message: "model discovery aborted by caller",
                               code: "ABORTED", isCallerAbort: true)
            }
            throw LLMError(message: "could not reach \(url.absoluteString): \(error.localizedDescription)",
                           code: "DISCOVERY_FAILED")
        }
        // 有界防线（dsh :96-131 读侧执行；万我为读后拒收——URLSession.data
        // 全量缓冲，登记为平台差异）。
        if data.count > maxResponseBytes {
            throw LLMError(message: "\(url.absoluteString) answered with more than \(maxResponseBytes) bytes",
                           code: "DISCOVERY_FAILED")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let hint = (status == 401 || status == 403) ? "; check the API key" : ""
            throw LLMError(message: "\(url.absoluteString) answered \(status)\(hint)",
                           code: "DISCOVERY_FAILED")
        }
        return try parseListing(data, url: url.absoluteString)
    }

    /// 拼接列举 URL（dsh listingUrl :86-88：base 按前缀拼接，尾斜杠去除
    /// ——部署路径段如 /openai/v1 不被 URL 解析吃掉）。
    static func listingURL(baseURL: String) -> URL {
        var trimmed = baseURL
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: "\(trimmed)/models") ?? URL(string: "https://localhost/models")!
    }

    // MARK: 候选解析（纯函数；dsh readListing :138-162 语义——单测直呼）

    /// 解析列举回复体。无 "data" 数组 = DISCOVERY_FAILED；无可用 id 的行
    /// 跳过（单个坏行不剥夺用户其余可用目录，dsh :135-137）；容量字段取
    /// 第一个可用候选（context_window → context_length /
    /// max_output_tokens → max_tokens，dsh :152-153）。
    static func parseListing(_ data: Data, url: String = "endpoint") throws -> [DiscoveredModel] {
        let body: Any
        do {
            body = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMError(message: "\(url) did not answer with JSON",
                           code: "DISCOVERY_FAILED")
        }
        guard let root = body as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw LLMError(message: "the endpoint's model listing has no \"data\" array; enter this provider's models by hand",
                           code: "DISCOVERY_FAILED")
        }
        var models: [DiscoveredModel] = []
        for entry in entries {
            guard let id = label(entry["id"]) else { continue }
            let name = label(entry["name"]) ?? label(entry["display_name"])
            let contextWindow = capacity(entry["context_window"], entry["context_length"])
            let maxTokens = capacity(entry["max_output_tokens"], entry["max_tokens"])
            models.append(DiscoveredModel(id: id, name: name,
                                          contextWindow: contextWindow,
                                          maxTokens: maxTokens))
        }
        return models
    }

    /// 正整数容量字段（dsh capacity :65-70：整数 > 0，否则 nil）。
    private static func capacity(_ candidates: Any...) -> Int? {
        for candidate in candidates {
            if let value = candidate as? Int, value > 0 { return value }
            if let value = candidate as? Double, value.rounded() == value, value > 0 {
                return Int(value)
            }
        }
        return nil
    }

    /// 非空字符串字段（dsh label :73-78）。
    private static func label(_ candidate: Any?) -> String? {
        guard let value = candidate as? String, !value.isEmpty else { return nil }
        return value
    }
}
