//
//  RequestProjection.swift
//  WanWo
//
//  【语义移植 · dsh · 纯函数层】出处：
//    · packages/attachment/attachment/src/request-projection.ts
//      （requestImageDimensions 几何 1:1：保比/总像素预算/inward/小图不放大）
//    · attachment-local/src/encoding.ts（IMAGE_ENCODING_QUALITIES 阶梯 +
//      encodeFirstWithinLimit「首个达标即停，否则保留最小产出」语义）
//    · attachment-local/src/request-image.ts（variantId 确定性身份 descriptor：
//      变换版本 + attachmentId + 路由像素/字节预算 + 编码器参数全量入列）
//  无 IO、无状态：单测直呼（CI 测试轨道已拆——自测=逻辑推演+锚点核对）。
//

import Foundation
import CryptoKit

/// 阶梯单档产出（encoding.ts:11-16 EncodedImage 1:1）。
struct EncodedImage: Equatable, Sendable {
    var data: Data
    var mediaType: ImageMediaType
    var width: Int
    var height: Int
}

enum RequestProjection {
    /// 质量阶梯（encoding.ts:6 IMAGE_ENCODING_QUALITIES = [85, 75, 60] 1:1
    /// ——各档拉开真实体积差）。
    static let qualities: [Int] = [85, 75, 60]

    /// 请求变换版本（request-image.ts:25 REQUEST_IMAGE_TRANSFORM_VERSION 语义；
    /// WanWo 编码器栈 = ImageIO JPEG/PNG，版本独立起名——dsh sharp 栈的
    /// request-image-v5 不混用）。
    static let transformVersion = "wanwo-request-image-v1"

    /// 保比整数投影（request-projection.ts:13-36 1:1）：
    /// scale = min(1, sqrt(max/(w*h)))；scale==1 直接原样（小图不放大）；
    /// inward 取整（宽/高主导分支各一），Math.round = 四舍五入远离零（正值域
    /// 与 Swift .rounded() 同义），Math.floor = .rounded(.down)；
    /// 投影后仍超预算则长边逐像素递减重算短边，直至达标或触底 1。
    static func requestImageDimensions(width: Int,
                                       height: Int,
                                       maxPixels: Int) -> (width: Int, height: Int) {
        precondition(width > 0 && height > 0 && maxPixels > 0,
                     "requestImageDimensions requires positive inputs")
        let scale = min(1.0, (Double(maxPixels) / Double(width * height)).squareRoot())
        if scale == 1.0 { return (width, height) }
        if width >= height {
            var projectedWidth = max(1, Int((Double(width) * scale).rounded(.down)))
            var projectedHeight = max(
                1, Int((Double(projectedWidth * height) / Double(width)).rounded()))
            while projectedWidth * projectedHeight > maxPixels && projectedWidth > 1 {
                projectedWidth -= 1
                projectedHeight = max(
                    1, Int((Double(projectedWidth * height) / Double(width)).rounded()))
            }
            return (projectedWidth, projectedHeight)
        }
        var projectedHeight = max(1, Int((Double(height) * scale).rounded(.down)))
        var projectedWidth = max(
            1, Int((Double(projectedHeight * width) / Double(height)).rounded()))
        while projectedWidth * projectedHeight > maxPixels && projectedHeight > 1 {
            projectedHeight -= 1
            projectedWidth = max(
                1, Int((Double(projectedHeight * width) / Double(height)).rounded()))
        }
        return (projectedWidth, projectedHeight)
    }

    /// 阶梯执行（encoding.ts:56-72 encodeFirstWithinLimit 1:1）：
    /// 按偏好序惰性执行编码候选，首个 ≤maxBytes 即停；全部超限保留最小产出
    /// （dsh 语义：provider 字节上限由传输该字节的路由继续执行）。
    static func encodeFirstWithinLimit(_ attempts: [() throws -> EncodedImage],
                                       maxBytes: Int) throws -> EncodedImage {
        guard let first = attempts.first else {
            throw AttachmentError(message: "image encoding requires at least one candidate",
                                  code: "INVALID_IMAGE")
        }
        var smallest = try first()
        if smallest.data.count <= maxBytes { return smallest }
        for attempt in attempts.dropFirst() {
            let candidate = try attempt()
            if candidate.data.count <= maxBytes { return candidate }
            if candidate.data.count < smallest.data.count { smallest = candidate }
        }
        return smallest
    }

    /// 请求变体确定性身份（request-image.ts:54-81 descriptor/requestImageVariantId
    /// 1:1 语义：变换版本 + attachmentId + 路由像素/字节预算 + 编码器参数全量
    /// 入列，SHA-256 寻址——同 ref + 同 policy 恒同变体，缓存与上传索引同键）。
    static func requestImageVariantId(ref: ImageAttachmentRef,
                                      policy: ImageRequestPolicy) -> String {
        // sortedKeys：descriptor 字节确定性与键序无关（JS JSON.stringify 按插入序，
        // Swift 端以排序键固定——descriptor 是内部身份，跨栈字节不必逐位同）。
        let encoding: [String: Any] = [
            "colourspace": "srgb",
            "jpegQualities": qualities,
            "order": ["alpha:png", "opaque:jpeg"],
        ]
        let descriptor: [String: Any] = [
            "transformVersion": transformVersion,
            "attachmentId": ref.attachmentId,
            "routePixelBudget": policy.maxPixels,
            "encodedByteBudget": policy.maxBytes,
            "encoding": encoding,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: descriptor,
                                                options: [.sortedKeys])) ?? Data()
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
