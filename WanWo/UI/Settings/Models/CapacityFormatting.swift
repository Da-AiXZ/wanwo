//
//  CapacityFormatting.swift
//  WanWo
//
//  【m8 批1 A2 · 照 dsh 语义翻译】K/M 容量文本解析与格式化。
//  语义源：dsh packages/client/ui-settings-models/src/client/DeepSeekModelsEditor.tsx:43-69
//  （parseCapacity / formatCapacity 逐语义；十进制：1M = 1000K，与模型容量
//  通行口径一致——非 1024 进制）。
//  伴生：模型目录行级校验（dsh validateDeepSeekModels :94-123 语义，
//  独立 enum 便于单测直呼；契约类型 ModelCatalogEntry 见 A1 冻结接口，
//  本文件按契约签名消费，编译对齐属集成期合并面）。
//

import Foundation

/// K/M 容量文本双向换算（dsh DeepSeekModelsEditor.tsx:43-69 同语义纯函数）。
enum CapacityFormatting {

    /// 接受的容量写法：十进制数字 + 可选 K/M 后缀（大小写不限）。
    /// dsh CAPACITY_PATTERN `/^(\d+(?:\.\d+)?)([km])?$/i`（:31）。
    private static let capacityPattern = try! NSRegularExpression(
        pattern: #"^(\d+(?:\.\d+)?)([km])?$"#,
        options: [.caseInsensitive])

    /// 十进制后缀倍率——`1M` 是 1000K（dsh CAPACITY_SCALE :34）。
    private static let scaleK: Double = 1_000
    private static let scaleM: Double = 1_000_000

    /// 解析结果标记：不可读文本（dsh 以 NaN 表达，Swift 沿用 Double.nan，
    /// 调用方以 `number.isNaN` 判别后按行报错、文本保留在屏）。
    /// 空白文本返回 nil = 本字段继承缺省（dsh undefined 语义，:42）。
    static func parseCapacity(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = capacityPattern.firstMatch(in: trimmed, range: range),
              let numberPart = Range(match.range(at: 1), in: trimmed),
              let base = Double(trimmed[numberPart]) else {
            return Double.nan
        }
        var scale: Double = 1
        if match.range(at: 2).location != NSNotFound,
           let suffixRange = Range(match.range(at: 2), in: trimmed) {
            switch trimmed[suffixRange].lowercased() {
            case "k": scale = scaleK
            case "m": scale = scaleM
            default: break
            }
        }
        let scaled = base * scale
        // 十进制小数倍数意图上精确、二进制浮点不精确（2.3 * 1e6 会高出数个
        // ULP）——整值意图就近取整回正（dsh :51-54）。
        let rounded = scaled.rounded()
        return abs(scaled - rounded) < 1e-6 ? rounded : scaled
    }

    /// 存储计数反写为经 parseCapacity 往返不变形的最短形式；非千的整倍数
    /// 原样写全（dsh formatCapacity :64-69）。
    static func formatCapacity(_ value: Double) -> String {
        // 非整数或非正数：原样（dsh Number.isInteger / <=0 分支）。
        guard value.rounded() == value, value > 0 else {
            return Self.describe(value)
        }
        let whole = Int(value)
        if whole % 1_000_000 == 0 { return "\(whole / 1_000_000)M" }
        if whole % 1_000 == 0 { return "\(whole / 1_000)K" }
        return "\(whole)"
    }

    /// 存储计数（Int）便捷反写——目录条目容量字段为 Int?（契约）。
    static func formatCapacity(_ value: Int) -> String {
        formatCapacity(Double(value))
    }

    /// Double → 文本：整值去小数点，否则原样描述（对齐 dsh String(value)
    /// 对整数不带 .0 的行为）。
    private static func describe(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15
            ? String(Int(value))
            : String(format: "%g", value)
    }
}

/// 模型目录行级校验（dsh validateDeepSeekModels :94-123 语义——schema 表达
/// 不了的适配器约束在 UI 侧挡下，坏行按位置点名）。
/// 契约消费：`ModelCatalogEntry`（A1 冻结接口——id/name/description/
/// contextWindow/maxTokens/inputModalities），编译对齐属集成期合并面。
enum ModelCatalogValidation {

    /// 一个用户目录的校验失败（dsh DeepSeekModelsValidationFailure :72-78）。
    struct Failure: Equatable {
        /// 零起算的行位置。
        let index: Int
        /// 文案键（dsh key 词表原样）。
        let key: Key
    }

    enum Key: String, Equatable {
        case modelIdRequired
        case modelIdDuplicate
        case modelNameInvalid
        case modelContextInvalid
        case modelMaxTokensInvalid
    }

    /// 返回第一个坏行；目录整体继承（无 override）时调用方传 nil 即不校验。
    static func validate(_ models: [ModelCatalogEntry]?) -> Failure? {
        guard let models else { return nil }
        var seen = Set<String>()
        for (index, model) in models.enumerated() {
            // 按 trim 后比较：首尾空白是粘贴残留，adapter 永不匹配；不 trim
            // 的比较会让 "model " 躲过与自己的重名检查（dsh :99-105）。
            let trimmedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedID.isEmpty { return .init(index: index, key: .modelIdRequired) }
            if seen.contains(trimmedID) { return .init(index: index, key: .modelIdDuplicate) }
            seen.insert(trimmedID)
            if let name = model.name, name.isEmpty {
                return .init(index: index, key: .modelNameInvalid)
            }
            if let window = model.contextWindow, window <= 0 {
                return .init(index: index, key: .modelContextInvalid)
            }
            if let maxTokens = model.maxTokens, maxTokens <= 0 {
                return .init(index: index, key: .modelMaxTokensInvalid)
            }
        }
        return nil
    }
}
