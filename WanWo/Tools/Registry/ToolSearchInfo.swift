//
//  ToolSearchInfo.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs tools/src/tool_search.rs:11-156
//  （ToolSearchEntry / ToolSearchInfo / default_tool_search_text /
//  append_function_search_text / append_schema_search_text / push_search_part，
//  逐式对拍）+ handlers/tool_search.rs:17（ToolSearchSourceInfo import 面）。
//  语料纪律（10-design:397-403 F023 条文）：语料 = 名称 + 下划线空格变体 +
//  描述 + schema 属性名/属性描述递归展开——**不含完整 parameters**（防语料
//  膨胀；type/required/additionalProperties 等非检索字段不进语料）。
//  平台差异登记：
//    · codex from_spec 的 defer_loading=true + output_schema=None 剥离
//      （tool_search.rs:39-40）不适用——WanWo AgentTool spec 无此二字段；
//    · codex LoadableToolSpec::Namespace（Responses API namespace 载体）→
//      WanWo 无 namespace 词汇，命中输出 = function spec object（C5 激活面
//      按此注入下一请求 tools 数组，gap11 §八.2 等价判定）。
//

import Foundation

/// tool_search 来源信息（codex ToolSearchSourceInfo 1:1：server 名 + 可选描述；
/// C7 来源清单渲染的消费面）。
struct ToolSearchSourceInfo: Equatable, Sendable {
    let name: String
    let description: String?
}

/// 单个可发现工具的检索语料 + 命中输出载荷（codex ToolSearchInfo 形态）。
struct ToolSearchInfo: Equatable, Sendable {

    /// 检索条目（codex ToolSearchEntry）。
    struct Entry: Equatable, Sendable {
        /// BM25 语料（构建规则见文件头；不含完整 parameters）。
        let searchText: String
        /// 命中输出载荷：LoadableToolSpec 的 WanWo 形 = function spec object
        /// {name, description, parameters}（C5 激活面注入下一请求 tools 数组）。
        let output: JSONValue
    }

    let entry: Entry
    /// 来源信息（MCP 工具携带 server 名+描述供 C7 来源清单；内置/无源工具为 nil）。
    let sourceInfo: ToolSearchSourceInfo?
}

extension ToolSearchInfo {

    /// 语料构建（codex default_tool_search_text 的 function 分支同构：
    /// tool_search.rs:124-129 append_function_search_text + :131-149
    /// append_schema_search_text + :151-156 push_search_part）。
    static func from(name: String,
                     description: String,
                     parameters: JSONValue,
                     sourceInfo: ToolSearchSourceInfo?) -> ToolSearchInfo {
        var parts: [String] = []
        // codex :125-126：名称原样 + 下划线空格变体（BM25 分词在空格边界断词，
        // 下划线连写名靠变体进语料）。
        pushSearchPart(name, into: &parts)
        pushSearchPart(name.replacingOccurrences(of: "_", with: " "), into: &parts)
        pushSearchPart(description, into: &parts)
        appendSchemaSearchText(parameters, into: &parts)

        let entry = Entry(
            searchText: parts.joined(separator: " "),
            output: .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": parameters,
            ]))
        return ToolSearchInfo(entry: entry, sourceInfo: sourceInfo)
    }

    /// schema 递归展开（codex append_schema_search_text 逐式同构）：
    /// schema 自身 description + 属性名（递归进入其 schema）+ items + anyOf；
    /// 其余字段（type/required/additionalProperties/default/…）不进语料。
    private static func appendSchemaSearchText(_ schema: JSONValue,
                                               into parts: inout [String]) {
        if let description = schema.field("description")?.stringValue {
            pushSearchPart(description, into: &parts)
        }
        // codex JsonSchema.properties = BTreeMap（键序确定性）；Swift 侧排序对齐。
        if let properties = schema.field("properties")?.objectFields {
            for (propertyName, subSchema) in properties.sorted(by: { $0.key < $1.key }) {
                pushSearchPart(propertyName, into: &parts)
                appendSchemaSearchText(subSchema, into: &parts)
            }
        }
        if let items = schema.field("items") {
            appendSchemaSearchText(items, into: &parts)
        }
        if let variants = schema.field("anyOf")?.arrayItems {
            for variant in variants {
                appendSchemaSearchText(variant, into: &parts)
            }
        }
    }

    /// codex push_search_part（:151-156）：trim 后非空才收。
    private static func pushSearchPart(_ part: String, into parts: inout [String]) {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
    }
}
