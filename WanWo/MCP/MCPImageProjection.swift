//
//  MCPImageProjection.swift
//  WanWo
//
//  【M4-A 件6 · 图片准入投影】dsh tools.ts 移植（出处：
//  packages/mcp/mcp-client/src/tools.ts）：
//    · :374-377 isImageMediaType（IMAGE_MEDIA_TYPES 四类型白名单）；
//    · :379-392 decodeImage（canonical base64 双校验：CANONICAL_BASE64 正则
//      + 回编等值；拒绝文案逐字）；
//    · :400-421 resolveImageAdmission（五条拒绝文案逐字；
//      exec.signal.aborted → Task.isCancelled，放行指令指定形态）；
//    · :434-488 prepareImageProjection（解码收集 → validationErrors 非空
//      全降级（兜底文案 :458）→ admission 失败全降级 → saveImages 成功
//      byIndex 原位回填 → 失败按 isImageAdmissionError 判定降级）；
//    · error.ts isImageAdmissionError（鸭子判定的 Swift 协议承载，呈报④）。
//  缝契约（件5 已定）：project(content:rawName:context:) -> (text, meta?)；
//  meta 非 nil 整体替换 ToolOutput.meta、nil 沿用 canonical。本实现恒返回
//  meta=nil——canonical 保留原始 image 块（含 base64）= dsh :431-433「while
//  retaining the canonical raw value for programmatic callers」字面实现。
//  平台适配（汇报逐项呈报）：
//    ①resolveModelInfo 无同形 API（WanWo LLM 层/SessionModelSelection/
//      ToolExecutionContext 三处均无模型能力查询通道）→ 路由能力校验以注入
//      闭包表达，本文件只做裁决→dsh 文案映射，不自造语义；生产装配在能力
//      通道落地前恒返回 .unverifiable = fail closed 拒图；
//    ②saveImages 为 sync throws（F042 既有形态，dsh :473 await 的对应=
//      直接调用）；
//    ③dsh 成功路径产 {type:'image', attachment: ref} 内容块进模型上下文，
//      WanWo ToolOutput 模型侧单文本 → 成功位=自创占位文案（呈报裁决）；
//    ④isImageAdmissionError 鸭子判定（任意 Error 携带 string code 且命中
//      闭集）→ MCPImageCodedError 协议承载。
//

import Foundation

// MARK: - 路由能力裁决缝（resolveImageAdmission :403-418 的 WanWo 形态）

/// dsh :403-418 路由解析+resolveModelInfo 校验的裁决词汇（呈报①：WanWo
/// 无 resolveModelInfo 同形 API——本枚举只承载校验结果，语义归注入方）。
enum MCPImageRouteVerdict: Sendable, Equatable {
    /// dsh :407-409——provider/model/llm 有其一缺失。
    case unresolved
    /// dsh :411-415——resolveModelInfo 抛错。
    case unverifiable
    /// dsh :416-418——info.inputModalities 不含 image。
    case noImageInput(model: String)
    /// 全部校验通过（exact positive image-capability proof，:398 注释）。
    case verified
}

/// dsh exec（工具执行现场的 agent 路由）→ 裁决的注入缝。ToolExecutionContext
/// 即 exec 的 WanWo 形态；生产装配在能力通道落地前恒返回 .unverifiable
/// （fail closed，六红线⑤）。
typealias MCPImageRouteResolving = @Sendable (ToolExecutionContext) async -> MCPImageRouteVerdict

// MARK: - 拒绝错误

/// dsh decodeImage/resolveImageAdmission 的拒绝错误（dsh plain `new Error`：
/// 文案即全部语义；非 AttachmentError——不参与 isImageAdmissionError 判定）。
struct MCPImageAdmissionRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    /// dsh `new Error(message)` 调用形态 1:1（无标签构造；memberwise 只有
    /// `init(message:)`——CI 工具链实证）。
    init(_ message: String) { self.message = message }
}

// MARK: - 投影器（tools.ts:434-488 prepareImageProjection 1:1）

/// dsh prepareImageProjection 的 MCPImageProjecting 实现：严格解码（canonical
/// base64 双校验+四媒体类型）→准入校验（store 挂载+路由能力裁决+取消检查）
/// →saveImages→按原位置产出图片呈现；任一环节失败→全部图片降级为文本诊断
/// （MCPToolExecutor.imageDiagnostic 文案复用）。投影无日志（dsh 同，零日志）。
final class MCPImageProjector: MCPImageProjecting, Sendable {

    /// dsh ctx.get('attachments')（:401）；nil = 未挂载。
    private let attachmentStore: AttachmentStore?
    /// dsh :403-412 路由解析+resolveModelInfo 的注入缝（呈报①）。
    private let routeResolver: MCPImageRouteResolving

    /// - Parameters:
    ///   - attachmentStore: 当前会话附件存储；nil = 'no attachment store is
    ///     mounted'（:402）。
    ///   - routeResolver: 模型路由能力裁决（exec.agent 路由 :403-405 +
    ///     resolveModelInfo :410-418 的缝化）。
    init(attachmentStore: AttachmentStore?,
         routeResolver: @escaping MCPImageRouteResolving) {
        self.attachmentStore = attachmentStore
        self.routeResolver = routeResolver
    }

    // MARK: 缝契约（件5 已定：meta 非 nil 整体替换、nil 沿用 canonical）

    func project(content: [JSONValue], rawName: String,
                 context: ToolExecutionContext) async -> (text: String, meta: JSONValue?) {
        // context 不直接消费：dsh 经 exec 取 agent 路由（:403-405），WanWo
        // 形态=路由随 context 传入注入缝（呈报①——生产装配闭包按需取用）。

        // :440-452——解码收集：跳过非 image 块（:444），原位 index 记录，
        // 解码失败按 index 归集（decodeImage 拥有全部 throw 且恒 Error，
        // :449 注释——文案即诊断语义）。
        var decoded: [SaveImageAttachment] = []
        var validationErrors: [Int: String] = [:]
        var imageIndexes: [Int] = []
        for (index, value) in content.enumerated() {
            guard let block = value.objectValue,
                  block["type"]?.stringValue == "image" else { continue }   // :444
            imageIndexes.append(index)
            do {
                decoded.append(try Self.decodeImage(block))
            } catch {
                validationErrors[index] = Self.errorMessage(error)
            }
        }

        // :453-461——任一解码失败→全部图片降级（无效图按各自文案、其余图
        // 兜底 'another image in the same result was invalid' :458）。
        if !validationErrors.isEmpty {
            let text = Self.projectedText(content, rawName: rawName) { block, index in
                MCPToolExecutor.imageDiagnostic(
                    block,
                    validationErrors[index]
                        ?? "another image in the same result was invalid")
            }
            return (text, nil)
        }

        // :463-470——准入解析失败（store 缺失/路由不可证/已取消）→全降级。
        let store: AttachmentStore
        do {
            store = try await Self.resolveImageAdmission(
                attachmentStore: attachmentStore, routeResolver: routeResolver,
                context: context)
        } catch {
            let reason = Self.errorMessage(error)
            let text = Self.projectedText(content, rawName: rawName) { block, _ in
                MCPToolExecutor.imageDiagnostic(block, reason)
            }
            return (text, nil)
        }

        // :472-487——持久化 + byIndex 原位回填。
        do {
            let refs = try store.saveImages(decoded)    // :473（sync throws——呈报②）
            // :474——refs 与 decoded 同序同长契约（store.saveImages 返回值
            // 与输入同序，AttachmentStore.saveImages 语义）；缺位=契约破缺，
            // 防御降级为存储故障文案（fail closed，不静默吞）。
            var byIndex: [Int: ImageAttachmentRef] = [:]
            for (offset, index) in imageIndexes.enumerated() {
                byIndex[index] = refs[offset]
            }
            let text = Self.projectedText(content, rawName: rawName) { block, index in
                guard let ref = byIndex[index] else {
                    return MCPToolExecutor.imageDiagnostic(
                        block, "durable image storage rejected the result")
                }
                // 成功位（呈报③）：dsh :475-478 产 {type:'image',
                // attachment: ref} 内容块进模型上下文；WanWo 模型侧单文本
                // →自创占位（attachmentId content-addressed 可寻址）。
                return Self.savedImagePlaceholder(ref)
            }
            return (text, nil)
        } catch {
            // :479-486——isImageAdmissionError 判定（error.ts 鸭子语义，
            // 呈报④）：准入失败携带 error.message，存储故障用固定文案。
            let reason = Self.isImageAdmissionError(error)
                ? "image admission rejected the result: \(Self.errorMessage(error))"
                : "durable image storage rejected the result"
            let text = Self.projectedText(content, rawName: rawName) { block, _ in
                MCPToolExecutor.imageDiagnostic(block, reason)
            }
            return (text, nil)
        }
    }

    // MARK: 准入解析（tools.ts:400-421 resolveImageAdmission 1:1）

    /// - Returns: 经 store 挂载+路由能力+取消三重校验的附件存储。
    /// 五条拒绝文案逐字（:402/:408/:414/:417/:419）。
    private static func resolveImageAdmission(
        attachmentStore: AttachmentStore?,
        routeResolver: MCPImageRouteResolving,
        context: ToolExecutionContext
    ) async throws -> AttachmentStore {
        guard let attachments = attachmentStore else {
            throw MCPImageAdmissionRefusal("no attachment store is mounted")    // :402
        }
        switch await routeResolver(context) {                                   // :403-412
        case .unresolved:
            throw MCPImageAdmissionRefusal(
                "the current model route could not be resolved")                // :408
        case .unverifiable:
            throw MCPImageAdmissionRefusal(
                "the current model route could not be verified")                // :414
        case .noImageInput(let model):
            throw MCPImageAdmissionRefusal(
                "model \"\(model)\" does not declare image input")              // :417
        case .verified:
            break
        }
        // :419——exec.signal.aborted 的 WanWo 形态=Task.isCancelled
        // （放行指令指定）：saveImages 前最后检查。
        if Task.isCancelled {
            throw MCPImageAdmissionRefusal(
                "the tool call was canceled before image storage")              // :419
        }
        return attachments
    }

    // MARK: 严格解码（tools.ts:379-392 decodeImage 1:1）

    /// 解码单个不可信 MCP image 块，不容忍任何 base64 别名（:379 注释）。
    /// - Throws: MCPImageAdmissionRefusal（文案逐字 :382/:385/:389）。
    static func decodeImage(_ block: [String: JSONValue]) throws -> SaveImageAttachment {
        // :381-383——mimeType 白名单（IMAGE_MEDIA_TYPES 四类型，:374-377）。
        guard let mediaTypeRaw = block["mimeType"]?.stringValue,
              let mediaType = ImageMediaType(rawValue: mediaTypeRaw) else {
            throw MCPImageAdmissionRefusal(
                "the declared media type is not PNG, JPEG, WebP, or GIF")
        }
        // :384-386——data 在场 + CANONICAL_BASE64 正则校验。
        guard let dataRaw = block["data"]?.stringValue,
              isCanonicalBase64(dataRaw) else {
            throw MCPImageAdmissionRefusal("the image data is not canonical base64")
        }
        // :387-390——回编双校验（decode→re-encode 与原文等值）。
        guard let data = Data(base64Encoded: dataRaw),
              data.base64EncodedString() == dataRaw else {
            throw MCPImageAdmissionRefusal("the image data is not canonical base64")
        }
        // :391——name 不适用 MCP 块（dsh 返回 {data, mediaType} 二元组）。
        return SaveImageAttachment(data: data, mediaType: mediaType, name: nil)
    }

    /// dsh CANONICAL_BASE64
    /// `/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/`
    /// 的手写等价（避免 NSRegularExpression 语义漂移；空串匹配=零主体+
    /// 零尾组）。结构不变式：主体恒 4 字符字母表组、尾组（在场时）恒末
    /// 4 字符（'=' 只允许出现在尾组填充位）。
    static func isCanonicalBase64(_ value: String) -> Bool {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let chars = Array(value)
        let n = chars.count
        // 尾组恒 4 字符、主体恒 4 字符组→总长必为 4 的倍数。
        guard n % 4 == 0 else { return false }
        if n == 0 { return true }
        if chars[n - 1] == "=" {
            // '=' 在场→尾组必为末 4 字符（主体不含 '='）；2 字符+"==" 或
            // 3 字符+"=" 两种形态，其余 '=' 非法。
            let tailStart = n - 4
            guard tailStart >= 0,
                  chars[0..<tailStart].allSatisfy(alphabet.contains) else { return false }
            if chars[n - 2] == "=" {
                return alphabet.contains(chars[tailStart])
                    && alphabet.contains(chars[tailStart + 1])
            }
            return alphabet.contains(chars[tailStart])
                && alphabet.contains(chars[tailStart + 1])
                && alphabet.contains(chars[tailStart + 2])
        }
        return chars.allSatisfy(alphabet.contains)
    }

    // MARK: 判定与投影辅助

    /// dsh error.ts isImageAdmissionError（鸭子判定：任意 Error 携带 string
    /// `code` 且命中 IMAGE_ADMISSION_ERROR_CODE_SET 即 true——tests
    /// index.spec.ts「foreign Error + code」实证，非 instanceof AttachmentError）
    /// 的 Swift 承载（呈报④）：协议表达「携带 code」；WanWo 存储层唯一
    /// code 携带者=AttachmentError（retroactive conform），外来携带者按需续。
    static func isImageAdmissionError(_ error: any Error) -> Bool {
        guard let coded = error as? MCPImageCodedError else { return false }
        return ImageAdmissionErrorCode.all.contains(coded.admissionErrorCode)
    }

    /// dsh `(error as Error).message` 的 WanWo 形态：AttachmentError 取
    /// message 字段，CustomStringConvertible 取 description，兜底反射。
    private static func errorMessage(_ error: any Error) -> String {
        if let attachmentError = error as? AttachmentError {
            return attachmentError.message
        }
        if let described = error as? CustomStringConvertible {
            return described.description
        }
        return String(describing: error)
    }

    /// projectContent（件5 static）+ 换行归并=dsh :454/:469/:475/:483 四处
    /// 「projectContent(content, toolName, image:)」调用形态（件5 已证：
    /// 文本块换行归并+image 位占位切开与 dsh render+finalizeContent 管线
    /// 等价）。
    private static func projectedText(_ content: [JSONValue], rawName: String,
                                      image: @escaping (JSONValue, Int) -> String) -> String {
        MCPToolExecutor.projectContent(content, toolName: rawName, image: image)
            .joined(separator: "\n")
    }

    /// 成功位占位（呈报③——文案自创须裁决）：词汇复用 imageDiagnostic 尾句
    /// 「raw image data remains available to programmatic callers」（canonical
    /// meta 保留原始块，程序化侧可寻址同图）；attachmentId="sha256:<hex>"
    /// content-addressed（AttachmentTypes.swift 语义）。
    private static func savedImagePlaceholder(_ ref: ImageAttachmentRef) -> String {
        "[image saved: \(ref.mediaType.rawValue); attachment \(ref.attachmentId); " +
            "raw image data remains available to programmatic callers]"
    }
}

// MARK: - code 携带错误协议（error.ts 鸭子判定的 Swift 形态）

/// 「携带 string code 的错误」的 Swift 表达（呈报④）：dsh 以 `'code' in error
/// && typeof error.code === 'string'` 鸭子判定；Swift 无鸭子类型，以协议
/// 承载。WanWo 既有 AttachmentError retroactive conform。
protocol MCPImageCodedError: Error {
    var admissionErrorCode: String { get }
}

extension AttachmentError: MCPImageCodedError {
    var admissionErrorCode: String { code }
}
