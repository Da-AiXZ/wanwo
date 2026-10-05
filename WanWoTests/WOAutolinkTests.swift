//
//  WOAutolinkTests.swift
//  WanWoTests
//
//  【批2 修复回归 2026-09-27】autolinkBareURLs 反引号边界——AI 以
//  `wanwo://…`（inline code）输出链接时，此前反引号不在 stopChars/blockPrev
//  两表内：①code span 内 URL 被包链 ②URL 吃进闭合反引号 → 原 code span
//  未闭合延伸行尾 → 整行纯代码渲染（IMG_2463 用户截图实证）。
//  修复后：反引号内 URL 保持字面（不包链）；裸 URL 照常包链。
//

import XCTest
@testable import WanWo

final class WOAutolinkTests: XCTestCase {

    // MARK: 反引号边界（本批修复面）

    /// inline code 内 wanwo:// URL 不包链、闭合反引号不被吃进 URL。
    func testBacktickCodeSpanWanwoURLUntouched() {
        let input = "- `wanwo://browser/screenshot_1790464722.jpg` — 必应首页"
        let output = WONodeBubbleView.autolinkBareURLs(input)
        // 反引号必须成对保留（未被吃进 URL 导致 span 未闭合）。
        XCTAssertEqual(output.filter { $0 == "`" }.count, 2,
                       "闭合反引号必须保留在原位：\(output)")
        // 不产生 markdown 链接包裹。
        XCTAssertFalse(output.contains("]("), "code span 内 URL 不得被包链：\(output)")
        XCTAssertTrue(output.contains("`wanwo://browser/screenshot_1790464722.jpg`"))
    }

    /// 反引号外的裸 wanwo:// URL 照常包链（既有语义不回归）。
    func testBareWanwoURLStillWrapped() {
        let input = "截图在 wanwo://browser/screenshot_1.jpg 请查看"
        let output = WONodeBubbleView.autolinkBareURLs(input)
        XCTAssertTrue(output.contains("[wanwo://browser/screenshot_1.jpg](wanwo://browser/screenshot_1.jpg)"),
                      "裸 URL 应包链：\(output)")
    }

    /// https 裸 URL 包链不回归。
    func testBareHTTPSURLWrapped() {
        let output = WONodeBubbleView.autolinkBareURLs("见 https://example.com/a 页面")
        XCTAssertTrue(output.contains("[https://example.com/a](https://example.com/a)"))
    }

    /// 已在 markdown 链接目标位的 URL 不重复包链（blockPrev `(` 既有语义）。
    func testURLInsideMarkdownLinkNotDoubleWrapped() {
        let input = "[text](https://example.com)"
        let output = WONodeBubbleView.autolinkBareURLs(input)
        XCTAssertEqual(output, input, "链接目标位 URL 不得二次包链")
    }

    /// 双反引号（``code``）紧邻场景：URL 紧跟反引号后不包链。
    func testDoubleBacktickAdjacencyUntouched() {
        let input = "``wanwo://browser/a.jpg``尾"
        let output = WONodeBubbleView.autolinkBareURLs(input)
        XCTAssertFalse(output.contains("]("), "反引号紧邻 URL 不得包链：\(output)")
    }

    /// URL 后紧跟反引号（`url` 形态闭合）：反引号不得被吃进 URL 目标。
    func testTrailingBacktickNotSwallowed() {
        let input = "看 wanwo://browser/a.jpg`结尾"
        let output = WONodeBubbleView.autolinkBareURLs(input)
        // 链接目标=纯 URL（反引号是 stopChar，留在目标外原位）。
        XCTAssertTrue(output.contains("[wanwo://browser/a.jpg](wanwo://browser/a.jpg)`结尾"),
                      "反引号必须保留在链接目标之外：\(output)")
    }

    /// 空串/无 URL 文本原样返回。
    func testPlainTextUnchanged() {
        XCTAssertEqual(WONodeBubbleView.autolinkBareURLs(""), "")
        XCTAssertEqual(WONodeBubbleView.autolinkBareURLs("普通文本没有链接"),
                       "普通文本没有链接")
    }
}
