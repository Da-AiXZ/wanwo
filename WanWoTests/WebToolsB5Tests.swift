//
//  WebToolsB5Tests.swift
//  WanWoTests
//
//  【批2 B⑤】web_fetch 孤立 % 预编码单测（批2 简报 2A B⑤ 测试面）：
//    · %l/%c/%t 等非法转义（wttr.in 天气格式串实证）→ 预编码 %25 后可解析；
//    · 合法转义 %20 等原样保留（不得二次编码成 %2520）；
//    · 混合矩阵 + 边界（结尾孤 %、%后单 hex、空串、无 % 直通）。
//  断言分两层：编码纯函数面（encodeLonePercent）+ 端到端 URL(string:) 可解析面。
//

import XCTest
@testable import WanWo

final class WebToolsB5Tests: XCTestCase {

    // MARK: - 编码纯函数面

    func testLonePercentFollowedByNonHexIsEncoded() {
        // wttr.in 实证串：%l/%c/%t 均为非法转义 → 全部编码。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("wttr.in/%l?format=%c+%t"),
                       "wttr.in/%25l?format=%25c+%25t")
    }

    func testValidEscapesArePreserved() {
        // 合法两位 hex 转义原样保留——不得二次编码。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("a%20b"), "a%20b")
        XCTAssertEqual(WebFetchTool.encodeLonePercent("%2Fpath%3Fq%3D1"), "%2Fpath%3Fq%3D1")
        // 小写 hex 同样合法。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("%c3%a9"), "%c3%a9")
    }

    func testMixedValidAndLone() {
        // 混合：合法 %20 保留 + 孤立 %l 编码（简报要求的混合矩阵）。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("f?a%20b=%l&x=%c"),
                       "f?a%20b=%25l&x=%25c")
    }

    func testBoundaryCases() {
        // 结尾孤 %。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("100%"), "100%25")
        // % 后仅一位 hex（结尾）。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("a%2"), "a%252")
        // % 后两位中第二位非 hex → 前 % 编码，后字面照抄。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("a%2z"), "a%252z")
        // 无 % 直通；空串直通。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("https://example.com/x?y=1"),
                       "https://example.com/x?y=1")
        XCTAssertEqual(WebFetchTool.encodeLonePercent(""), "")
        // 多个连续孤 %。
        XCTAssertEqual(WebFetchTool.encodeLonePercent("%%"), "%25%25")
    }

    // MARK: - 端到端：预编码后 URL(string:) 可解析

    func testURLParsingAfterPreencoding() {
        // 修前：URL(string: "https://wttr.in/%l?format=%c+%t") == nil。
        // 修后：预编码可解析且 scheme 正常。
        let raw = "https://wttr.in/%l?format=%c+%t"
        // 修前基线断言（URL(string: raw) == nil）环境相关：新 Foundation 对
        // 部分非法转义宽松解析——基线断言不可靠，删除；修复有效性由下方
        // 预编码可解析 + scheme 断言承载。
        let url = URL(string: WebFetchTool.encodeLonePercent(raw))
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme?.lowercased(), "https")
    }

    func testValidURLUnaffected() {
        // 正常 URL（含合法转义）经预编码后解析结果不变。
        let raw = "https://example.com/a%20b/c?d=e"
        let direct = URL(string: raw)
        let preencoded = URL(string: WebFetchTool.encodeLonePercent(raw))
        XCTAssertEqual(direct?.absoluteString, preencoded?.absoluteString)
    }
}
