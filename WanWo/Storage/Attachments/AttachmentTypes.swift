//
//  AttachmentTypes.swift
//  WanWo
//
//  【语义移植 · dsh】出处：packages/attachment/attachment/src/types.ts（附件词汇）
//  + error.ts（错误码闭集）+ attachment-local/src/index.ts:28-52（部署默认限制
//  ——dsh 源码硬编码默认值 1:1 取值，非自造）。
//  F042 附件系统（图片）：dsh attachment 包 = 纯图片附件（EncodedImageAttachment
//  族，无文件上传——文件上传属 M9.7 侧聊，本批不做，范围红线）。
//

import Foundation

/// 栅格图片格式闭集（types.ts:8 ImageMediaType 1:1）。
enum ImageMediaType: String, Equatable, Codable, Sendable, CaseIterable {
    case png = "image/png"
    case jpeg = "image/jpeg"
    case webp = "image/webp"
    case gif = "image/gif"
}

/// 附件失败（error.ts:40-54 AttachmentError 语义：code 稳定机器路由，
/// 文案不含原始字节与宿主路径；WanWo Native 化为 struct——消费按 code 路由，
/// 不按类型链，error.ts:38 注释原文语义）。
struct AttachmentError: Error, Equatable, Sendable {
    let message: String
    let code: String
}

/// 准入错误码闭集（error.ts:3-13 1:1——错误横幅按 code 路由）。
enum ImageAdmissionErrorCode {
    static let all: Set<String> = [
        "TOO_MANY_IMAGES", "IMAGES_TOO_LARGE", "UNSUPPORTED_IMAGE_TYPE",
        "INVALID_IMAGE_BASE64", "INVALID_IMAGE", "IMAGE_TYPE_MISMATCH",
        "IMAGE_TOO_LARGE", "IMAGE_TOO_MANY_PIXELS", "IMAGE_DIMENSION_TOO_LARGE",
    ]
}

/// 图片尺寸对（types.ts originalDimensions 形状）。
struct ImageDimensions: Equatable, Codable, Sendable {
    var width: Int
    var height: Int
}

/// 持久化归一化图片引用（types.ts:11-32 ImageAttachmentRef 1:1）。
/// 随 E1 extensionEvent（kind "attachment/images"）进会话日志；呈现与请求两侧共用。
/// 字段语义：
///   · attachmentId = "sha256:<hex>"（不透明存储标识，永非文件系统路径）；
///   · mediaType = 从存储字节核实过的类型；
///   · originalDimensions = EXIF 方向应用后、归一化缩放前的输入尺寸（仅缩小时在场）。
struct ImageAttachmentRef: Equatable, Codable, Sendable, Identifiable {
    /// Identifiable：attachmentId 即身份（content-addressed——同 id = 同字节图）；
    /// SwiftUI fullScreenCover(item:) 等以引用为身份的场景共用。
    var id: String { attachmentId }
    var attachmentId: String
    var mediaType: ImageMediaType
    var bytes: Int
    var width: Int
    var height: Int
    var name: String?
    var originalDimensions: ImageDimensions?
}

/// 部署解析的图片上传限制（types.ts:35-43；默认值 = attachment-local
/// index.ts:28-36 硬编码默认 1:1——20MiB / 20 张 / 200MiB / 64M 像素 / 8192px）。
struct ImageAttachmentLimits: Equatable, Sendable {
    var maxImageBytes = 20 * 1024 * 1024
    var maxImagesPerMessage = 20
    var maxMessageImageBytes = 200 * 1024 * 1024
    var maxImagePixels = 64_000_000
    var maxImageDimension = 8192
    var mediaTypes: [ImageMediaType] = [.png, .jpeg, .webp, .gif]
}

/// 归一化存储策略（normalization.ts:11-18 NormalizationPolicy 1:1；默认 =
/// attachment-local index.ts:44-48 硬编码默认 1:1——2048² / 8192 / 4MiB）。
struct NormalizationPolicy: Equatable, Sendable {
    var maxPixels = 2048 * 2048
    var maxDimension = 8192
    var maxBytes = 4 * 1024 * 1024
}

/// 路由拥有的请求图片策略（types.ts:91-96 ImageRequestPolicy 1:1——
/// maxPixels = 保比投影后的总像素上限；maxBytes = base64 展开前的编码字节目标，
/// 无档位达标时保留最小档产出）。
struct ImageRequestPolicy: Equatable, Sendable {
    var maxPixels: Int
    var maxBytes: Int
}

/// 请求变体（types.ts:99-116 RequestImageAttachment 消费子集——WanWo 请求侧
/// 只消费 bytes/mediaType/尺寸；depth='uchar'/space='srgb' 由 iOS 编码器
/// （8-bit sRGB 位图上下文 + JPEG/PNG）构造性保证）。
struct RequestImageAttachment: Equatable, Sendable {
    var variantId: String
    var attachment: ImageAttachmentRef
    var data: Data
    var mediaType: ImageMediaType
    var width: Int
    var height: Int
}
