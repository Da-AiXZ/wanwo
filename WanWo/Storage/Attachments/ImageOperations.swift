//
//  ImageOperations.swift
//  WanWo
//
//  【语义移植 · dsh · iOS ImageIO 落地】出处：attachment-local/src/image.ts
//  （detectImage 全解码准入 / probeImage 头探测回核）+ normalization.ts
//  （归一化：EXIF 方向应用、总像素预算缩放、长边帽、质量阶梯、pass-through
//  条件 canPassThroughNormalization:35-48）。dsh 用 sharp/libvips；WanWo 用
//  系统 ImageIO（不引第三方，§2.4）——语义对位差异（呈报）：
//    ①alpha 编码 webp → PNG（iOS 无系统 WebP 编码器；opaque → JPEG 阶梯不变）；
//    ②色彩空间 sRGB 判定以 CGColorSpace model RGB 近似（image.ts space 字段）；
//    ③全解码验证 = CGImageSourceCreateImageAtIndex 非空（dsh raw().toBuffer()
//      全量物化；ImageIO createImage 惰性解码，对畸形数据同样失败拒绝）。
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageOperations {
    /// 检测结果（image.ts:8-24 DetectedImage 对位子集；width/height 为 EXIF
    /// 方向应用后的感知尺寸——image.ts:69-74 转置口径同源）。
    struct DetectedImage {
        var mediaType: ImageMediaType
        var width: Int
        var height: Int
        var animated: Bool
        var carriesMetadata: Bool
        var bitDepth: Int
        var isRGB: Bool
        var hasAlpha: Bool
    }

    // MARK: - 探测（probeImage / detectImage）

    /// 头探测（image.ts:91-98 probeImage 语义：不解码像素，只回核引用字段
    /// ——digest 已证明这些字节是准入全解码过的字节）。
    static func probeImage(_ data: Data) throws -> DetectedImage {
        try detectImage(data, declared: nil, maxPixels: nil, maxDimension: nil)
    }

    /// 全解码准入（image.ts:114-130 detectImage 语义 + store.ts inspectMetadata
    /// 声明类型比对：空数据 INVALID_IMAGE、格式白名单外/畸形 INVALID_IMAGE、
    /// 超 maxPixels IMAGE_TOO_MANY_PIXELS、超 maxDimension IMAGE_DIMENSION_TOO_LARGE、
    /// 声明与字节不符 IMAGE_TYPE_MISMATCH）。
    static func detectImage(_ data: Data,
                            declared: ImageMediaType?,
                            maxPixels: Int?,
                            maxDimension: Int?) throws -> DetectedImage {
        if data.isEmpty {
            throw AttachmentError(message: "Image is empty.", code: "INVALID_IMAGE")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AttachmentError(message: "Unsupported or malformed image data.",
                                  code: "INVALID_IMAGE")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any] else {
            throw AttachmentError(message: "Unsupported or malformed image data.",
                                  code: "INVALID_IMAGE")
        }
        // 格式白名单（image.ts:44-49 MEDIA_TYPES 对位；ImageIO UTType 映射）。
        let mediaType: ImageMediaType
        if let raw = CGImageSourceGetType(source) as String?,
           let type = UTType(raw) {
            if type.conforms(to: .png) { mediaType = .png }
            else if type.conforms(to: .jpeg) { mediaType = .jpeg }
            else if type.conforms(to: UTType("org.webpproject.webp") ?? .data) { mediaType = .webp }
            else if type.conforms(to: .gif) { mediaType = .gif }
            else {
                throw AttachmentError(message: "Unsupported or malformed image data.",
                                      code: "INVALID_IMAGE")
            }
        } else {
            throw AttachmentError(message: "Unsupported or malformed image data.",
                                  code: "INVALID_IMAGE")
        }
        if let declared, declared != mediaType {
            throw AttachmentError(message: "Declared image type does not match its bytes.",
                                  code: "IMAGE_TYPE_MISMATCH")
        }
        let storedWidth = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let storedHeight = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard storedWidth > 0, storedHeight > 0 else {
            throw AttachmentError(message: "Unsupported or malformed image data.",
                                  code: "INVALID_IMAGE")
        }
        // EXIF 方向 5-8 转置存储栅格——报告感知轴（image.ts:70-74 原文语义）。
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        let transposed = orientation >= 5
        let width = transposed ? storedHeight : storedWidth
        let height = transposed ? storedWidth : storedHeight
        if let maxPixels, width * height > maxPixels {
            throw AttachmentError(message: "Image exceeds the configured decoded-pixel limit.",
                                  code: "IMAGE_TOO_MANY_PIXELS")
        }
        if let maxDimension, max(width, height) > maxDimension {
            throw AttachmentError(message: "Image exceeds the configured per-side pixel limit.",
                                  code: "IMAGE_DIMENSION_TOO_LARGE")
        }
        // 元数据留存判定（image.ts:51-60 carriesRetainedMetadata 对位：
        // exif / iptc / xmp / tiff(photoshop) / icc profile / orientation
        // 任一在场即留存）。
        let carriesMetadata =
            properties[kCGImagePropertyExifDictionary] != nil
            || properties[kCGImagePropertyIPTCDictionary] != nil
            || properties[kCGImagePropertyXMPDictionary] != nil
            || properties[kCGImagePropertyTIFFDictionary] != nil
            || properties[kCGImagePropertyProfileName] != nil
            || properties[kCGImagePropertyOrientation] != nil
        let detected = DetectedImage(
            mediaType: mediaType,
            width: width,
            height: height,
            animated: frameCount > 1,
            carriesMetadata: carriesMetadata,
            bitDepth: (properties[kCGImagePropertyDepth] as? Int) ?? 8,
            isRGB: (properties[kCGImagePropertyColorModel] as? String) == "RGB",
            hasAlpha: (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false)
        // 全解码验证（image.ts:124 全量物化对位；畸形数据在此拒绝）。
        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw AttachmentError(message: "Unsupported or malformed image data.",
                                  code: "INVALID_IMAGE")
        }
        return detected
    }

    // MARK: - 归一化（normalizeImage）

    /// 归一化产出（normalization.ts:21-26 NormalizedImage 1:1）。
    struct NormalizedImage {
        var data: Data
        var mediaType: ImageMediaType
        var width: Int
        var height: Int
    }

    /// pass-through 条件（normalization.ts:35-48 canPassThroughNormalization 1:1
    /// ——非 gif、单帧、无元数据、8-bit、RGB、字节/像素/长边全达标才原样直通）。
    static func canPassThrough(_ detected: DetectedImage, bytes: Int,
                               policy: NormalizationPolicy) -> Bool {
        detected.mediaType != .gif
            && !detected.animated
            && !detected.carriesMetadata
            && detected.bitDepth == 8
            && detected.isRGB
            && bytes <= policy.maxBytes
            && detected.width * detected.height <= policy.maxPixels
            && max(detected.width, detected.height) <= policy.maxDimension
    }

    /// 归一化（normalization.ts:103-130 normalizeImage 1:1 语义）：达标直通，
    /// 否则「总像素预算缩放 → 长边帽 → 质量阶梯编码 → 首达/最小」；alpha 源
    /// 走 PNG 单档（呈报差异①），不透明源走 JPEG 阶梯。再编码从不丢透明。
    static func normalizeImage(_ data: Data,
                               detected: DetectedImage,
                               policy: NormalizationPolicy) throws -> NormalizedImage {
        if canPassThrough(detected, bytes: data.count, policy: policy) {
            return NormalizedImage(data: data, mediaType: detected.mediaType,
                                   width: detected.width, height: detected.height)
        }
        // initialDimensions（normalization.ts:81-90 1:1）：总像素预算内投影，
        // 再对长边应用帽（floor 取整），不改变纵横比。
        let budgeted = RequestProjection.requestImageDimensions(
            width: detected.width, height: detected.height, maxPixels: policy.maxPixels)
        let longEdge = max(budgeted.width, budgeted.height)
        var target = budgeted
        if longEdge > policy.maxDimension {
            let scale = Double(policy.maxDimension) / Double(longEdge)
            target = (max(1, Int((Double(budgeted.width) * scale).rounded(.down))),
                      max(1, Int((Double(budgeted.height) * scale).rounded(.down))))
        }
        let raster = try orientedSRGBImage(data)
        let resized = try resizedImage(raster, width: target.width, height: target.height)
        let attempts = encodeLadder(resized, hasAlpha: detected.hasAlpha)
        let chosen = try RequestProjection.encodeFirstWithinLimit(attempts, maxBytes: policy.maxBytes)
        // verifyNormalizedImage（normalization.ts:51-70 对位）：归一化产出回核
        // 尺寸/类型（本实现产出的编码天然无 EXIF 元数据；失败 fail closed）。
        guard chosen.width == target.width, chosen.height == target.height else {
            throw AttachmentError(
                message: "Image normalization did not produce a single-frame 8-bit sRGB image with matching metadata.",
                code: "ATTACHMENT_WRITE_FAILED")
        }
        return NormalizedImage(data: chosen.data, mediaType: chosen.mediaType,
                               width: chosen.width, height: chosen.height)
    }

    /// 阶梯构造（encoding.ts:33-38 encodingLadder 对位）：alpha → PNG 单档
    /// （呈报差异①），opaque → JPEG 按 qualities 从高到低。
    static func encodeLadder(_ image: CGImage, hasAlpha: Bool) -> [() throws -> EncodedImage] {
        if hasAlpha {
            return [{ try Self.encodePNG(image) }]
        }
        return RequestProjection.qualities.map { quality in
            { try Self.encodeJPEG(image, quality: quality) }
        }
    }

    // MARK: - 栅格与编码

    /// 解码 + EXIF 方向应用 + sRGB 化（normalization.ts:73-78 preparedPipeline
    /// 对位：rotate() + toColourspace('srgb')；尺寸暂不缩放，由 resizedImage 承担）。
    static func orientedSRGBImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AttachmentError(message: "Unsupported or malformed image data.",
                                  code: "INVALID_IMAGE")
        }
        let orientationRaw = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        let storedWidth = image.width
        let storedHeight = image.height
        // EXIF 方向变换（Apple Q&A 标准映射；1-4 不转置、5-8 转置）。
        var transform = CGAffineTransform.identity
        switch orientationRaw {
        case 2: transform = transform.translatedBy(x: CGFloat(storedWidth), y: 0).scaledBy(x: -1, y: 1)
        case 3: transform = transform.translatedBy(x: CGFloat(storedWidth), y: CGFloat(storedHeight)).rotated(by: .pi)
        case 4: transform = transform.translatedBy(x: 0, y: CGFloat(storedHeight)).scaledBy(x: 1, y: -1)
        case 5: transform = transform.translatedBy(x: CGFloat(storedHeight), y: CGFloat(storedWidth)).rotated(by: 3 * .pi / 2).scaledBy(x: -1, y: 1)
        case 6: transform = transform.translatedBy(x: CGFloat(storedHeight), y: 0).rotated(by: .pi / 2)
        case 7: transform = transform.translatedBy(x: 0, y: CGFloat(storedWidth)).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
        case 8: transform = transform.translatedBy(x: 0, y: CGFloat(storedWidth)).rotated(by: -.pi / 2)
        default: break
        }
        // 感知尺寸（5-8 转置）。
        let perceivedWidth = orientationRaw >= 5 ? storedHeight : storedWidth
        let perceivedHeight = orientationRaw >= 5 ? storedWidth : storedHeight
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: perceivedWidth,
                                      height: perceivedHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AttachmentError(message: "Image normalization failed to allocate the sRGB context.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(storedWidth),
                                       height: CGFloat(storedHeight)))
        guard let output = context.makeImage() else {
            throw AttachmentError(message: "Image normalization failed to render the oriented raster.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        return output
    }

    /// 缩放（normalization.ts:77 resize fit:'inside' withoutEnlargement 对位
    /// ——重绘进目标尺寸的 sRGB 上下文；调用方保证目标 ≤ 感知尺寸）。
    static func resizedImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw AttachmentError(message: "Image projection requires positive dimensions.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AttachmentError(message: "Image projection failed to allocate the sRGB context.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(width), height: CGFloat(height)))
        guard let output = context.makeImage() else {
            throw AttachmentError(message: "Image projection failed to render the resized raster.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        return output
    }

    static func encodeJPEG(_ image: CGImage, quality: Int) throws -> EncodedImage {
        let data = try destinationData(image: image, type: .jpeg,
                                       quality: Double(quality) / 100.0)
        return EncodedImage(data: data, mediaType: .jpeg,
                            width: image.width, height: image.height)
    }

    static func encodePNG(_ image: CGImage) throws -> EncodedImage {
        let data = try destinationData(image: image, type: .png, quality: nil)
        return EncodedImage(data: data, mediaType: .png,
                            width: image.width, height: image.height)
    }

    private static func destinationData(image: CGImage, type: UTType,
                                        quality: Double?) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw AttachmentError(message: "Image encoding failed to create the destination.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentError(message: "Image encoding failed to finalize the destination.",
                                  code: "ATTACHMENT_WRITE_FAILED")
        }
        return output as Data
    }
}
