//
//  MemoryTools.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6
//  codex-rs/ext/memories/src/）：
//    - lib.rs :18-22 —— 工具名与命名空间：namespace="memories"，list/read/search/
//      add_ad_hoc_note（万我扁平注册表 → wire 名 list_memories/read_memory/
//      search_memories/add_ad_hoc_note——派单拍板原名承接，namespace 语义并入
//      工具名，登记）。
//    - tools/{list,read,search,ad_hoc_note}.rs —— description 与参数 schema 逐字
//      （deny_unknown_fields；clamp_max_results：requested.unwrap_or(default)
//      .clamp(1, max)）；响应结构（backend.rs）逐字段；错误 =
//      backend_error_to_function_call 的 RespondToModel 面（Io=Fatal）→ 万我
//      ToolOutput.failure 文案 1:1。
//    - constants —— list 2000/2000、search 200/200、read max_tokens 20000。
//  万我适配（登记）：
//    - schemars JSON schema 生成面 → 手写等价 JSON Schema（万我
//      ToolRegistry schema 形态惯例，参照 TodoTool.buildParameters）。
//    - 后端为 MemoryBackend（宿主直读 memoryPersistentDir——件头注裁定）。
//

import Foundation

// MARK: - 注册面

/// memory read-path 系统段（codex build_memory_tool_developer_instructions 万我
/// 承载——prompts.rs :27-51 逐语义：memory_summary.md 读取 + trim + 2500 token
/// 截断 + read_path 模板 render(base_path, memory_summary)；空 summary = None →
/// 万我 nil = 不注册段落——assemble 空段落丢弃同语义）。万我 base_path =
/// memory guest 根（FsContextRouter 全局桶——模型可见路径体系）。
enum MemoryPromptSection {
    static func summarySection(summaryText: String) -> PromptSection? {
        let summary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let truncated = MemoryRollout.truncateToTokenEstimate(
            summary, MemoryConstants.memorySummaryTokenLimit)
        let rendered = MemoryTemplates.render(MemoryTemplates.readPath, [
            ("base_path", MemoryConstants.memoryGuestPath),
            ("memory_summary", truncated),
        ])
        return PromptSection(name: "memory:read-path",
                             order: SECTION_ORDERS.memorySummary,
                             text: rendered)
    }
}

/// 四工具注册（AppEnvironment.makeAgentStack 装配；幂等性由调用面单次保证）。
enum MemoryTools {
    static func registerAll(into registry: ToolRegistry, backend: MemoryBackend) {
        registry.register(MemoryListTool(backend: backend))
        registry.register(MemoryReadTool(backend: backend))
        registry.register(MemorySearchTool(backend: backend))
        registry.register(MemoryAddAdHocNoteTool(backend: backend))
    }

    /// clamp_max_results 1:1（tools/mod.rs :91-93）。
    static func clampMaxResults(_ requested: Int?, default def: Int, cap: Int) -> Int {
        min(Swift.max(requested ?? def, 1), cap)
    }

    /// 后端错误 → 工具失败输出（backend_error_to_function_call RespondToModel 面；
    /// 文案与 MemoriesBackendError Display 1:1——MemoryError.message 承载）。
    static func backendFailure(_ error: Error) -> ToolOutput {
        .failure((error as? MemoryError)?.description ?? String(describing: error),
                 code: "MEMORIES_BACKEND", name: "MemoriesBackendError")
    }
}

// MARK: - list_memories（tools/list.rs）

struct MemoryListTool: AgentTool {
    let name = "list_memories"
    let description = "List immediate files and directories under a path in the Codex memories store."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path within the memories store."),
            ]),
            "cursor": .object([
                "type": .string("string"),
                "description": .string("Opaque pagination cursor from a previous response."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("Maximum entries to return (default 2000, cap 2000)."),
                "minimum": .int(1),
            ]),
        ],
        required: [])
    let backend: MemoryBackend

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "List memories")
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let maxResults = MemoryTools.clampMaxResults(
            args.field("max_results")?.intValue,
            default: MemoryConstants.listDefaultMaxResults,
            cap: MemoryConstants.listMaxResults)
        // QA-5 P2-③：cursor 非法拒绝（codex local.rs :39-43 invalid_cursor
        // 语义——非整数字符串报错回模型，不静默回落 0）。
        let cursor: Int
        if let raw = args.field("cursor")?.stringValue {
            guard let parsed = Int(raw) else {
                return .failure("invalid cursor: '\(raw)'", code: "INVALID_CURSOR",
                                name: "MemoriesBackendError")
            }
            cursor = parsed
        } else {
            cursor = 0
        }
        do {
            let response = try backend.list(
                path: args.field("path")?.stringValue,
                cursor: cursor,
                maxResults: maxResults)
            let value: JSONValue = .object([
                "path": args.field("path") ?? .null,
                "entries": .array(response.entries.map {
                    .object(["path": .string($0.path), "entry_type": .string($0.entryType)])
                }),
                "next_cursor": response.nextCursor.map { .string($0) } ?? .null,
                "truncated": .bool(response.truncated),
            ])
            return .success(renderEntries(response.entries), meta: value)
        } catch {
            return MemoryTools.backendFailure(error)
        }
    }

    private func renderEntries(_ entries: [MemoryBackendEntry]) -> String {
        guard !entries.isEmpty else { return "No entries." }
        return entries.map { entry in
            "\(entry.entryType == "directory" ? "[dir] " : "")\(entry.path)"
        }.joined(separator: "\n")
    }
}

// MARK: - read_memory（tools/read.rs）

struct MemoryReadTool: AgentTool {
    let name = "read_memory"
    let description = "Read a Codex memory file by relative path, optionally starting at a 1-indexed line offset and limiting the number of lines returned."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path within the memories store."),
            ]),
            "line_offset": .object([
                "type": .string("integer"),
                "description": .string("1-indexed line to start reading from."),
                "minimum": .int(1),
            ]),
            "max_lines": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of lines to return."),
                "minimum": .int(1),
            ]),
        ],
        required: ["path"])
    let backend: MemoryBackend

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .file, title: "Read memory",
                       detail: args.field("path")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let path = args.field("path")?.stringValue else {
            return .failure("path is required", code: "INVALID_ARGS", name: "MemoriesBackendError")
        }
        do {
            let response = try backend.read(
                path: path,
                lineOffset: args.field("line_offset")?.intValue ?? 1,
                maxLines: args.field("max_lines")?.intValue,
                maxTokens: MemoryConstants.readMaxTokens)
            let value: JSONValue = .object([
                "path": .string(response.path),
                "start_line_number": .int(response.startLineNumber),
                "content": .string(response.content),
                "truncated": .bool(response.truncated),
            ])
            return .success(response.content, meta: value)
        } catch {
            return MemoryTools.backendFailure(error)
        }
    }
}

// MARK: - search_memories（tools/search.rs）

struct MemorySearchTool: AgentTool {
    let name = "search_memories"
    let description = "Search Codex memory files for substring matches, optionally normalizing separators or requiring all query substrings on the same line or within a line window."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "queries": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Substring queries; every query must be non-empty."),
            ]),
            "match_mode": .object([
                "type": .string("object"),
                "description": .string(
                    "Match mode: {\"type\":\"any\"}, {\"type\":\"all_on_same_line\"}, "
                        + "or {\"type\":\"all_within_lines\",\"line_count\":N}."),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to scope the search."),
            ]),
            "cursor": .object([
                "type": .string("string"),
                "description": .string("Opaque pagination cursor from a previous response."),
            ]),
            "context_lines": .object([
                "type": .string("integer"),
                "description": .string("Context lines around each match."),
                "minimum": .int(0),
            ]),
            "case_sensitive": .object([
                "type": .string("boolean"),
                "description": .string("Case-sensitive matching (default true)."),
            ]),
            "normalized": .object([
                "type": .string("boolean"),
                "description": .string("Compare alphanumeric-normalized text (default false)."),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("Maximum matches to return (default 200, cap 200)."),
                "minimum": .int(1),
            ]),
        ],
        required: ["queries"])
    let backend: MemoryBackend

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .search, title: "Search memories",
                       detail: args.field("path")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let rawQueries = args.field("queries")?.arrayItems else {
            return .failure("queries must be an array of strings",
                            code: "INVALID_ARGS", name: "MemoriesBackendError")
        }
        let queries = rawQueries.compactMap(\.stringValue)
        guard queries.count == rawQueries.count else {
            return .failure("queries must be an array of strings",
                            code: "INVALID_ARGS", name: "MemoriesBackendError")
        }
        let matchMode: MemorySearchMatchMode
        if let raw = args.field("match_mode"),
           let decoded = try? JSONDecoder().decode(
            MemorySearchMatchMode.self, from: MemoryRollout.serializeJSON(raw).data(using: .utf8) ?? Data()) {
            matchMode = decoded
        } else {
            matchMode = .any // SearchArgs.into_request unwrap_or(Any)
        }
        let maxResults = MemoryTools.clampMaxResults(
            args.field("max_results")?.intValue,
            default: MemoryConstants.searchDefaultMaxResults,
            cap: MemoryConstants.searchMaxResults)
        // QA-5 P2-③：cursor 非法拒绝（codex search.rs :39-43 invalid_cursor
        // 语义——非整数字符串报错回模型，不静默回落 0）。
        let cursor: Int
        if let raw = args.field("cursor")?.stringValue {
            guard let parsed = Int(raw) else {
                return .failure("invalid cursor: '\(raw)'", code: "INVALID_CURSOR",
                                name: "MemoriesBackendError")
            }
            cursor = parsed
        } else {
            cursor = 0
        }
        do {
            let response = try backend.search(
                queries: queries,
                matchMode: matchMode,
                path: args.field("path")?.stringValue,
                cursor: cursor,
                contextLines: args.field("context_lines")?.intValue ?? 0,
                caseSensitive: args.field("case_sensitive")?.boolValue ?? true,
                normalized: args.field("normalized")?.boolValue ?? false,
                maxResults: maxResults)
            let value: JSONValue = .object([
                "queries": .array(queries.map { .string($0) }),
                "match_mode": encodeMatchMode(matchMode),
                "path": args.field("path") ?? .null,
                "matches": .array(response.matches.map { match in
                    .object([
                        "path": .string(match.path),
                        "match_line_number": .int(match.matchLineNumber),
                        "content_start_line_number": .int(match.contentStartLineNumber),
                        "content": .string(match.content),
                        "matched_queries": .array(match.matchedQueries.map { .string($0) }),
                    ])
                }),
                "next_cursor": response.nextCursor.map { .string($0) } ?? .null,
                "truncated": .bool(response.truncated),
            ])
            let text = response.matches.isEmpty
                ? "No matches."
                : response.matches.map { match in
                    "\(match.path):\(match.matchLineNumber)\n\(match.content)"
                }.joined(separator: "\n---\n")
            return .success(text, meta: value)
        } catch {
            return MemoryTools.backendFailure(error)
        }
    }

    private func encodeMatchMode(_ mode: MemorySearchMatchMode) -> JSONValue {
        switch mode {
        case .any:
            return .object(["type": .string("any")])
        case .allOnSameLine:
            return .object(["type": .string("all_on_same_line")])
        case .allWithinLines(let count):
            return .object(["type": .string("all_within_lines"),
                            "line_count": .int(count)])
        }
    }
}

// MARK: - add_ad_hoc_note（tools/ad_hoc_note.rs）

struct MemoryAddAdHocNoteTool: AgentTool {
    let name = "add_ad_hoc_note"
    let description = "Create one append-only ad-hoc memory note after the user explicitly asks Codex to remember, forget, or update something."
    let parameters: JSONValue = .schemaObject(
        properties: [
            "filename": .object([
                "type": .string("string"),
                "description": .string(
                    "Name of the note file to create, in "
                        + "YYYY-MM-DDTHH-MM-SS-<slug>.md format. The slug must use only lowercase "
                        + "ASCII letters, digits, and hyphens."),
            ]),
            "note": .object([
                "type": .string("string"),
                "description": .string("Verbatim Markdown note to append to the ad-hoc memory notes."),
            ]),
        ],
        required: ["filename", "note"])
    let backend: MemoryBackend

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Add ad-hoc memory note",
                       detail: args.field("filename")?.stringValue)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let filename = args.field("filename")?.stringValue,
              let note = args.field("note")?.stringValue else {
            return .failure("filename and note are required",
                            code: "INVALID_ARGS", name: "MemoriesBackendError")
        }
        do {
            try backend.addAdHocNote(filename: filename, note: note)
            // AddAdHocMemoryNoteResponse {} —— 空对象输出 1:1。
            return .success("Ad-hoc memory note created.", meta: .object([:]))
        } catch {
            return MemoryTools.backendFailure(error)
        }
    }
}
