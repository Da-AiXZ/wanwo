//
//  MCPImageProjectionTests.swift
//  WanWoTests
//
//  【M4-A 件12】件6 锚点：图片准入投影（MCPImageProjection.swift，dsh
//  tools.ts:374-392）——isCanonicalBase64 边界（CANONICAL_BASE64 正则的
//  手写等价：'=' 只允许尾组填充位）+ decodeImage 三条拒绝文案逐字：
//  "the declared media type is not PNG, JPEG, WebP, or GIF"（:382）/
//  "the image data is not canonical base64"（:385 正则 + :389 回编双校验）。
//  "AB==" 是「正则通过但回编失败」的判定对锚点（两道校验缺一不可）。
//

import XCTest
import MCP
@testable import WanWo

final class MCPImageProjectionTests: XCTestCase {

    private func decodeError(_ block: [String: JSONValue]) -> String {
        do {
            _ = try MCPImageProjector.decodeImage(block)
            return "<no error>"
        } catch let error as MCPImageAdmissionRefusal {
            return error.description
        } catch {
            return "unexpected error type: \(error)"
        }
    }

    private func decodeAttachment(_ block: [String: JSONValue]) throws
        -> SaveImageAttachment {
        try MCPImageProjector.decodeImage(block)
    }

    // MARK: isCanonicalBase64（tools.ts:379-385 等价形态）

    /// 中段 '='：非尾组填充位 → false。
    func testEmbeddedPaddingIsRejected() {
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("AB==CD=="))
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("===="))
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("A=AA"))
    }

    /// 合法尾组填充形态。
    func testTrailingPaddingFormsAreAccepted() {
        XCTAssertTrue(MCPImageProjector.isCanonicalBase64("AAA="))
        XCTAssertTrue(MCPImageProjector.isCanonicalBase64("AA=="))
        XCTAssertTrue(MCPImageProjector.isCanonicalBase64("AB=="))  // 正则形态合法
        XCTAssertTrue(MCPImageProjector.isCanonicalBase64("ABCD"))
    }

    /// 空串 = 零主体 + 零尾组（正则全可选语义）。
    func testEmptyStringIsCanonical() {
        XCTAssertTrue(MCPImageProjector.isCanonicalBase64(""))
    }

    /// 长度非 4 的倍数 / 非字母表字符 / 越界 '='。
    func testMalformedFormsAreRejected() {
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("A"))
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("ABCDE"))
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("AB=C"))
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("!@#$"))
        XCTAssertFalse(MCPImageProjector.isCanonicalBase64("AB C"))
    }

    // MARK: decodeImage 三条拒绝文案（:382/:385/:389 逐字）

    func testMissingOrUnknownMediaTypeRefusal() {
        XCTAssertEqual(
            decodeError(["data": .string("AAAA")]),
            "the declared media type is not PNG, JPEG, WebP, or GIF")
        XCTAssertEqual(
            decodeError(["mimeType": .string("image/tiff"),
                         "data": .string("AAAA")]),
            "the declared media type is not PNG, JPEG, WebP, or GIF")
    }

    func testDataMissingRefusal() {
        XCTAssertEqual(
            decodeError(["mimeType": .string("image/png")]),
            "the image data is not canonical base64")
    }

    func testNonCanonicalPatternRefusal() {
        XCTAssertEqual(
            decodeError(["mimeType": .string("image/png"),
                         "data": .string("!!")]),
            "the image data is not canonical base64")
    }

    /// 判定对锚点：'AB==' 正则通过、Data 解码后回编不等值 → 仍拒（:389）。
    func testRegexPassButReencodeMismatchRefusal() {
        XCTAssertEqual(
            decodeError(["mimeType": .string("image/png"),
                         "data": .string("AB==")]),
            "the image data is not canonical base64")
    }

    // MARK: 合法块 → SaveImageAttachment

    func testValidPngBlockDecodes() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])  // PNG 魔数片段
        let base64 = bytes.base64EncodedString()          // 编码器输出恒 canonical
        let attachment = try decodeAttachment(
            ["mimeType": .string("image/png"), "data": .string(base64)])
        XCTAssertEqual(attachment.data, bytes)
        XCTAssertEqual(attachment.mediaType, .png)
        XCTAssertNil(attachment.name)  // :391——name 不适用 MCP 块
    }

    func testMinimalValidBlockDecodes() throws {
        let attachment = try decodeAttachment(
            ["mimeType": .string("image/gif"), "data": .string("AA==")])
        XCTAssertEqual(attachment.data, Data([0x00]))
        XCTAssertEqual(attachment.mediaType, .gif)
    }

    /// 四媒体类型白名单全通过（IMAGE_MEDIA_TYPES :374-377）。
    func testAllFourMediaTypesAccepted() throws {
        for mediaType in ["image/png", "image/jpeg", "image/webp", "image/gif"] {
            XCTAssertNoThrow(
                try decodeAttachment(
                    ["mimeType": .string(mediaType), "data": .string("AA==")]),
                "media type \(mediaType) must be admitted")
        }
    }
}
