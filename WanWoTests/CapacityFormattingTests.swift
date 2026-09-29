//
//  CapacityFormattingTests.swift
//  WanWo
//
//  【m8 批1 A2】K/M 容量解析/格式化纯函数单测——dsh
//  DeepSeekModelsEditor.tsx:43-69 语义往返对拍 + ModelCatalogValidation
//  行级校验（validateDeepSeekModels :94-123）。
//

import XCTest
@testable import WanWo

final class CapacityFormattingTests: XCTestCase {

    // MARK: - parseCapacity：合法写法

    func testParsePlainNumbers() {
        XCTAssertEqual(CapacityFormatting.parseCapacity("131072"), 131_072)
        XCTAssertEqual(CapacityFormatting.parseCapacity(" 8192 "), 8_192)
        XCTAssertEqual(CapacityFormatting.parseCapacity("0"), 0)
    }

    func testParseDecimalScales() {
        // 1M = 1_000_000 十进制（非 1024 进制——dsh CAPACITY_SCALE 语义）。
        XCTAssertEqual(CapacityFormatting.parseCapacity("1M"), 1_000_000)
        XCTAssertEqual(CapacityFormatting.parseCapacity("1m"), 1_000_000)
        XCTAssertEqual(CapacityFormatting.parseCapacity("256K"), 256_000)
        XCTAssertEqual(CapacityFormatting.parseCapacity("256k"), 256_000)
        XCTAssertEqual(CapacityFormatting.parseCapacity("650K"), 650_000)
        // 小数倍数：整值意图 snap 回正（2.3 * 1e6 浮点 ULP 修正）。
        XCTAssertEqual(CapacityFormatting.parseCapacity("2.3M"), 2_300_000)
        XCTAssertEqual(CapacityFormatting.parseCapacity("0.5K"), 500)
    }

    // MARK: - parseCapacity：继承与不可读

    func testParseBlankMeansInherit() {
        XCTAssertNil(CapacityFormatting.parseCapacity(""))
        XCTAssertNil(CapacityFormatting.parseCapacity("   "))
    }

    func testParseUnreadableIsNaN() {
        let bad = ["abc", "1MB", "K", "-5", "1,000", "1 K", "+256", "1e3", "٣٢"]
        for text in bad {
            guard let parsed = CapacityFormatting.parseCapacity(text) else {
                XCTFail("'\(text)' 应为 NaN 而非继承(nil)")
                continue
            }
            XCTAssertTrue(parsed.isNaN, "'\(text)' 应不可读(NaN)，得 \(parsed)")
        }
    }

    // MARK: - formatCapacity：最短往返形式

    func testFormatRoundTrip() {
        let cases: [(Double, String)] = [
            (1_000_000, "1M"),
            (256_000, "256K"),
            (131_072, "131072"),   // 非千整倍数写全
            (8_192, "8192"),
            (650_000, "650K"),
            // dsh formatCapacity 逐字语义：整除 K 用 K（2_300_000 → "2300K"，
            // 非"最短形式"——dsh 注释名不符实，以实现为准）。
            (2_300_000, "2300K"),
        ]
        for (value, text) in cases {
            XCTAssertEqual(CapacityFormatting.formatCapacity(value), text)
            // 往返：格式化文本再解析回同一数值。
            XCTAssertEqual(CapacityFormatting.parseCapacity(text), value, text)
        }
    }

    func testFormatNonPositiveAndNonInteger() {
        // dsh：非整数或 <=0 原样写全。
        XCTAssertEqual(CapacityFormatting.formatCapacity(0), "0")
        XCTAssertEqual(CapacityFormatting.formatCapacity(-4096), "-4096")
        XCTAssertEqual(CapacityFormatting.formatCapacity(1.5), "1.5")
    }

    func testFormatIntOverload() {
        XCTAssertEqual(CapacityFormatting.formatCapacity(1_000_000), "1M")
        XCTAssertEqual(CapacityFormatting.formatCapacity(65536), "65536")
    }

    // MARK: - ModelCatalogValidation（dsh validateDeepSeekModels :94-123）

    private func entry(id: String, name: String? = nil,
                       window: Int? = nil, maxTokens: Int? = nil) -> ModelCatalogEntry {
        // 契约全参构造（memberwise init 无默认参数保证）。
        ModelCatalogEntry(id: id, name: name, description: nil,
                          contextWindow: window, maxTokens: maxTokens, inputModalities: nil)
    }

    func testValidateAcceptsGoodCatalog() {
        XCTAssertNil(ModelCatalogValidation.validate(nil)) // 继承态不校验
        XCTAssertNil(ModelCatalogValidation.validate([
            entry(id: "deepseek-v4-flash", name: "V4 Flash", window: 1_000_000, maxTokens: 256_000),
            entry(id: "deepseek-v4-pro"),
        ]))
    }

    func testValidateBlankIDByPosition() {
        let failure = ModelCatalogValidation.validate([entry(id: "a"), entry(id: "  ")])
        XCTAssertEqual(failure, .init(index: 1, key: .modelIdRequired))
    }

    func testValidateDuplicateIDTrimmed() {
        // "model " 与 "model" 经 trim 视为重名（dsh :99-105 注释语义）。
        let failure = ModelCatalogValidation.validate([entry(id: "model"), entry(id: "model ")])
        XCTAssertEqual(failure, .init(index: 1, key: .modelIdDuplicate))
    }

    func testValidateEmptyNameRejected() {
        let failure = ModelCatalogValidation.validate([entry(id: "a", name: "")])
        XCTAssertEqual(failure, .init(index: 0, key: .modelNameInvalid))
    }

    func testValidateNonPositiveCapacities() {
        XCTAssertEqual(ModelCatalogValidation.validate([entry(id: "a", window: 0)]),
                       .init(index: 0, key: .modelContextInvalid))
        XCTAssertEqual(ModelCatalogValidation.validate([entry(id: "a", window: -5)]),
                       .init(index: 0, key: .modelContextInvalid))
        XCTAssertEqual(ModelCatalogValidation.validate([entry(id: "a", maxTokens: 0)]),
                       .init(index: 0, key: .modelMaxTokensInvalid))
    }
}
