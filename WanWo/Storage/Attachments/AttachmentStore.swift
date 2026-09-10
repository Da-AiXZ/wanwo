//
//  AttachmentStore.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    · attachment/attachment/src/index.ts:40-147（AttachmentStore 服务缝：
//      validateImageBatch 批次策略 → saveImages 顺序提交 → readImage 校验读取）
//    · attachment-local/src/store.ts（content-addressed 发布/读取校验：
//      prepareImageFile 归一化+digest / commitPreparedImageFile 原子发布+EEXIST
//      去重回核 / readImageFile digest+头探测回核）
//    · attachment-local/src/request-image.ts（readRequestImageFile：variantId
//      寻址的请求变体缓存 + createRequestImage 投影/阶梯编码）
//  存储根 = WanWoPaths.sessionPersistentDir(for: sid, bucket: "attachments")
//  （会话隔离对齐 WanWoPaths session bucket 惯例）：
//    objects/<sha2前缀>/<sha256>    归一化对象（content-addressed，发布后只读）
//    request-images/<hash2>/<hash>  请求变体缓存（variantId 寻址）
//  E1 注册：extension kind "attachment/images"（userMessage 专用 case 冻结
//  不动——附件引用随归属 userMessage 紧随走 extensionEvent 通道）。
//  路径卫生：content-addressed 寻址（digest hex，恒 [0-9a-f]）天然免疫
//  `..`/分隔符注入——显示名 name 永不参与寻址（store.ts displayName 剥离
//  路径成分后仅作呈现）。
//

import Foundation
import CryptoKit

/// 单图存储输入（types.ts:76-82 SaveImageAttachment 1:1）。
struct SaveImageAttachment: Sendable {
    var data: Data
    var mediaType: ImageMediaType
    var name: String?
}

/// 归一化产物（store.ts:85-90 PreparedImageFile 1:1）。
struct PreparedImage: Sendable {
    var data: Data
    var ref: ImageAttachmentRef
}

final class AttachmentStore: @unchecked Sendable {
    // MARK: E1 extension 事件（userMessage 后紧随，携带该消息图片引用集）
    static let imagesEventKind = "attachment/images"

    /// 路由请求策略（types.ts ImageRequestPolicy = route-owned 部署决策，dsh
    /// 源码无硬编码默认——WanWo 取与归一化策略同预算 2048² / 4MiB，呈报项）。
    static let requestPolicy = ImageRequestPolicy(maxPixels: 2048 * 2048,
                                                  maxBytes: 4 * 1024 * 1024)
    /// 压缩并发（attachment-local index.ts:50 默认 2）。
    static let compressionConcurrency = 2

    let imageLimits: ImageAttachmentLimits
    let normalizationPolicy: NormalizationPolicy
    let root: URL
    private let limiter: CompressionLimiter

    /// 注册 E1 schema（进程级一次；fail loud 同 registry 纪律）。
    private static let registrationOnce: Void = {
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: AttachmentStore.imagesEventKind,
            requiredFields: [
                ExtensionFieldSchema("seq", .int),
                ExtensionFieldSchema("images", .array),
            ],
            // logOnly：DeriveFold/ConversationProjector 对本 kind 做专属挂接
            //（回填 userMessage），不走 <extension-event> 通用信封。
            projection: .logOnly,
            pairing: .none))
    }()

    /// - Parameters:
    ///   - sessionId: 会话 id（root = session bucket attachments/）。
    ///   - limits: 部署限制（默认 = dsh 硬编码默认；测试注入收窄值）。
    ///   - policy: 归一化策略（同上）。
    init(sessionId: String,
         limits: ImageAttachmentLimits = ImageAttachmentLimits(),
         policy: NormalizationPolicy = NormalizationPolicy()) {
        self.root = WanWoPaths.sessionPersistentDir(for: sessionId, bucket: "attachments")
        self.imageLimits = limits
        self.normalizationPolicy = policy
        self.limiter = CompressionLimiter(concurrency: Self.compressionConcurrency)
        _ = Self.registrationOnce
    }

    /// 测试注根构造（root 可注入——单测落临时目录）。
    init(root: URL,
         limits: ImageAttachmentLimits = ImageAttachmentLimits(),
         policy: NormalizationPolicy = NormalizationPolicy()) {
        self.root = root
        self.imageLimits = limits
        self.normalizationPolicy = policy
        self.limiter = CompressionLimiter(concurrency: Self.compressionConcurrency)
        _ = Self.registrationOnce
    }

    // MARK: - 批次准入（index.ts:64-92 语义）

    /// 批次预检（index.ts:64-78 validateImageBatch 1:1：数量/聚合字节/媒体类型
    /// 白名单；任一失败整批拒绝，不开始任何写入）。
    func validateImageBatch(_ inputs: [SaveImageAttachment]) throws {
        if inputs.count > imageLimits.maxImagesPerMessage {
            throw AttachmentError(
                message: "Image batch exceeds the configured image-count limit.",
                code: "TOO_MANY_IMAGES")
        }
        let totalBytes = inputs.reduce(0) { $0 + $1.data.count }
        if totalBytes > imageLimits.maxMessageImageBytes {
            throw AttachmentError(
                message: "Image batch exceeds the configured aggregate image-byte limit.",
                code: "IMAGES_TOO_LARGE")
        }
        for input in inputs where !imageLimits.mediaTypes.contains(input.mediaType) {
            throw AttachmentError(
                message: "Image type \(input.mediaType.rawValue) is not accepted by this deployment.",
                code: "UNSUPPORTED_IMAGE_TYPE")
        }
    }

    /// 校验并顺序提交（index.ts:85-92 saveImages 语义：全批校验通过后逐个
    /// 发布；返回引用与输入同序）。
    func saveImages(_ inputs: [SaveImageAttachment]) throws -> [ImageAttachmentRef] {
        try validateImageBatch(inputs)
        return try inputs.map { try saveImage($0) }
    }

    // MARK: - 单图（store.ts prepare/commit 语义）

    /// 校验并持久化单图：字节帽 → 全解码检测（含声明比对/像素帽/单边帽）→
    /// 归一化 → digest 寻址原子发布（store.ts:264-271 saveImageFile 语义）。
    /// - Returns: content-addressed 归一化图片引用（可进会话日志）。
    @discardableResult
    func saveImage(_ input: SaveImageAttachment) throws -> ImageAttachmentRef {
        let prepared = try limiter.run { [limits = imageLimits, policy = normalizationPolicy] in
            try Self.prepareImage(input, limits: limits, policy: policy)
        }
        return try commitPrepared(prepared)
    }

    /// 准备（store.ts:99-124 prepareImageFile 1:1；静态纯函数——单测直呼）。
    static func prepareImage(_ input: SaveImageAttachment,
                             limits: ImageAttachmentLimits,
                             policy: NormalizationPolicy) throws -> PreparedImage {
        if input.data.count > limits.maxImageBytes {
            throw AttachmentError(message: "Image exceeds the configured byte limit.",
                                  code: "IMAGE_TOO_LARGE")
        }
        let detected = try ImageOperations.detectImage(
            input.data, declared: input.mediaType,
            maxPixels: limits.maxImagePixels, maxDimension: limits.maxImageDimension)
        let normalized = try ImageOperations.normalizeImage(
            input.data, detected: detected, policy: policy)
        let sha256 = sha256Hex(normalized.data)
        let name = displayName(input.name)
        let downscaled = detected.width != normalized.width
            || detected.height != normalized.height
        return PreparedImage(
            data: normalized.data,
            ref: ImageAttachmentRef(
                attachmentId: "sha256:\(sha256)",
                mediaType: normalized.mediaType,
                bytes: normalized.data.count,
                width: normalized.width,
                height: normalized.height,
                name: name,
                originalDimensions: downscaled
                    ? ImageDimensions(width: detected.width, height: detected.height)
                    : nil))
    }

    /// 原子发布（store.ts:191-254 commitPreparedImageFile 语义对位）：
    /// digest/字节双重回核 → 目标已存在（去重路径）重核既有对象 digest →
    /// 否则 [.atomic] 写入（Foundation 原子写 = 暂存 + rename，单写者沙盒内
    /// 等价 dsh 硬链发布 + 目录 fsync 段——iOS 单进程写者，呈报）。
    private func commitPrepared(_ prepared: PreparedImage) throws -> ImageAttachmentRef {
        let sha256 = Self.sha256Hex(prepared.data)
        guard prepared.ref.attachmentId == "sha256:\(sha256)",
              prepared.ref.bytes == prepared.data.count else {
            throw AttachmentError(
                message: "Prepared attachment bytes do not match their reference.",
                code: "ATTACHMENT_CORRUPT")
        }
        let target = Self.objectPath(root: root, sha256: sha256)
        if FileManager.default.fileExists(atPath: target.path) {
            // 去重路径（store.ts:221-224 EEXIST 分支对位）。
            if let existing = try? Data(contentsOf: target),
               Self.sha256Hex(existing) == sha256 {
                return prepared.ref
            }
            throw AttachmentError(
                message: "Stored attachment failed integrity verification.",
                code: "ATTACHMENT_CORRUPT")
        }
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try prepared.data.write(to: target, options: [.atomic])
        } catch {
            throw AttachmentError(message: "Unable to persist image attachment.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        return prepared.ref
    }

    /// 读取 + 校验（store.ts:281-308 readImageFile 1:1：digest 回核 + 头探测
    /// 回核引用字段——不再付全栅格解码）。
    func readImage(_ ref: ImageAttachmentRef) throws -> (ref: ImageAttachmentRef, data: Data) {
        guard let sha256 = Self.sha256Hex(of: ref) else {
            throw AttachmentError(message: "Attachment reference is invalid.",
                                  code: "INVALID_ATTACHMENT_REF")
        }
        let target = Self.objectPath(root: root, sha256: sha256)
        guard let data = try? Data(contentsOf: target) else {
            throw AttachmentError(message: "Attachment object is missing.",
                                  code: "ATTACHMENT_NOT_FOUND")
        }
        if Self.sha256Hex(data) != sha256 || data.count != ref.bytes {
            throw AttachmentError(message: "Stored attachment failed integrity verification.",
                                  code: "ATTACHMENT_CORRUPT")
        }
        let probed = try ImageOperations.probeImage(data)
        if probed.mediaType != ref.mediaType || probed.width != ref.width
            || probed.height != ref.height {
            throw AttachmentError(
                message: "Stored attachment metadata does not match its reference.",
                code: "ATTACHMENT_CORRUPT")
        }
        return (ref, data)
    }

    // MARK: - 请求变体（request-image.ts 语义）

    /// 生成或复用一个确定性请求版本（request-image.ts:176-207
    /// readRequestImageFile 1:1 语义）：variantId 寻址缓存命中且校验通过即读；
    /// 否则投影/阶梯编码后写缓存。同 ref + 同 policy 恒同字节（会话内前缀
    /// 稳定的前提）。
    func readRequestImage(_ ref: ImageAttachmentRef,
                          policy: ImageRequestPolicy = AttachmentStore.requestPolicy)
        throws -> RequestImageAttachment {
        let stored = try readImage(ref)
        let variantId = RequestProjection.requestImageVariantId(ref: ref, policy: policy)
        let hash = String(variantId.dropFirst("sha256:".count))
        let cachePath = Self.requestImagePath(root: root, hash: hash)
        if let cached = try? Data(contentsOf: cachePath),
           let verified = try? Self.verifyRequestCandidate(cached, ref: ref, policy: policy) {
            return RequestImageAttachment(variantId: variantId, attachment: ref,
                                          data: cached, mediaType: verified.mediaType,
                                          width: verified.width, height: verified.height)
        }
        let created = try limiter.run { [limitsData = stored.data] in
            try Self.createRequestImage(storedData: limitsData, ref: ref, policy: policy)
        }
        // 缓存写入尽力而为（失败不致命——下次请求重算；request-image.ts:194
        // 同口径）。
        try? FileManager.default.createDirectory(
            at: cachePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? created.data.write(to: cachePath, options: [.atomic])
        return RequestImageAttachment(variantId: variantId, attachment: ref,
                                      data: created.data, mediaType: created.mediaType,
                                      width: created.width, height: created.height)
    }

    /// 请求版本生成（request-image.ts:92-113 createRequestImage 1:1）：
    /// 投影后尺寸与原尺寸一致且字节达标 → 原样透传；否则按源 alpha 走阶梯
    /// （encodingLadder(pipeline, hasAlpha) 对位）取首个达标，无达标取最小。
    static func createRequestImage(storedData: Data,
                                   ref: ImageAttachmentRef,
                                   policy: ImageRequestPolicy) throws -> EncodedImage {
        let dimensions = RequestProjection.requestImageDimensions(
            width: ref.width, height: ref.height, maxPixels: policy.maxPixels)
        if dimensions.width == ref.width && dimensions.height == ref.height
            && storedData.count <= policy.maxBytes {
            return EncodedImage(data: storedData, mediaType: ref.mediaType,
                                width: ref.width, height: ref.height)
        }
        let detected = try ImageOperations.probeImage(storedData)
        let raster = try ImageOperations.orientedSRGBImage(storedData)
        let resized = try ImageOperations.resizedImage(
            raster, width: dimensions.width, height: dimensions.height)
        let attempts = ImageOperations.encodeLadder(resized, hasAlpha: detected.hasAlpha)
        return try RequestProjection.encodeFirstWithinLimit(attempts, maxBytes: policy.maxBytes)
    }

    /// 缓存候选校验（request-image.ts:119-139 readCached 对位：头探测回核
    /// ——类型为请求编码产物族、尺寸不超投影上限；alpha/深度兼容性由本栈
    /// 编码器构造性保证，回核从简）。
    static func verifyRequestCandidate(_ data: Data,
                                       ref: ImageAttachmentRef,
                                       policy: ImageRequestPolicy)
        throws -> (mediaType: ImageMediaType, width: Int, height: Int) {
        let probed = try ImageOperations.probeImage(data)
        let maximum = RequestProjection.requestImageDimensions(
            width: ref.width, height: ref.height, maxPixels: policy.maxPixels)
        guard probed.mediaType != .gif, probed.width <= maximum.width,
              probed.height <= maximum.height else {
            throw AttachmentError(message: "Cached request image failed verification.",
                                  code: "ATTACHMENT_CORRUPT")
        }
        return (probed.mediaType, probed.width, probed.height)
    }

    // MARK: - 寻址与名称

    /// 对象路径（store.ts:51-54 normalizedImagePath 1:1：objects/<sha2前缀>/<sha256>）。
    static func objectPath(root: URL, sha256: String) -> URL {
        root.appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(sha256)
    }

    /// 请求缓存路径（request-image.ts:115-117 cachePath 1:1）。
    static func requestImagePath(root: URL, hash: String) -> URL {
        root.appendingPathComponent("request-images", isDirectory: true)
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent(hash)
    }

    /// 引用解析（store.ts:22/:39-43 ID_PATTERN 语义：sha256: + 64 位 hex）。
    static func sha256Hex(of ref: ImageAttachmentRef) -> String? {
        guard ref.attachmentId.hasPrefix("sha256:") else { return nil }
        let hex = String(ref.attachmentId.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex.lowercased()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 显示名清洗（store.ts:29-37 displayName 1:1：两种分隔符均剥——POSIX 宿主
    /// 视 `\` 为普通字符，手剥防 Windows 客户端全路径泄漏；控制字符剔除 +
    /// trim + 255 截断；空串归 nil）。
    static func displayName(_ value: String?) -> String? {
        guard var leaf = value else { return nil }
        if let slashIndex = leaf.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            leaf = String(leaf[leaf.index(after: slashIndex)...])
        }
        let clean = String(leaf.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7f })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }
        return String(clean.prefix(255))
    }

    // MARK: - E1 载荷编解码

    private struct ImagesPayload: Codable {
        var seq: Int
        var images: [ImageAttachmentRef]
    }

    /// refs → E1 载荷（字段名对齐 dsh ImageAttachmentRef wire 形态）。
    static func refsJSONPayload(seq: Int, refs: [ImageAttachmentRef]) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(ImagesPayload(seq: seq, images: refs)) else {
            return nil
        }
        return JSONValue(data: data)
    }

    /// E1 载荷 → refs（消费侧 fail closed：解析失败由调用方整条丢弃——
    /// 呈现退化为纯文本、派生历史不含损坏引用）。
    static func refsFromPayload(_ payload: JSONValue) -> (seq: Int, refs: [ImageAttachmentRef])? {
        guard let data = try? JSONEncoder().encode(payload),
              let decoded = try? JSONDecoder().decode(ImagesPayload.self, from: data) else {
            return nil
        }
        return (decoded.seq, decoded.images)
    }
}
