//
//  SkillParserTests.swift
//  WanWoTests
//
//  【M4-D 件 D1 · F034 格式层测试移植】出处：codex-rs skills/src/parser_tests.rs
//  （六个用例 1:1 移植，测试名保持原 snake_case 对应）+ 3 个锚点边界补测
//  （extract_frontmatter 边界 / name 长度边界 / 空名回退——均直接锚定 parser.rs）。
//

import XCTest
@testable import WanWo

final class SkillParserTests: XCTestCase {

    // MARK: parser_tests.rs:parses_repairs_and_sanitizes_frontmatter

    func testParsesRepairsAndSanitizesFrontmatter() throws {
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname:  deploy  service\ndescription: Build for AWS: ECS\nmetadata:\n  short-description:  Deploy   safely\n---\n",
            defaultName: { "fallback" }
        )

        XCTAssertEqual(
            parsed,
            ParsedSkillFrontmatter(
                name: "deploy service",
                description: "Build for AWS: ECS",
                shortDescription: "Deploy safely"
            )
        )
    }

    // MARK: parser_tests.rs:uses_default_name_and_requires_description

    func testUsesDefaultNameAndRequiresDescription() throws {
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\ndescription: Demo skill\n---\n",
            defaultName: { "demo" }
        )
        XCTAssertEqual(
            parsed,
            ParsedSkillFrontmatter(
                name: "demo",
                description: "Demo skill",
                shortDescription: nil
            )
        )

        do {
            _ = try SkillParser.parseSkillFrontmatterMetadata(
                "---\nname: demo\n---\n",
                defaultName: { "fallback" }
            )
            XCTFail("description should be required")
        } catch {
            // 错误文案逐字（parser.rs:37）
            XCTAssertEqual(String(describing: error), "missing field `description`")
        }
    }

    // MARK: parser_tests.rs:repairs_short_descriptions_containing_colons_and_apostrophes

    func testRepairsShortDescriptionsContainingColonsAndApostrophes() throws {
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname: short\ndescription: Short skill\nmetadata:\n  short-description: What's included: builds and tests\n---\n",
            defaultName: { "fallback" }
        )

        XCTAssertEqual(
            parsed,
            ParsedSkillFrontmatter(
                name: "short",
                description: "Short skill",
                shortDescription: "What's included: builds and tests"
            )
        )
    }

    // MARK: parser_tests.rs:repairs_unrecognized_frontmatter_fields_that_need_quotes

    func testRepairsUnrecognizedFrontmatterFieldsThatNeedQuotes() throws {
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname: unknown\ndescription: Unknown fields\nargument-hint: <duration: e.g. 7d, 2w>\ntags: [next,@supabase/ssr]\n---\n",
            defaultName: { "fallback" }
        )

        XCTAssertEqual(
            parsed,
            ParsedSkillFrontmatter(
                name: "unknown",
                description: "Unknown fields",
                shortDescription: nil
            )
        )
    }

    // MARK: parser_tests.rs:preserves_block_scalar_bodies_while_repairing_other_fields

    func testPreservesBlockScalarBodiesWhileRepairingOtherFields() throws {
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname: block\ndescription: |-\n  Build for AWS: ECS\nargument-hint: <duration: e.g. 7d>\n---\n",
            defaultName: { "fallback" }
        )

        XCTAssertEqual(
            parsed,
            ParsedSkillFrontmatter(
                name: "block",
                description: "Build for AWS: ECS",
                shortDescription: nil
            )
        )
    }

    // MARK: parser_tests.rs:preserves_overlong_descriptions_and_short_descriptions

    func testPreservesOverlongDescriptionsAndShortDescriptions() throws {
        let description = String(repeating: "💡", count: 1025)
        let shortDescription = String(repeating: "x", count: 1025)
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname: long\ndescription: \(description)\nmetadata:\n  short-description: \(shortDescription)\n---\n",
            defaultName: { "fallback" }
        )

        XCTAssertEqual(
            parsed,
            ParsedSkillFrontmatter(
                name: "long",
                description: description,
                shortDescription: shortDescription
            )
        )
    }

    // MARK: 补测 · extract_frontmatter 边界（parser.rs:200-221）

    /// 无 frontmatter / 无闭合 / 空块 / 首行非分隔符 → MissingFrontmatter，文案逐字。
    func testMissingFrontmatterVariants() {
        let cases: [String] = [
            "name: demo\n",   // 无 frontmatter
            "---\nname: demo\n",   // 无闭合
            "---\n---\n",   // 空块
            "name: demo\n---\n",   // 首行非 ---
        ]
        for contents in cases {
            do {
                _ = try SkillParser.parseSkillFrontmatterMetadata(
                    contents, defaultName: { "fallback" })
                XCTFail("expected MissingFrontmatter for: \(contents)")
            } catch {
                XCTAssertEqual(
                    String(describing: error),
                    "missing YAML frontmatter delimited by ---")
            }
        }
    }

    // MARK: 补测 · name 长度边界（parser.rs:183-198 + :82）

    /// name 65 字素 → invalid name 文案逐字；恰好 64 → 通过。
    func testNameLengthValidationBoundary() throws {
        let overlong = String(repeating: "a", count: 65)
        do {
            _ = try SkillParser.parseSkillFrontmatterMetadata(
                "---\nname: \(overlong)\ndescription: ok\n---\n",
                defaultName: { "fallback" }
            )
            XCTFail("expected InvalidField for 65-character name")
        } catch {
            XCTAssertEqual(
                String(describing: error),
                "invalid name: exceeds maximum length of 64 characters")
        }

        let atLimit = String(repeating: "a", count: 64)
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname: \(atLimit)\ndescription: ok\n---\n",
            defaultName: { "fallback" }
        )
        XCTAssertEqual(parsed.name, atLimit)
    }

    // MARK: 补测 · 空名回退（parser.rs:64-69）

    /// name sanitize 后为空 → default_name 闭包回退。
    func testEmptyNameFallsBackToDefault() throws {
        let parsed = try SkillParser.parseSkillFrontmatterMetadata(
            "---\nname:    \ndescription: Demo\n---\n",
            defaultName: { "fallback" }
        )
        XCTAssertEqual(parsed.name, "fallback")
    }
}
