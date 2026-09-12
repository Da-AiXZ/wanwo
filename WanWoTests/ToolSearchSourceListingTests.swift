//
//  ToolSearchSourceListingTests.swift
//  WanWoTests
//
//  【C7 测试锚】来源清单渲染纯函数——对拍基准 = codex-rs core/src/tools/
//  handlers/tool_search_spec.rs:34-89（Include 变体逐式）+ :108-220 codex 自测
//  （deduplicates_and_renders / bounds_aggregate_source_descriptions）的 Swift
//  移植锚 + take_bytes_at_char_boundary 字符边界截断。
//  红线覆盖：渲染字节稳定性 + 512KB 裁剪边界。
//

import XCTest
@testable import WanWo

final class ToolSearchSourceListingTests: XCTestCase {

    // MARK: 去重与行格式（codex :116-157 自测移植）

    /// 同 name 去重：首个非 nil description 生效；nil 描述只出 `- {name}`；
    /// 按 name 字节序排列（codex create_tool_search_tool_deduplicates_and_
    /// renders_enabled_sources 渲染层对拍）。
    func testDeduplicatesAndRendersEnabledSources() {
        let rendered = ToolSearchSourceListing.renderSourceDescriptions([
            ToolSearchSourceInfo(
                name: "Google Drive",
                description: "Use Google Drive as the single entrypoint for Drive, Docs, "
                    + "Sheets, and Slides work."),
            ToolSearchSourceInfo(name: "Google Drive", description: nil),
            ToolSearchSourceInfo(name: "docs", description: nil),
        ])
        XCTAssertEqual(rendered,
            "- Google Drive: Use Google Drive as the single entrypoint for Drive, Docs, "
                + "Sheets, and Slides work.\n- docs")
    }

    /// 同 name 首个为 nil、后见非 nil → 补位（:40-44 and_modify 语义）；
    /// 已有非 nil 后续不覆盖。
    func testLaterNonNilDescriptionFillsNilFirst() {
        let rendered = ToolSearchSourceListing.renderSourceDescriptions([
            ToolSearchSourceInfo(name: "docs", description: nil),
            ToolSearchSourceInfo(name: "docs", description: "Documents server."),
            ToolSearchSourceInfo(name: "docs", description: "Other wording."),
        ])
        XCTAssertEqual(rendered, "- docs: Documents server.")
    }

    /// 空清单固定文案（codex :48-49）。
    func testEmptySourcesRenderPlaceholder() {
        XCTAssertEqual(ToolSearchSourceListing.renderSourceDescriptions([]),
                       "None currently enabled.")
    }

    /// source_section 包装逐字（codex :86-88 format!：首尾 \n 归属本段）。
    func testSourceSectionWrapperIsVerbatim() {
        let section = ToolSearchSourceListing.sourceSection(from: [
            ToolSearchSourceInfo(name: "calendar", description: "Calendar server")])
        XCTAssertEqual(section,
            "\n\nYou have access to tools from the following sources:\n"
                + "- calendar: Calendar server\n")
    }

    // MARK: 512KB 聚合预算（codex :178-220 自测移植：裁剪边界）

    /// 聚合预算：8 个超长描述截到清单总长 ≤ 512KB，且 8 个名字行全部完整
    /// 保留（名字行不截断；codex bounds_aggregate 断言的渲染层移植）。
    func testBoundsAggregateSourceDescriptions() {
        let longDescription = String(repeating: "🦀", count: 20_000)
        let sources = (0..<8).map { index in
            ToolSearchSourceInfo(name: String(format: "source-%02d", index),
                                 description: longDescription)
        }
        let rendered = ToolSearchSourceListing.renderSourceDescriptions(sources)

        XCTAssertLessThanOrEqual(rendered.utf8.count,
                                 ToolSearchSourceListing.maxSourceDescriptionBytes)
        XCTAssertTrue(rendered.hasPrefix("- source-00: 🦀"))
        let names = rendered.split(separator: "\n").map { line -> String in
            let body = line.hasPrefix("- ") ? String(line.dropFirst(2)) : String(line)
            return body.contains(": ")
                ? String(body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
                : body
        }
        XCTAssertEqual(names, (0..<8).map { String(format: "source-%02d", $0) },
                       "每个来源名字行都必须完整保留（required 判定逐条跳过，绝不半行）")
    }

    /// 名字行放不进剩余预算 → 整条跳过（:61-65 continue），其余来源照常入列。
    func testNameLineOverflowSkipsEntry() {
        let bigName = String(repeating: "n", count: 300_000)
        let rendered = ToolSearchSourceListing.renderSourceDescriptions([
            ToolSearchSourceInfo(name: bigName, description: nil),
            ToolSearchSourceInfo(name: bigName, description: nil),
            ToolSearchSourceInfo(name: "tiny", description: nil),
        ])
        // 第一个 300KB 名字行入列后剩余 ~224KB，第二个 required ~300KB → 跳过；
        // tiny 行仍可入列（逐条判定，非「超限即截断后续」）。
        XCTAssertEqual(rendered.split(separator: "\n").count, 2)
        XCTAssertTrue(rendered.contains("- tiny"))
        XCTAssertLessThanOrEqual(rendered.utf8.count,
                                 ToolSearchSourceListing.maxSourceDescriptionBytes)
    }

    // MARK: description 字符边界截断（take_bytes_at_char_boundary 等价锚）

    /// 预算恰为字符整数倍 → 完整保留；预算卡在多字节字符中段 → 回退到字符
    /// 起始边界（不劈开 🦀；不产生替换字符）。
    func testTruncationRespectsCharBoundary() {
        let crabs = String(repeating: "🦀", count: 10)  // 40 bytes

        // 预算充裕 → 不截断。
        let full = ToolSearchSourceListing.renderSourceDescriptions([
            ToolSearchSourceInfo(name: "s", description: crabs)])
        XCTAssertEqual(full, "- s: \(crabs)")

        // 预算 4 字节 → 恰好 1 只蟹（4 字节边界内）。
        let name4 = String(repeating: "n", count: 524_288 - 8)  // 524280 字节
        let oneCrab = ToolSearchSourceListing.renderSourceDescriptions([
            ToolSearchSourceInfo(name: name4, description: crabs)])
        XCTAssertEqual(oneCrab, "- \(name4): 🦀")

        // 预算 3 字节 → 🦀 放不下，回退到空前缀（行尾仅剩 ": "，codex 同式）。
        let name3 = String(repeating: "n", count: 524_281)
        let clipped = ToolSearchSourceListing.renderSourceDescriptions([
            ToolSearchSourceInfo(name: name3, description: crabs)])
        XCTAssertEqual(clipped, "- \(name3): ")
    }

    // MARK: 字节稳定性（红线）

    /// 同输入渲染逐字节相等；迭代序不影响结果（排序保证确定性——缓存前缀
    /// 纪律的底层前提）。
    func testRenderingIsByteStableForSameInputs() {
        let sources = [
            ToolSearchSourceInfo(name: "calendar", description: "Calendar server"),
            ToolSearchSourceInfo(name: "docs", description: nil),
        ]
        XCTAssertEqual(ToolSearchSourceListing.renderSourceDescriptions(sources),
                       ToolSearchSourceListing.renderSourceDescriptions(sources))
        XCTAssertEqual(
            ToolSearchSourceListing.renderSourceDescriptions(sources),
            ToolSearchSourceListing.renderSourceDescriptions(Array(sources.reversed())))
    }
}
