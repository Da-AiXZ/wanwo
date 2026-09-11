//
//  MCPToolExecutor.swift
//  WanWo
//
//  【M4-A 件5 · 工具执行 + 结果投影】dsh tools.ts 移植（出处：
//  packages/mcp/mcp-client/src/tools.ts）：
//    · :59 RawCallToolResultSchema（z.record(string, unknown) 宽松 result
//      解码——网络信任边界，dsh :197-201 注释：SDK 声明 required 的字段在
//      server 有 bug 时可能缺席）；
//    · :80-96 callToolUncached（raw method=tools/call、rawName 上 wire、
//      绕开 SDK 类型化 content 解码与校验路径、timeout=toolCallTimeoutMs、
//      signal 取消）；
//    · :304-362 createExecutor（taskRequired 拒绝、模型参数非对象回退 {}、
//      isError→throw、legacy toolResult 归一化、McpResult canonical、
//      含图内容投影分支）；
//    · :365-377 containsImage；:424-427 imageDiagnostic；:498-560
//      extractText/projectContent（文本投影与占位文案逐字）。
//  图片准入（:379-488 decodeImage/resolveImageAdmission/prepareImageProjection）
//  = MCPImageProjecting 缝，件6 实现；件5 阶段缝未注入（nil）时图片块走
//  projectContent 默认占位（=未准入语义，fail closed）。
//  依赖复用：MCPSettleOnce（件3 立亦在本批提升 internal——超时竞速同形态）、
//  JSONValue(MCP.Value) 桥（件4）。
//

import Foundation
import MCP

// MARK: - 图片投影缝（件6 实现）

/// dsh tools.ts:434-488 prepareImageProjection 的缝化（件6 实现）：严格解码
/// （canonical base64 双校验+四媒体类型）→准入校验（AttachmentStore 存在+
/// 当前会话路由模型 inputModalities 含 image）→saveImages→按原位置产出
/// 图片呈现；任一环节失败→全部图片降级为文本诊断（imageDiagnostic 文案）。
protocol MCPImageProjecting: Sendable {
    /// - Returns: text=模型可见文本（含图位置按件6 定义呈现；任一失败即
    ///   全降级诊断）；meta=非 nil 时整体替换 ToolOutput.meta（nil=沿用
    ///   canonical McpResult——件6 的图片引用载荷通道由其定义）。
    func project(content: [JSONValue], rawName: String,
                 context: ToolExecutionContext) async -> (text: String, meta: JSONValue?)
}

// MARK: - 宽松 result 解码（tools.ts:59 RawCallToolResultSchema）

/// dsh 宽松 tools/call 结果的 Swift Method 形态：顶层必须是 object、字段值
/// 任意 JSON——不经 SDK 类型化 content 解码（dsh :80-96 raw request 绕行
/// 1:1；Method/Request/Client.send 均为 SDK 公开 API，非 fork）。
enum RawCallTool: MCP.Method {
    // MCP.Method 限定：桥接头把 ObjC runtime.h 的 `Method`（typedef struct
    // objc_method *）泄入模块——CI 工具链实证裸名歧义，SDK 协议须限定。
    static let name = "tools/call"                  // dsh :88 method 1:1
    typealias Parameters = CallTool.Parameters      // SDK 公开参数类型

    struct Result: Codable, Hashable, Sendable {
        /// dsh :324 content：宽松形态（数组/null/缺失/非数组均可能）。
        let content: Value?
        /// dsh :349-354 structuredContent（键存在即保留，含显式 null）。
        let structuredContent: Value?
        /// dsh :329/:345 isError（`=== true` 严格判定；null→不抛）。
        let isError: Bool?
        /// dsh :325 legacy toolResult 值。
        let toolResult: Value?
        /// dsh :327 `'toolResult' in result`——键存在性（含显式 null）。
        let hasToolResult: Bool

        private enum CodingKeys: String, CodingKey {
            case content, structuredContent, isError, toolResult
        }

        init(from decoder: Decoder) throws {
            // container(keyedBy:) 对非 object 顶层即抛——z.record 校验 1:1。
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // decodeIfPresent 会把 JSON null 合并为 nil（丢失「键存在值为
            // null」）；dsh 语义区分两者（structuredContent: null 进
            // canonical、'toolResult' in result 对 null 为 true），故
            // contains+decode 组合（JSON null → Value.null）。
            content = try Self.decodeLoose(.content, container)
            structuredContent = try Self.decodeLoose(.structuredContent, container)
            isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
            if container.contains(.toolResult) {
                hasToolResult = true
                toolResult = try Self.decodeLoose(.toolResult, container)
            } else {
                hasToolResult = false
                toolResult = nil
            }
        }

        private static func decodeLoose(_ key: CodingKeys,
                                        _ container: KeyedDecodingContainer<CodingKeys>) throws -> Value? {
            guard container.contains(key) else { return nil }
            return try container.decode(Value.self, forKey: key)
        }
    }
}

// MARK: - 错误

/// 工具调用超时（dsh RequestOptions.timeout 的错误由 TS SDK 内部产出——
/// 文案不受 dsh 控制；Swift 自拟，风格对齐 MCPConnectTimeoutError）。
struct MCPToolCallTimeoutError: Error, CustomStringConvertible {
    let timeoutMs: Int
    var description: String { "mcp-client: tool call timed out after \(timeoutMs)ms" }
}

// MARK: - 执行器（tools.ts:304-362 createExecutor 1:1）

/// dsh createExecutor 的 MCPToolExecuting 实现：rawName 上 wire（公共名永不
/// 解析还原，tools.ts:9-10 契约）、taskRequired 拒绝（件4 口径：SDK 未建模
/// execution 字段→当前不可达，路径保留）、模型参数非对象回退、60s 超时、
/// isError→throw、legacy 归一化、canonical value 落 meta、文本投影。
/// （执行路径无日志——dsh executor 同样零日志，:304-362。）
final class MCPToolExecutor: MCPToolExecuting {

    /// 件6 注入；nil（件5 阶段）=图片全部走 projectContent 默认占位。
    private let imageProjector: MCPImageProjecting?

    init(imageProjector: MCPImageProjecting? = nil) {
        self.imageProjector = imageProjector
    }

    func execute(client: Client,
                 rawName: String,
                 taskRequired: Bool,
                 options: MCPToolBridgeOptions,
                 args: JSONValue,
                 context: ToolExecutionContext) async throws -> ToolOutput {
        // :313-315——task-based execution 本桥不支持。
        if taskRequired {
            throw MCPConfigurationError(
                "Tool \"\(rawName)\" requires task-based execution, " +
                "which this bridge does not support")
        }
        // :316-320——模型参数通常为 object，模型失当（裸 string/number/null）
        // 时回退 {}：让 MCP server 产出具体的「缺参」错误供模型学习。
        let argsObject = args.objectValue ?? [:]

        // :321——uncached tools/call（超时=opts.toolCallTimeoutMs，dsh :93）。
        let result = try await callToolUncached(
            client: client, rawName: rawName, arguments: argsObject,
            timeoutMs: options.toolCallTimeoutMs)

        // :349-354——structuredContent 键存在即保留（含显式 null，decodeLoose
        // 已区分）；Value→JSONValue 桥（件4）。Optional.map 不收 throwing
        // 闭包，逐值 if-let。
        var structured: JSONValue?
        if let raw = result.structuredContent { structured = try JSONValue(raw) }

        // :323-336——legacy 归一化：content 缺失或非数组时走 toolResult/占位。
        var content: [JSONValue]?
        if let raw = result.content {
            let converted = try JSONValue(raw)
            if case .array(let items) = converted { content = items }
        }
        guard let content else {
            // :325-328——'toolResult' in result ? JSON.stringify : '(no output)'。
            let text = legacyText(result)
            if result.isError == true { throw MCPConfigurationError(text) }   // :329
            return ToolOutput(text: text, isError: false, errorName: nil,
                              errorCode: nil, meta: legacyCanonical(text: text,
                                                                    structuredContent: structured))
        }

        // :341-342——信任边界逐块宽松解析的文本提取。
        let text = Self.extractText(content, toolName: rawName)
        // :344-347——MCP isError → throw（loop 侧产出 isError 结果给模型）。
        if result.isError == true { throw MCPConfigurationError(text) }

        // :349-354——canonical value（content 数组原样+structuredContent 可选；
        // dsh :40 注释「without discarding protocol blocks」）。WanWo 通道=
        // ToolOutput.meta 落 tool/result.meta（程序化/呈现侧可见，模型可见=
        // 投影 text）。
        let canonical = try canonicalMeta(content: content, structuredContent: structured)

        // :355-359——含图内容→投影缝（件6）。dsh 的 fallback（:356）与
        // finalizeContent 一致性校验（:263-271）的 WanWo 形态说明：ToolOutput
        // 单形态，execute 返回即最终落盘形态（无二次校验位），投影即输出。
        if Self.containsImage(content) {
            if let imageProjector {
                let projected = await imageProjector.project(
                    content: content, rawName: rawName, context: context)
                let meta = projected.meta ?? canonical
                return ToolOutput(text: projected.text, isError: false,
                                  errorName: nil, errorCode: nil, meta: meta)
            }
            // 缝未注入→默认占位（extractText 的 image 位已是未准入诊断）。
        }
        return ToolOutput(text: text, isError: false, errorName: nil,
                          errorCode: nil, meta: canonical)
    }

    // MARK: uncached 调用（tools.ts:80-96 + 超时/取消的 Swift 竞速）

    /// dsh callToolUncached 1:1：raw request（method=tools/call+宽松 result
    /// 解码）——dsh 经 TS SDK request options 传 {signal, timeout}；Swift SDK
    /// 无内建 request 超时/取消（sendAndAwait 挂起至响应或 disconnect），
    /// 两半边均由 settle-once 结果箱竞速实现（形态=件3 看门狗同款）：
    /// - timeout：watchdog Task 在 toolCallTimeoutMs 后 settle 超时错误；
    /// - signal：外层任务取消（withTaskCancellationHandler）settle
    ///   CancellationError。悬置的 call 任务不强杀（无 abort API——上游
    ///   限制，随 response/client disconnect 有界回收，悬置零 CPU）。
    private func callToolUncached(client: Client,
                                  rawName: String,
                                  arguments: [String: JSONValue],
                                  timeoutMs: Int) async throws -> RawCallTool.Result {
        let valueArgs = try arguments.mapValues { try Value($0) }
        let request = RawCallTool.request(
            CallTool.Parameters(name: rawName, arguments: valueArgs))     // :88-89
        let box = MCPSettleOnce<Result<RawCallTool.Result, any Error>>()
        // call 任务无需引用保持（Task 自调度）；悬置回收=response/disconnect。
        Task {
            do {
                // Client 是 actor：send 须 await（CI 工具链实证；SDK 0.12.1
                // send 本体 throws → RequestContext，.value 再 await）。
                let context = try await client.send(request)
                box.settle(.success(try await context.value))
            } catch {
                box.settle(.failure(error))
            }
        }
        let watchdogTask = Task { [timeoutMs] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)  // :93
            box.settle(.failure(MCPToolCallTimeoutError(timeoutMs: timeoutMs)))
        }
        let outcome = await withTaskCancellationHandler {
            await box.wait()
        } onCancel: {
            box.settle(.failure(CancellationError()))
        }
        watchdogTask.cancel()
        switch outcome {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    // MARK: 投影纯函数（tools.ts:498-560；dsh 模块级纯函数 1:1，static 供件6 复用）

    /// dsh :498-503：文本块换行归并；image/audio/resource→占位（声明 required
    /// 的字段在信任边界用兜底守卫，:495-497 注释）。
    static func extractText(_ content: [JSONValue], toolName: String) -> String {
        projectContent(content, toolName: toolName).joined(separator: "\n")
    }

    /// dsh :510-560 projectContent 1:1：有序块投影——文本段换行归并，image
    /// 位置由占位闭包切开（dsh 形态=ContentBlock[]；件5 全文本形态，件6 准入
    /// 后经缝改写）。
    /// - Parameters:
    ///   - image: dsh :513-516 默认 image 投影=未准入占位诊断。
    static func projectContent(_ content: [JSONValue],
                               toolName: String,
                               image: (JSONValue, Int) -> String
                                   = { block, _ in
                                       MCPToolExecutor.imageDiagnostic(
                                           block,
                                           "this result was not admitted to durable model context")
                                   }
    ) -> [String] {
        var projected: [String] = []
        var textRun: [String] = []
        func flushText() {                                     // :520-523
            if textRun.isEmpty { return }
            projected.append(textRun.joined(separator: "\n"))
            textRun.removeAll()
        }

        for (index, value) in content.enumerated() {           // :525
            guard let block = value.objectValue else {         // :526-529 isRecord
                textRun.append("[unsupported MCP content block: expected an object]")
                continue
            }
            switch block["type"]?.stringValue {                // :530-531
            case "text":                                       // :532-534
                // dsh：text !== undefined 即 push（JSON null 会 push null、
                // join 时空串占位）；Swift 对 null 用空串占位等价。
                if case .string(let t)? = block["text"] {
                    textRun.append(t)
                } else if block["text"] != nil {
                    textRun.append("")
                }
            case "image":                                      // :535-538
                flushText()
                projected.append(image(value, index))
            case "resource_link":                              // :539-545
                let name = block["name"]?.stringValue
                let uri = block["uri"]?.stringValue
                // dsh 以 undefined 判缺失；JSON null 在 dsh 会被当有效值串出
                // "null"（非意图行为）——WanWo 将 null 并入缺失分支（自查登记）。
                if name == nil || uri == nil {
                    textRun.append("[resource link unavailable: the MCP block is missing its name or URI]")
                } else {
                    textRun.append("Resource link: \(name!) (\(uri!))")
                }
            case "audio":                                      // :546-548
                textRun.append(
                    "[audio result unsupported: " +
                    "\(block["mimeType"]?.stringValue ?? "unknown media type"); " +
                    "raw audio data remains available to programmatic callers]")
            case "resource":                                   // :549-551
                textRun.append(
                    "[embedded resource unsupported; raw resource data " +
                    "remains available to programmatic callers]")
            default:                                           // :552-554
                // dsh 字面：block.type 为 undefined 时模板串出 "undefined"。
                textRun.append("[unsupported MCP content type: " +
                               "\(block["type"]?.stringValue ?? "undefined")]")
            }
        }
        flushText()                                            // :556
        // :557-559——全空兜底。
        return projected.isEmpty
            ? ["(\(toolName) returned no model-visible content)"]
            : projected
    }

    /// dsh :365-367：无信内容数组是否含声明的 image 块。
    static func containsImage(_ content: [JSONValue]) -> Bool {
        content.contains { $0.objectValue?["type"]?.stringValue == "image" }
    }

    /// dsh :424-427 imageDiagnostic 1:1：未准入 image 块的稳定诊断文本。
    static func imageDiagnostic(_ block: JSONValue, _ reason: String) -> String {
        let mediaType = block.objectValue?["mimeType"]?.stringValue ?? "unknown media type"
        return "[image unavailable: \(mediaType); \(reason); " +
               "raw image data remains available to programmatic callers]"
    }

    // MARK: canonical 组装（tools.ts:41-44/325-335）

    /// dsh :330-335 legacy 归一化返回形态 1:1：
    /// `{content: [{type:'text', text}], structuredContent?}`。
    private func legacyCanonical(text: String, structuredContent: JSONValue?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if let structuredContent { fields["structuredContent"] = structuredContent }
        return .object(fields)
    }

    /// dsh :349-354 主路径 canonical：`{content, structuredContent?}`。
    private func canonicalMeta(content: [JSONValue], structuredContent: JSONValue?) throws -> JSONValue {
        var fields: [String: JSONValue] = ["content": .array(content)]
        if let structuredContent { fields["structuredContent"] = structuredContent }
        return .object(fields)
    }

    /// dsh :325-328 legacy 文本：'toolResult' in result → JSON.stringify 值
    /// （恒 string——null→"null"、object→JSON 文本）；否则/失败→'(no output)'。
    private func legacyText(_ result: RawCallTool.Result) -> String {
        guard result.hasToolResult, let toolResult = result.toolResult else {
            return "(no output)"
        }
        guard let data = try? JSONEncoder().encode(toolResult),
              let text = String(data: data, encoding: .utf8) else {
            return "(no output)"
        }
        return text
    }
}

// MARK: - JSONValue → Value 桥（arguments 转换）

extension Value {
    /// WanWo JSONValue → SDK Value（经 Codable lossless 往返；签名 throws
    /// 仅为 fail closed 严谨，实际不可失败）。
    init(_ json: JSONValue) throws {
        let data = try JSONEncoder().encode(json)
        self = try JSONDecoder().decode(Value.self, from: data)
    }
}
