//
//  FsTools.swift
//  WanWo
//
//  【语义移植 · dsh + 10-design】出处：
//    - dsh packages/fs/tool-fs（read/write/edit、read_image）与 tool-fs-search
//      （glob/grep）、tool-str-replace-editor——wire 工具名与参数名 1:1：
//      read{file_path,offset,limit} / write{file_path,content} /
//      edit{file_path,old_string,new_string,replace_all} / glob{pattern,path} /
//      grep{pattern,path,include} / read_image{file_path} /
//      str_replace_editor{command,path,file_text,old_str,new_str,insert_line,view_range}
//    - 10-design §十一 M2.5（F014：7 件、宿主直读、纯 Swift 遍历不 spawn rg、
//      read-match-write 临界区）
//  环境纪律：iOS 禁 spawn——glob/grep 用宿主原生遍历 + NSRegularExpression；
//  rg 语法子集由「ripgrep 兼容的正则 + include 通配」近似承载（偏差见交付报告）。
//

import Foundation

// MARK: - 读取工具

/// dsh read：UTF-8 文本文件，行号输出（cat -n 风格），offset/limit 续读大文件。
struct FsReadTool: AgentTool {
    let name = "read"
    let description = "Read a UTF-8 text file and return line-numbered content. "
        + "Use offset and limit to continue reading large files."
    let parameters = JSONValue.schemaObject(
        properties: [
            "file_path": .stringSchema(description: "Path to read, resolved by the filesystem backend."),
            "offset": .numberSchema(description: "1-based first line to return. Defaults to 1."),
            "limit": .numberSchema(description: "Maximum number of lines to return. Defaults to 2000."),
        ],
        required: ["file_path"])

    static let defaultLimit = 2_000
    /// 单文件读取字符上限（§十三：16000 字符语义对齐）。
    static let maxChars = 16_000
    /// 单行最大字符（dsh read maxLineLength 语义：防 minified 单行爆预算）。
    static let maxLineLength = 2_000

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let path = args.objectValue?["file_path"]?.stringValue else {
            return .failure("missing required parameter \"file_path\"", code: "INVALID_ARGS")
        }
        let workspace = ctx.workspace
        guard workspace.exists(path) else {
            return .failure("file not found: \(path)", code: "FILE_NOT_FOUND")
        }
        let text: String
        do { text = try workspace.readText(path) } catch {
            return .failure(String(describing: error), code: "READ_FAILED")
        }
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, args.objectValue?["offset"]?.intValue ?? 1)
        let limit = args.objectValue?["limit"]?.intValue ?? Self.defaultLimit
        let start = min(offset - 1, lines.count)
        var slice = Array(lines[start..<min(start + max(1, limit), lines.count)])

        // 字符预算：超限从尾部丢行并标注。
        var total = slice.reduce(0) { $0 + $1.count + 1 }
        while total > Self.maxChars, slice.count > 1 {
            total -= slice.removeLast().count + 1
        }
        // 单行截断（dsh maxLineLength 语义）：防 minified 单行文件爆预算。
        var truncatedAny = false
        slice = slice.map { line in
            guard line.count > Self.maxLineLength else { return line }
            truncatedAny = true
            return String(line.prefix(Self.maxLineLength)) + "…[line truncated]"
        }
        var out = slice.enumerated().map { (i, line) in
            "\(String(start + i + 1).padding(toLength: 6, withPad: " ", startingAt: 0))\t\(line)"
        }.joined(separator: "\n")
        if truncatedAny {
            out += "\n… (some lines exceeded \(Self.maxLineLength) chars and were truncated)"
        }
        if start + slice.count < lines.count {
            out += "\n… (file has \(lines.count) lines; showing \(start + 1)–\(start + slice.count); "
                + "continue with offset=\(start + slice.count + 1))"
        }
        return .success(out.isEmpty ? "(empty file)" : out)
    }
}

// MARK: - 写入工具

/// dsh write：创建或整体替换 UTF-8 文本文件（原子写；临界区内）。
struct FsWriteTool: AgentTool {
    let name = "write"
    let description = "Create or fully replace a UTF-8 text file. Existing files are overwritten; "
        + "read an existing file first and prefer edit for targeted changes."
    let parameters = JSONValue.schemaObject(
        properties: [
            "file_path": .stringSchema(description: "Path to write, resolved by the filesystem backend."),
            "content": .stringSchema(description: "Full UTF-8 text content to write."),
        ],
        required: ["file_path", "content"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let path = args.objectValue?["file_path"]?.stringValue,
              let content = args.objectValue?["content"]?.stringValue else {
            return .failure("missing required parameters \"file_path\"/\"content\"", code: "INVALID_ARGS")
        }
        let workspace = ctx.workspace
        let existed = workspace.exists(path)
        do {
            // dsh write 语义 =「创建或整体替换」：不走 mutate（read-match-write
            // 是 edit 族语义，对不存在的文件会读打开失败 → NSCocoaErrorDomain
            // 260，ERR-013 真根因）。原子性由 writeData 的 .atomic + 独占并发保证。
            _ = try workspace.writeData(path, data: Data(content.utf8))
        } catch {
            return .failure(String(describing: error), code: "WRITE_FAILED")
        }
        return .success(existed ? "File updated: \(path)"
                                : "File created: \(path) (\(content.utf8.count) bytes)")
    }
}

// MARK: - 编辑工具

/// dsh edit：字面量替换（默认 old_string 必须唯一命中；replace_all 覆盖全部）。
struct FsEditTool: AgentTool {
    let name = "edit"
    let description = "Edit an existing UTF-8 text file by replacing literal text. "
        + "By default old_string must appear exactly once; provide a more specific old_string "
        + "or set replace_all to true. Read the file first."
    let parameters = JSONValue.schemaObject(
        properties: [
            "file_path": .stringSchema(description: "Path to edit, resolved by the filesystem backend."),
            "old_string": .stringSchema(description: "Literal text to replace. Must match exactly."),
            "new_string": .stringSchema(description: "Literal replacement text. Use an empty string to delete the match."),
            "replace_all": .booleanSchema(description: "Replace all matches. Defaults to false."),
        ],
        required: ["file_path", "old_string", "new_string"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let path = args.objectValue?["file_path"]?.stringValue,
              let oldString = args.objectValue?["old_string"]?.stringValue,
              let newString = args.objectValue?["new_string"]?.stringValue else {
            return .failure("missing required parameters \"file_path\"/\"old_string\"/\"new_string\"",
                            code: "INVALID_ARGS")
        }
        guard !oldString.isEmpty else {
            return .failure("old_string must not be empty", code: "INVALID_ARGS")
        }
        let replaceAll = args.objectValue?["replace_all"]?.boolValue ?? false
        let workspace = ctx.workspace
        do {
            let next = try workspace.mutate(path) { current in
                let occurrences = current.components(separatedBy: oldString).count - 1
                if occurrences == 0 {
                    throw FsToolFailure("old_string not found in \(path)")
                }
                if occurrences > 1 && !replaceAll {
                    throw FsToolFailure(
                        "old_string appears \(occurrences) times in \(path); "
                            + "provide a more specific old_string or set replace_all=true")
                }
                return current.replacingOccurrences(of: oldString, with: newString)
            }
            return .success("Edited \(path): replaced \(replaceAll ? "all" : "1") occurrence(s) of "
                                + "\(oldString.count) chars with \(newString.count) chars "
                                + "(\(next.utf8.count) bytes written)")
        } catch let failure as FsToolFailure {
            return .failure(failure.message, code: "EDIT_FAILED")
        } catch {
            return .failure(String(describing: error), code: "EDIT_FAILED")
        }
    }
}

/// 工具内部失败（文本身份；不抛穿 loop——管线统一合成）。
struct FsToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Glob 工具

/// dsh glob：路径模式匹配；修改时间序；上限 100 条；排除 VCS 元数据目录。
struct FsGlobTool: AgentTool {
    let name = "glob"
    let description = "Find files whose paths match a glob pattern. Returns matching file paths in "
        + "modification-time order (newest first), up to 100 results. This tool does not enumerate "
        + "directory entries — only regular files."
    let parameters = JSONValue.schemaObject(
        properties: [
            "pattern": .stringSchema(description: "Glob pattern, e.g. \"**/*.swift\" or \"src/*.ts\"."),
            "path": .stringSchema(description: "Directory to search. Defaults to the session workspace root."),
        ],
        required: ["pattern"])

    static let maxResults = 100

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let pattern = args.objectValue?["pattern"]?.stringValue else {
            return .failure("missing required parameter \"pattern\"", code: "INVALID_ARGS")
        }
        let workspace = ctx.workspace
        let baseTail = args.objectValue?["path"]?.stringValue
        guard let base = baseTail.flatMap({ workspace.resolve($0) }) ?? Optional(workspace.rootURL) else {
            return .failure("path escapes the workspace root", code: "INVALID_ARGS")
        }
        guard let regex = Self.globRegex(pattern: pattern) else {
            return .failure("invalid glob pattern: \(pattern)", code: "INVALID_ARGS")
        }
        let files = workspace.recursiveFiles()
            .filter { $0.path.hasPrefix(base.path) }
            // ERR-018：dsh glob 模式相对搜索目录匹配——对绝对路径匹配 `*`
            // （^[^/]*$）永远失败（真机实证：`*` 搜不到 hello.txt 而 `**/*` 能）。
            .filter { url -> Bool in
                var tail = String(url.path.dropFirst(base.path.count))
                if tail.hasPrefix("/") { tail.removeFirst() }
                return regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
            }
        func mtime(_ url: URL) -> TimeInterval {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? nil ?? 0
        }
        let sorted = files.sorted { mtime($0) > mtime($1) }
        var rootPrefix = workspace.rootURL.path
        if rootPrefix.hasSuffix("/") { rootPrefix.removeLast() }
        let names = sorted.prefix(Self.maxResults).map { url -> String in
            var p = url.path
            if p.hasPrefix("/private" + rootPrefix) { p = String(p.dropFirst("/private".count)) }
            return p.hasPrefix(rootPrefix) ? String(p.dropFirst(rootPrefix.count + 1)) : p
        }
        if names.isEmpty { return .success("No files match \(pattern)") }
        var text = names.joined(separator: "\n")
        if sorted.count > Self.maxResults {
            text += "\n… and \(sorted.count - Self.maxResults) more (showing newest \(Self.maxResults))"
        }
        return .success(text)
    }

    /// 受限 glob → 正则（** 跨目录、* 单段、? 单字符；其余字符字面量）。
    static func globRegex(pattern: String) -> NSRegularExpression? {
        var rx = "^"
        var iterator = pattern.makeIterator()
        while let ch = iterator.next() {
            switch ch {
            case "*":
                if iterator.next() == "*" {
                    rx += ".*"
                } else {
                    rx += "[^/]*"
                }
            case "?": rx += "[^/]"
            case ".", "(", ")", "[", "]", "{", "}", "+", "^", "$", "|", "\\":
                rx += "\\" + String(ch)
            default: rx += String(ch)
            }
        }
        return try? NSRegularExpression(pattern: rx + "$")
    }
}

// MARK: - Grep 工具

/// dsh grep：内容正则搜索；按文件分组带行号；上限 200 条；include 单 glob 过滤。
struct FsGrepTool: AgentTool {
    let name = "grep"
    let description = "Search file contents with a regular expression. Returns matching lines with "
        + "line numbers, grouped by file. Use read on a matched file for surrounding context."
    let parameters = JSONValue.schemaObject(
        properties: [
            "pattern": .stringSchema(description: "Regular expression to search for."),
            "path": .stringSchema(description: "File or directory to search. Defaults to the session workspace; a relative path resolves against it."),
            "include": .stringSchema(description: "One glob filter for which files to search (e.g. \"*.ts\"). Not a list; negation is not supported."),
        ],
        required: ["pattern"])

    static let maxMatches = 200

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let pattern = args.objectValue?["pattern"]?.stringValue else {
            return .failure("missing required parameter \"pattern\"", code: "INVALID_ARGS")
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return .failure("invalid regular expression: \(pattern)", code: "INVALID_ARGS")
        }
        let includeRegex = (args.objectValue?["include"]?.stringValue)
            .flatMap(FsGlobTool.globRegex(pattern:))
        let workspace = ctx.workspace
        var files: [URL]
        if let path = args.objectValue?["path"]?.stringValue {
            if workspace.exists(path), let resolved = workspace.resolve(path),
               resolved.hasDirectoryPath {
                files = workspace.recursiveFiles().filter { $0.path.hasPrefix(resolved.path) }
            } else {
                files = [workspace.resolve(path)].compactMap { $0 }
            }
        } else {
            files = workspace.recursiveFiles()
        }
        if let includeRegex {
            files = files.filter {
                includeRegex.firstMatch(in: $0.lastPathComponent,
                                        range: NSRange($0.lastPathComponent.startIndex..., in: $0.lastPathComponent)) != nil
            }
        }

        var output: [String] = []
        var matchCount = 0
        var capped = false
        let sorted = files.sorted { $0.path < $1.path }
        for file in sorted {
            guard matchCount < Self.maxMatches else { capped = true; break }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var fileHits: [String] = []
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    fileHits.append("\(index + 1):\(line.prefix(400))")
                    matchCount += 1
                    if matchCount >= Self.maxMatches { capped = true; break }
                }
            }
            if !fileHits.isEmpty {
                var display = file.path
                let root = workspace.rootURL.path
                if display.hasPrefix("/private" + root) { display = String(display.dropFirst("/private".count)) }
                if display.hasPrefix(root) { display = String(display.dropFirst(root.count + 1)) }
                output.append("\(display)\n" + fileHits.joined(separator: "\n"))
            }
            if capped { break }
        }
        if output.isEmpty { return .success("No matches for \(pattern)") }
        var text = output.joined(separator: "\n")
        if capped {
            text += "\n… (result capped at \(Self.maxMatches) matches)"
        }
        return .success(text)
    }
}

// MARK: - 图片读取工具

/// dsh read_image：M2 文本通道形态——图片元信息回注模型，原图经 meta 供工具卡
/// 与附件通道呈现（多模态消息角色随 M9 语义对齐再升级；偏差记交付报告）。
struct FsReadImageTool: AgentTool {
    let name = "read_image"
    let description = "Read a PNG/JPEG/WebP/GIF file and return its metadata. The image itself is "
        + "presented in the tool card; the model receives size/format information."
    let parameters = JSONValue.schemaObject(
        properties: [
            "file_path": .stringSchema(description: "Path to the image file."),
        ],
        required: ["file_path"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let path = args.objectValue?["file_path"]?.stringValue else {
            return .failure("missing required parameter \"file_path\"", code: "INVALID_ARGS")
        }
        let workspace = ctx.workspace
        guard let url = workspace.resolve(path), FileManager.default.fileExists(atPath: url.path) else {
            return .failure("file not found: \(path)", code: "FILE_NOT_FOUND")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure("failed to read: \(path)", code: "READ_FAILED")
        }
        let (format, dimension) = Self.probe(data)
        let sizeKB = data.count / 1024
        let imageMeta: [String: JSONValue] = [
            "path": .string(path),
            "format": .string(format),
            "bytes": .int(data.count),
        ]
        var output = ToolOutput.success(
            "[image: \(path), \(format)\(dimension), \(max(1, sizeKB)) KB] "
                + "Image is presented to the user in the tool card.")
        output.meta = .object(imageMeta)
        return output
    }

    /// 文件头探测格式 + PNG/JPEG 尺寸（纯 Swift，无 ImageIO 依赖即可出尺寸信息）。
    static func probe(_ data: Data) -> (format: String, dimension: String) {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            var dim = ""
            if data.count >= 24 {
                let w = Int(data[data.startIndex + 16]) << 24 | Int(data[data.startIndex + 17]) << 16
                    | Int(data[data.startIndex + 18]) << 8 | Int(data[data.startIndex + 19])
                let h = Int(data[data.startIndex + 20]) << 24 | Int(data[data.startIndex + 21]) << 16
                    | Int(data[data.startIndex + 22]) << 8 | Int(data[data.startIndex + 23])
                dim = " \(w)x\(h)"
            }
            return ("PNG", dim)
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return ("JPEG", "") }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return ("GIF", "") }
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return ("WebP", "") }
        return ("unknown", "")
    }
}

// MARK: - str_replace_editor

/// dsh str_replace_editor：view/create/str_replace/insert 四命令（Anthropic 风格编辑器）。
struct FsStrReplaceEditorTool: AgentTool {
    let name = "str_replace_editor"
    let description = "Custom editing tool. Commands: `view` (show file with line numbers), "
        + "`create` (new file with file_text), `str_replace` (replace old_str with new_str, "
        + "must be unique), `insert` (insert new_str after line insert_line)."
    let parameters = JSONValue.schemaObject(
        properties: [
            "command": .stringSchema(description: "One of: view, create, str_replace, insert."),
            "path": .stringSchema(description: "Path to file (or directory for view)."),
            "file_text": .stringSchema(description: "Required by `create`: full file content."),
            "old_str": .stringSchema(description: "Required by `str_replace`: literal text to replace."),
            "new_str": .stringSchema(description: "Replacement text (`str_replace`) or inserted text (`insert`)."),
            "insert_line": .numberSchema(description: "Required by `insert`: new_str is inserted AFTER this 1-based line."),
            "view_range": .stringSchema(description: "Optional for `view`: \"start-end\" 1-based line range."),
        ],
        required: ["command", "path"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let command = args.objectValue?["command"]?.stringValue,
              let path = args.objectValue?["path"]?.stringValue else {
            return .failure("missing required parameters \"command\"/\"path\"", code: "INVALID_ARGS")
        }
        let workspace = ctx.workspace
        do {
            switch command {
            case "view":
                guard workspace.exists(path) else {
                    return .failure("file not found: \(path)", code: "FILE_NOT_FOUND")
                }
                let text = try workspace.readText(path)
                if let range = args.objectValue?["view_range"]?.stringValue {
                    let parts = range.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2, parts[0] >= 1, parts[1] >= parts[0] {
                        let lines = text.components(separatedBy: "\n")
                        let s = min(parts[0] - 1, lines.count)
                        let e = min(parts[1], lines.count)
                        let window = lines[s..<e].enumerated()
                            .map { "\($0.offset + parts[0])\t\($0.element)" }
                            .joined(separator: "\n")
                        return .success(window.isEmpty ? "(empty range)" : window)
                    }
                }
                let lines = text.components(separatedBy: "\n")
                return .success(lines.enumerated().prefix(FsReadTool.defaultLimit)
                    .map { "\($0.offset + 1)\t\($0.element.count > FsReadTool.maxLineLength ? $0.element.prefix(FsReadTool.maxLineLength) + "…[line truncated]" : $0.element)" }
                    .joined(separator: "\n"))

            case "create":
                guard let fileText = args.objectValue?["file_text"]?.stringValue else {
                    return .failure("`create` requires \"file_text\"", code: "INVALID_ARGS")
                }
                guard !workspace.exists(path) else {
                    return .failure("file already exists: \(path)", code: "ALREADY_EXISTS")
                }
                try workspace.writeText(path, content: fileText)
                return .success("File created: \(path) (\(fileText.utf8.count) bytes)")

            case "str_replace":
                guard let oldStr = args.objectValue?["old_str"]?.stringValue else {
                    return .failure("`str_replace` requires \"old_str\"", code: "INVALID_ARGS")
                }
                let newStr = args.objectValue?["new_str"]?.stringValue ?? ""
                guard !oldStr.isEmpty else {
                    return .failure("old_str must not be empty", code: "INVALID_ARGS")
                }
                _ = try workspace.mutate(path) { current in
                    let occurrences = current.components(separatedBy: oldStr).count - 1
                    if occurrences != 1 {
                        throw FsToolFailure(
                            "old_str appears \(occurrences) times; it must appear exactly once")
                    }
                    return current.replacingOccurrences(of: oldStr, with: newStr)
                }
                return .success("Replaced 1 occurrence in \(path)")

            case "insert":
                guard let insertLine = args.objectValue?["insert_line"]?.intValue,
                      let newStr = args.objectValue?["new_str"]?.stringValue else {
                    return .failure("`insert` requires \"insert_line\" and \"new_str\"", code: "INVALID_ARGS")
                }
                guard insertLine >= 0 else {
                    return .failure("insert_line must be >= 0", code: "INVALID_ARGS")
                }
                _ = try workspace.mutate(path) { current in
                    var lines = current.components(separatedBy: "\n")
                    let at = min(insertLine, lines.count)
                    lines.insert(newStr, at: at)
                    return lines.joined(separator: "\n")
                }
                return .success("Inserted after line \(insertLine) in \(path)")

            default:
                return .failure("unknown command \"\(command)\"; expected view/create/str_replace/insert",
                                code: "INVALID_ARGS")
            }
        } catch let failure as FsToolFailure {
            return .failure(failure.message, code: "EDIT_FAILED")
        } catch {
            return .failure(String(describing: error), code: "FS_ERROR")
        }
    }
}

// MARK: - 注册器

/// fs 工具族装配（M2.5：7 件；每会话一份 WorkspaceFileAccess 实例）。
enum FsTools {
    /// 按名称注册全部 7 件到 registry。
    static func registerAll(into registry: ToolRegistry, sessionId: String) {
        registry.register(FsReadTool())
        registry.register(FsWriteTool())
        registry.register(FsEditTool())
        registry.register(FsGlobTool())
        registry.register(FsGrepTool())
        registry.register(FsReadImageTool())
        registry.register(FsStrReplaceEditorTool())
        _ = sessionId // WorkspaceFileAccess 由执行上下文按调用注入（ToolExecutionContext.workspace）
    }
}
