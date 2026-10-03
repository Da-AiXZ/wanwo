//
//  MemoryBackend.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6
//  codex-rs/ext/memories/src/ 逐文件对拍）：
//    - local.rs —— resolve_scoped_path（:38-88 逐语义：ParentDir/RootDir/Prefix
//      拒绝、隐藏组件 NotFound、逐组件下探 + 中途 symlink 拒绝 + 非目录穿越拒绝、
//      末段缺席=预期新建路径放行）。
//    - local/list.rs —— list 全文（文件=单条自返；目录=排序条目、hidden/symlink
//      跳过；cursor 切片 + next_cursor + truncated）。
//    - local/read.rs —— read 全文（line_offset 1-indexed、max_lines 行窗、
//      max_tokens 截断——万我 token 估算=字节/4，MemoryRollout 头注同登记）。
//    - local/search.rs —— SearchMatcher（queries trim 非空校验；match_mode
//      Any/AllOnSameLine/AllWithinLines{line_count 窗口 + strictly_contains_
//      another_window 去除}；case_sensitive/normalized prepare=lowercase +
//      is_alphanumeric 过滤 1:1；matches 按 path→line 排序；build_search_match
//      context_lines 前后文窗）。
//    - local/ad_hoc_note.rs —— validate_filename（≤128 字节、.md 后缀、
//      YYYY-MM-DDTHH-MM-SS- 前缀逐字节校验、slug 1-80 字节小写字母数字连字符）、
//      create_new 语义（已存在 = AdHocNoteAlreadyExists）、notes 目录
//      extensions/ad_hoc/notes。
//    - local/path.rs —— read_sorted_dir_entries（字典序）/ is_hidden_path
//      （首分量 '.' 前缀）/ display_relative_path / reject_symlink。
//    - backend.rs —— 请求/响应结构与错误文案 1:1（RespondToModel 面 = 工具
//      输出错误文本；Io = Fatal 面）。
//  平台适配（登记）：
//    - 宿主侧直读 memoryPersistentDir（WorkspaceFileAccess 直读根先例——不经
//      iSH fork，§7.5 数据源纪律）；iSH bind mount 使 guest 面同源同真。
//    - symlink_metadata：iOS 无独立 symlink stat 面 → FileManager
//      attributesOfItem 不跟随（[.isSymbolicLinkKey]）逐组件复核等价。
//    - truncate_text Tokens：字节/4 估算（MemoryRollout 头注同登记）。
//

import Foundation

/// list_memories 响应单元（backend.rs MemoryEntry 1:1）。
struct MemoryBackendEntry: Equatable, Codable, Sendable {
    var path: String
    var entryType: String   // "file" | "directory"（snake_case wire 值）
}

/// search 命中单元（backend.rs MemorySearchMatch 1:1）。
struct MemoryBackendSearchMatch: Equatable, Codable, Sendable {
    var path: String
    var matchLineNumber: Int
    var contentStartLineNumber: Int
    var content: String
    var matchedQueries: [String]
}

/// search 匹配模式（backend.rs SearchMatchMode 1:1；wire tag "type" snake_case）。
enum MemorySearchMatchMode: Equatable, Codable, Sendable {
    case any
    case allOnSameLine
    case allWithinLines(lineCount: Int)

    private enum Kind: String, Codable {
        case any, allOnSameLine, allWithinLines
    }

    private enum Keys: String, CodingKey {
        case type, lineCount = "line_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .any: self = .any
        case .allOnSameLine: self = .allOnSameLine
        case .allWithinLines:
            self = .allWithinLines(lineCount:
                try container.decode(Int.self, forKey: .lineCount))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .any: try container.encode(Kind.any, forKey: .type)
        case .allOnSameLine: try container.encode(Kind.allOnSameLine, forKey: .type)
        case .allWithinLines(let count):
            try container.encode(Kind.allWithinLines, forKey: .type)
            try container.encode(count, forKey: .lineCount)
        }
    }
}

/// memories 本地后端（LocalMemoriesBackend 1:1；错误 = MemoryError 可回模型文案）。
struct MemoryBackend {
    let rootURL: URL

    private static let fm = FileManager.default

    // MARK: - 路径解析（resolve_scoped_path）

    /// 相对路径（nil = 根）→ 宿主 URL（逐组件下探 + 安全校验）。
    func resolveScopedPath(_ relativePath: String?) throws -> URL {
        guard let relativePath, !relativePath.isEmpty else { return rootURL }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        for component in components {
            if component == ".." {
                throw MemoryError(message:
                    "path '\(relativePath)' must stay within the memories root")
            }
            if component.hasPrefix(".") {
                throw MemoryError(message: "path '\(relativePath)' was not found")
            }
        }
        var scoped = rootURL
        for (idx, component) in components.enumerated() {
            scoped.appendPathComponent(component)
            guard Self.metadataExists(at: scoped) else {
                // 中途缺席：剩余组件拼接放行（预期新建路径——:68-73）。
                for remaining in components[(idx + 1)...] {
                    scoped.appendPathComponent(remaining)
                }
                return scoped
            }
            if Self.isSymlink(scoped) {
                throw MemoryError(message:
                    "path '\(Self.displayRelativePath(rootURL, scoped))' must not be a symlink")
            }
            if idx + 1 < components.count && Self.isDirectory(scoped) == false {
                throw MemoryError(message:
                    "path '\(relativePath)' traverses through a non-directory path component")
            }
        }
        return scoped
    }

    // MARK: - list（local/list.rs 1:1）

    func list(path: String?, cursor: Int, maxResults: Int) throws
        -> (entries: [MemoryBackendEntry], nextCursor: String?, truncated: Bool) {
        let start = try resolveScopedPath(path)
        guard Self.metadataExists(at: start) else {
            throw MemoryError(message: "path '\(path ?? "")' was not found")
        }
        var entries: [MemoryBackendEntry] = []
        if Self.isDirectory(start) == true {
            for (url, _) in try Self.readSortedDirEntries(start) {
                if url.lastPathComponent.hasPrefix(".") { continue }
                if Self.isSymlink(url) { continue }
                if Self.isDirectory(url) == true {
                    entries.append(MemoryBackendEntry(
                        path: Self.displayRelativePath(rootURL, url),
                        entryType: "directory"))
                } else {
                    entries.append(MemoryBackendEntry(
                        path: Self.displayRelativePath(rootURL, url),
                        entryType: "file"))
                }
            }
        } else {
            entries = [MemoryBackendEntry(
                path: Self.displayRelativePath(rootURL, start), entryType: "file")]
        }
        guard cursor <= entries.count else {
            throw MemoryError(message:
                "cursor '\(cursor)' exceeds result count")
        }
        let end = min(cursor + maxResults, entries.count)
        let nextCursor = end < entries.count ? String(end) : nil
        return (Array(entries[cursor..<end]), nextCursor, nextCursor != nil)
    }

    // MARK: - read（local/read.rs 1:1）

    func read(path: String, lineOffset: Int, maxLines: Int?, maxTokens: Int) throws
        -> (path: String, startLineNumber: Int, content: String, truncated: Bool) {
        if lineOffset == 0 {
            throw MemoryError(message: "line_offset must be a 1-indexed line number")
        }
        if maxLines == 0 {
            throw MemoryError(message: "max_lines must be a positive integer")
        }
        let url = try resolveScopedPath(path)
        guard Self.metadataExists(at: url) else {
            throw MemoryError(message: "path '\(path)' was not found")
        }
        if Self.isSymlink(url) {
            throw MemoryError(message: "path '\(path)' must not be a symlink")
        }
        guard Self.isDirectory(url) == false else {
            throw MemoryError(message: "path '\(path)' is not a file")
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw MemoryError(message: "I/O error while reading memories: \(path)")
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lineOffset <= lines.count else {
            throw MemoryError(message: "line_offset exceeds file length")
        }
        let slice = Array(lines[(lineOffset - 1)...].prefix(maxLines ?? lines.count))
        let fromOffset = slice.joined(separator: "\n")
        let effectiveTokens = maxTokens == 0 ? MemoryConstants.readMaxTokens : maxTokens
        let truncatedContent = MemoryRollout.truncateToTokenEstimate(
            fromOffset, effectiveTokens)
        let truncated = (lineOffset - 1 + slice.count) < lines.count
            || truncatedContent != fromOffset
        return (path, lineOffset, truncatedContent, truncated)
    }

    // MARK: - search（local/search.rs 1:1）

    func search(queries: [String], matchMode: MemorySearchMatchMode, path: String?,
                cursor: Int, contextLines: Int, caseSensitive: Bool, normalized: Bool,
                maxResults: Int) throws
        -> (matches: [MemoryBackendSearchMatch], nextCursor: String?, truncated: Bool) {
        let trimmed = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.isEmpty || trimmed.contains(where: { $0.isEmpty }) {
            throw MemoryError(message:
                "queries must not be empty or contain empty strings")
        }
        if case .allWithinLines(let lineCount) = matchMode, lineCount == 0 {
            throw MemoryError(message:
                "all_within_lines.line_count must be a positive integer")
        }
        let matcher = try SearchMatcher(queries: trimmed, matchMode: matchMode,
                                        caseSensitive: caseSensitive,
                                        normalized: normalized)
        let start = try resolveScopedPath(path)
        guard Self.metadataExists(at: start) else {
            throw MemoryError(message: "path '\(path ?? "")' was not found")
        }
        var matches: [MemoryBackendSearchMatch] = []
        try searchEntries(at: start, matcher: matcher, contextLines: contextLines,
                          into: &matches)
        // 排序（path → match_line_number）。
        matches.sort {
            $0.path != $1.path ? $0.path < $1.path
                : $0.matchLineNumber < $1.matchLineNumber
        }
        guard cursor <= matches.count else {
            throw MemoryError(message: "cursor '\(cursor)' exceeds result count")
        }
        let end = min(cursor + maxResults, matches.count)
        let nextCursor = end < matches.count ? String(end) : nil
        return (Array(matches[cursor..<end]), nextCursor, nextCursor != nil)
    }

    /// search_entries 1:1：文件直查；目录栈遍历（hidden/symlink 跳过）。
    private func searchEntries(at url: URL, matcher: SearchMatcher,
                               contextLines: Int,
                               into matches: inout [MemoryBackendSearchMatch]) throws {
        if Self.isDirectory(url) == true {
            var pending = [url]
            while let dir = pending.popLast() {
                for (entry, _) in try Self.readSortedDirEntries(dir) {
                    if entry.lastPathComponent.hasPrefix(".") { continue }
                    if Self.isSymlink(entry) { continue }
                    if Self.isDirectory(entry) == true {
                        pending.append(entry)
                    } else {
                        try searchFile(entry, matcher: matcher,
                                       contextLines: contextLines, into: &matches)
                    }
                }
            }
        } else {
            try searchFile(url, matcher: matcher, contextLines: contextLines,
                           into: &matches)
        }
    }

    /// search_file 三模式 1:1（:130-228）。
    private func searchFile(_ url: URL, matcher: SearchMatcher, contextLines: Int,
                            into matches: inout [MemoryBackendSearchMatch]) throws {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return // InvalidData → Ok(())（非 UTF-8 文件跳过）
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let lineMatches = lines.map { matcher.matchedQueryFlags($0) }
        let relPath = Self.displayRelativePath(rootURL, url)
        switch matcher.matchMode {
        case .any:
            for (idx, flags) in lineMatches.enumerated() where flags.contains(true) {
                matches.append(buildMatch(relPath, lines: lines, start: idx, end: idx,
                                          contextLines: contextLines,
                                          matched: matcher.matchedQueries(flags)))
            }
        case .allOnSameLine:
            for (idx, flags) in lineMatches.enumerated()
            where flags.allSatisfy({ $0 }) {
                matches.append(buildMatch(relPath, lines: lines, start: idx, end: idx,
                                          contextLines: contextLines,
                                          matched: matcher.matchedQueries(flags)))
            }
        case .allWithinLines(let lineCount):
            var windows: [(start: Int, end: Int, flags: [Bool])] = []
            for startIndex in 0..<lines.count {
                if !lineMatches[startIndex].contains(true) { continue }
                let lastAllowed = min(startIndex + max(lineCount - 1, 0),
                                      lines.count - 1)
                var flags = [Bool](repeating: false, count: matcher.queries.count)
                for endIndex in startIndex...lastAllowed {
                    for (idx, matched) in lineMatches[endIndex].enumerated()
                    where matched { flags[idx] = true }
                    if flags.allSatisfy({ $0 }) {
                        windows.append((startIndex, endIndex, flags))
                        break
                    }
                }
            }
            for (idx, window) in windows.enumerated() {
                // strictly_contains_another_window 去除（:203-214 逐语义）。
                let strictlyContains = windows.enumerated().contains { other in
                    other.offset != idx
                        && window.start <= other.element.start
                        && window.end >= other.element.end
                        && (window.start != other.element.start
                            || window.end != other.element.end)
                }
                if strictlyContains { continue }
                matches.append(buildMatch(relPath, lines: lines, start: window.start,
                                          end: window.end,
                                          contextLines: contextLines,
                                          matched: matcher.matchedQueries(window.flags)))
            }
        }
    }

    /// build_search_match 1:1（:230-251）。
    private func buildMatch(_ path: String, lines: [String], start: Int, end: Int,
                            contextLines: Int,
                            matched: [String]) -> MemoryBackendSearchMatch {
        let contentStart = max(start - contextLines, 0)
        let contentEnd = min(end + contextLines + 1, lines.count)
        return MemoryBackendSearchMatch(
            path: path,
            matchLineNumber: start + 1,
            contentStartLineNumber: contentStart + 1,
            content: lines[contentStart..<contentEnd].joined(separator: "\n"),
            matchedQueries: matched)
    }

    // MARK: - add_ad_hoc_note（local/ad_hoc_note.rs 1:1）

    func addAdHocNote(filename: String, note: String) throws {
        try Self.validateAdHocFilename(filename)
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MemoryError(message: "ad-hoc note must not be empty")
        }
        var notesDir = rootURL
        for component in ["extensions", "ad_hoc", "notes"] {
            notesDir.appendPathComponent(component)
            if Self.metadataExists(at: notesDir) {
                if Self.isSymlink(notesDir) {
                    throw MemoryError(message:
                        "path '\(notesDir.lastPathComponent)' must not be a symlink")
                }
                if Self.isDirectory(notesDir) == false {
                    throw MemoryError(message:
                        "path '\(notesDir.path)' must be a directory")
                }
            } else {
                try Self.fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
            }
        }
        // fakefs 元数据注册（拍板 2026-10-04——宿主直写须注册才对 bash 可见，
        // MemoryStorage.registerFakefsIfInTree 同语义；legacy 桶树外自然跳过）。
        if let guestNotesDir = MemoryProjectLayout.fakefsGuestPathIfInTree(notesDir) {
            IshExecutorBridge.ensureParentDirsInMetaDB(for: guestNotesDir)
            IshExecutorBridge.ensureFakefsMetadata(for: guestNotesDir, isDirectory: true)
        }
        let target = notesDir.appendingPathComponent(filename)
        if Self.fm.fileExists(atPath: target.path) {
            throw MemoryError(message: "ad-hoc note '\(filename)' already exists")
        }
        guard let data = note.data(using: .utf8) else {
            throw MemoryError(message: "ad-hoc note utf8 encode failed")
        }
        try data.write(to: target, options: .atomic)
        if let guestTarget = MemoryProjectLayout.fakefsGuestPathIfInTree(target) {
            IshExecutorBridge.ensureFakefsMetadata(for: guestTarget, isDirectory: false)
        }
    }

    /// validate_filename 1:1（:84-126）。
    static func validateAdHocFilename(_ filename: String) throws {
        if filename.utf8.count > 128 {
            throw MemoryError(message: "filename '\(filename)' must be at most 128 bytes")
        }
        guard filename.hasSuffix(".md") else {
            throw MemoryError(message:
                "filename '\(filename)' must end with .md")
        }
        let stem = String(filename.dropLast(3))
        let prefixLen = "YYYY-MM-DDTHH-MM-SS-".count
        guard stem.count > prefixLen else {
            throw MemoryError(message:
                "filename '\(filename)' must use YYYY-MM-DDTHH-MM-SS-<slug>.md")
        }
        let bytes = Array(stem.utf8)
        let validPrefix = bytes.count > prefixLen
            && bytes[4] == UInt8(ascii: "-") && bytes[7] == UInt8(ascii: "-")
            && bytes[10] == UInt8(ascii: "T") && bytes[13] == UInt8(ascii: "-")
            && bytes[16] == UInt8(ascii: "-") && bytes[19] == UInt8(ascii: "-")
            && (0..<4).allSatisfy { bytes[$0].isAsciiDigit }
            && (5..<7).allSatisfy { bytes[$0].isAsciiDigit }
            && (8..<10).allSatisfy { bytes[$0].isAsciiDigit }
            && (11..<13).allSatisfy { bytes[$0].isAsciiDigit }
            && (14..<16).allSatisfy { bytes[$0].isAsciiDigit }
            && (17..<19).allSatisfy { bytes[$0].isAsciiDigit }
        guard validPrefix else {
            throw MemoryError(message:
                "filename '\(filename)' must use YYYY-MM-DDTHH-MM-SS-<slug>.md")
        }
        let slug = String(stem.dropFirst(prefixLen))
        if slug.isEmpty || slug.utf8.count > 80 {
            throw MemoryError(message:
                "filename '\(filename)' slug must be 1 to 80 bytes")
        }
        let slugValid = slug.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
        guard slugValid else {
            throw MemoryError(message:
                "filename '\(filename)' slug must contain only lowercase ASCII letters, digits, or hyphens")
        }
    }

    // MARK: - 元数据辅助（local.rs metadata_or_none 等价）

    private static func metadataExists(at url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    private static func isDirectory(_ url: URL) -> Bool? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue
    }

    /// 不跟随 symlink 判定（attributesOfItem 返回 symlink 自身元数据）。
    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// read_sorted_dir_entries 1:1（字典序；缺目录 = 空表）。
    static func readSortedDirEntries(_ dir: URL) throws -> [(URL, Bool)] {
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }
        return items
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, isDirectory($0) == true) }
    }

    /// display_relative_path 1:1。
    static func displayRelativePath(_ root: URL, _ path: URL) -> String {
        guard path.path.hasPrefix(root.path), path.path != root.path else {
            return path.lastPathComponent == root.lastPathComponent ? "" : path.lastPathComponent
        }
        var rel = String(path.path.dropFirst(root.path.count + 1))
        if rel.isEmpty { rel = path.lastPathComponent }
        return rel
    }
}

private extension UInt8 {
    var isAsciiDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
}

// MARK: - SearchMatcher（local/search.rs :253-336 1:1）

/// 三模式匹配器（prepare = lowercase + alphanumeric 过滤；逐 query 布尔旗标）。
struct SearchMatcher {
    let queries: [String]
    let preparedQueries: [String]
    let caseSensitive: Bool
    let normalized: Bool
    let matchMode: MemorySearchMatchMode

    init(queries: [String], matchMode: MemorySearchMatchMode,
         caseSensitive: Bool, normalized: Bool) throws {
        self.queries = queries
        self.caseSensitive = caseSensitive
        self.normalized = normalized
        self.matchMode = matchMode
        self.preparedQueries = queries.map {
            Self.prepare($0, caseSensitive: caseSensitive, normalized: normalized)
        }
        if preparedQueries.contains(where: { $0.isEmpty }) {
            throw MemoryError(message:
                "queries must not be empty or contain empty strings")
        }
    }

    /// SearchComparison.prepare 1:1（:315-336）。
    static func prepare(_ value: String, caseSensitive: Bool, normalized: Bool) -> String {
        var out = caseSensitive ? value : value.lowercased()
        if normalized {
            out = out.filter { $0.isLetter || $0.isNumber }
        }
        return out
    }

    /// matched_query_flags 1:1。
    func matchedQueryFlags(_ line: String) -> [Bool] {
        let prepared = Self.prepare(line, caseSensitive: caseSensitive,
                                    normalized: normalized)
        return preparedQueries.map { prepared.contains($0) }
    }

    /// matched_queries 1:1（命中 query 原文保序）。
    func matchedQueries(_ flags: [Bool]) -> [String] {
        zip(queries, flags).compactMap { $0.1 ? $0.0 : nil }
    }
}
