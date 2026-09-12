//
//  ToolSearchSourceListing.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs core/src/tools/handlers/tool_search_spec.rs:34-89
//  （create_tool_search_tool 的 Include 变体来源清单渲染，逐式端口）+
//  codex_utils_string::take_bytes_at_char_boundary（:78-79 消费面——Swift UTF-8
//  边界安全截断，语义等价登记）。
//  Include/Omit 门控取证（C7 呈报项 3，已亲验）：ToolSearchSourceListing 的
//  取值唯一消费点 = spec_plan.rs:1390-1407 append_tool_search_executor——
//  `turn_context.config.features.enabled(Feature::DeferredToolWorldState)` 为真
//  ⇒ Omit，否则 Include（:1396-1404）；handler cache（tool_search.rs:50-130
//  get_or_build）仅以 source_listing 作缓存键分量（:284-289 测试锚），无其他
//  Include/Omit 语义。WanWo 无 DeferredToolWorldState 特性词汇（无 world-state
//  广告面）→ 恒 Include（来源清单随 description 渲染）。
//  平台差异登记：
//    · Rust BTreeMap<String, Option<String>>（UTF-8 字节序键序）→ Swift 字典
//      + 输出面按 name 的 UTF-8 字节序字典序排序（ASCII 名完全等价）；
//    · 去重语义（:38-45 and_modify/or_insert 逐式）：同 name 首个非 nil
//      description 生效——首个即 nil 时由后见非 nil 补位；
//    · 迭代序：codex = search_infos 注册序 → WanWo = deferredTools() 字典序
//      （确定性——排序输出后迭代序不影响渲染结果，字节稳定前提成立）；
//    · 512KB 为逐清单聚合预算（reserved_name_bytes 预扣 + 逐条 required 判定
//      超预算 continue + description 按 description_budget 字符边界截断），
//      非逐条独立预算；名字行不截断（放不下即整条跳过）。
//

import Foundation

/// C7 来源清单渲染（codex tool_search_spec.rs Include 变体的纯函数端口；
/// 同输入字节稳定——ToolSearchTool description 缓存的底层保证）。
enum ToolSearchSourceListing {

    /// codex :8 MAX_TOOL_SEARCH_SOURCE_DESCRIPTION_BYTES = 512 * 1024。
    static let maxSourceDescriptionBytes = 512 * 1024

    /// source_section 包装（codex :86-88 format! 逐字：首尾 \n 归属本段——
    /// Include 形态下「Some of the tools…」指引紧随尾 \n，无空行）。
    static func sourceSection(from sources: [ToolSearchSourceInfo]) -> String {
        "\n\nYou have access to tools from the following sources:\n"
            + "\(renderSourceDescriptions(sources))\n"
    }

    /// 来源清单渲染（codex :36-85 逐式端口，差异登记见文件头）。
    /// - Returns: 空清单 → "None currently enabled."（:48-49）；否则
    ///   按 name 字节序的 `- {name}` / `- {name}: {description}` 行集。
    static func renderSourceDescriptions(_ sources: [ToolSearchSourceInfo]) -> String {
        // :36-46——BTreeMap 去重：or_insert（首见插入，可 nil）+ and_modify
        // （existing 为 nil 时才被后见非 nil 补位；已有非 nil 恒保留）。
        var byName: [String: String?] = [:]
        for source in sources {
            switch byName[source.name] {
            case .none, .some(.none): byName[source.name] = source.description
            case .some(.some): break
            }
        }
        // :48-49——空清单固定文案。
        guard !byName.isEmpty else { return "None currently enabled." }

        // Rust BTreeMap 键序 = UTF-8 字节序（按字节字典序对齐）。
        let entries = byName
            .map { (name: $0.key, description: $0.value) }
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }

        // :51-56——reserved_name_bytes 预扣：全部「- name」行 + 行间 \n 分隔的
        // 总字节（count-1 起，逐名 +2 + name 字节数，饱和运算），description
        // 预算 = 512KB 减去该预留。
        var reservedNameBytes = satSub(entries.count, 1)
        for entry in entries {
            reservedNameBytes = satAdd(satAdd(reservedNameBytes, 2), entry.name.utf8.count)
        }
        var descriptionBudget = satSub(maxSourceDescriptionBytes, reservedNameBytes)

        var rendered = ""
        for entry in entries {
            // :59-65——逐条 required 判定：本条「- name」（连分隔符）放不进
            // 当前累计面则整条跳过（continue；description 不参与本判定）。
            let separatorBytes = rendered.isEmpty ? 0 : 1
            let required = satAdd(satAdd(separatorBytes, 2), entry.name.utf8.count)
            if required > satSub(maxSourceDescriptionBytes, rendered.utf8.count) {
                continue
            }
            if !rendered.isEmpty { rendered += "\n" }
            rendered += "- "
            rendered += entry.name
            // :73-82——description 预算内截断：先扣 ": " 两字节，再按字符边界
            // 取字节；预算 < 2 时整段描述跳过（行仅出名字，codex 同式）。
            if let description = entry.description, descriptionBudget >= 2 {
                rendered += ": "
                descriptionBudget -= 2
                let bounded = takeBytesAtCharBoundary(description, descriptionBudget)
                rendered += bounded
                descriptionBudget -= bounded.utf8.count
            }
        }
        return rendered
    }

    /// codex take_bytes_at_char_boundary（codex_utils_string）的 Swift 等价：
    /// 取不超过 maxBytes 的最长前缀，且截断点落在 UTF-8 字符边界（不劈开
    /// 多字节字符——回退尾部 continuation 字节 0b10xxxxxx 至起始字节）。
    static func takeBytesAtCharBoundary(_ value: String, _ maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let bytes = Array(value.utf8)
        guard bytes.count > maxBytes else { return value }
        var end = maxBytes
        while end > 0 && bytes[end] & 0b1100_0000 == 0b1000_0000 {
            end -= 1
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    // MARK: 饱和运算（codex saturating_add/sub 语义 1:1）

    private static func satAdd(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : result
    }

    private static func satSub(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? 0 : result
    }
}
