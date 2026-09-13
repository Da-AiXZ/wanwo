//
//  SkillParser.swift
//  WanWo
//
//  【M4-D 件 D1 · F034 SKILL.md 格式层】语义移植 · codex 原件：
//  repos/codex-rust-v0.153.0-alpha.6/codex-rs/skills/src/parser.rs（225 行，逐锚点端口）。
//  职责：SKILL.md frontmatter 提取 + 元数据解析{name≤64/description 必填/
//  metadata.short-description?}+ 标量行修复器（第三方技能"非法但可读"YAML 的
//  工程化妥协）+ 长度校验。纯函数、零宿主依赖、线程安全。
//
//  锚点对拍（parser.rs 行号 → 本文件符号）：
//    :4      MAX_NAME_LEN=64                     → maxNameLen
//    :6-20   serde 结构（全 Option/未知字段忽略） → SubsetFields + 子集解析器
//    :24-28  ParsedSkillFrontmatter              → 同名 struct
//    :31-41  SkillParseError 四 case 文案逐字     → SkillParseError
//    :44-92  主流程顺序 1:1                       → parseSkillFrontmatterMetadata
//    :94-96  sanitize_single_line                → sanitizeSingleLine
//    :98-181 repair_frontmatter_scalar_fields    → repairFrontmatterScalarFields
//    :183-198 validate_len（字素/标量差异登记）    → validateLen
//    :200-221 extract_frontmatter                → extractFrontmatter
//
//  平台自实现面（本件唯一）：YAML 解析。codex 用 serde_yaml crate；Swift 无对应
//  物 → 自写 frontmatter 子集解析器（parseSubsetYaml）。修复器先行（纯文本行处理
//  无 YAML 依赖），修复后行集只剩三类：安全标量 / 已引号 / 块标量。子集只处理：
//  顶层 key:value 标量 + 一层嵌套（metadata.short-description）+ 单/双引号剥离 +
//  块标量多行体收集；未知字段静默忽略（serde 默认行为等价）。
//  覆盖论证与差异登记见 D1 呈报。
//

import Foundation

/// Validated metadata parsed from a `SKILL.md` frontmatter block.
/// （parser.rs:22-28，1:1；`short_description` → Swift 命名 `shortDescription`）
struct ParsedSkillFrontmatter: Equatable {
    let name: String
    let description: String
    let shortDescription: String?
}

/// Error produced while parsing or validating `SKILL.md` metadata.
/// （parser.rs:31-41；四 case 文案逐字，CustomStringConvertible 承载 `to_string()` 位）
enum SkillParseError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter
    /// InvalidYaml 携带"原始错误"描述字符串——codex 语义：修复版再解析仍失败时
    /// 抛原始错误，不抛修复后错误（parser.rs:52-61）。载体位对拍 serde_yaml::Error。
    case invalidYaml(String)
    case missingField(String)
    case invalidField(field: String, reason: String)

    var description: String {
        switch self {
        case .missingFrontmatter:
            return "missing YAML frontmatter delimited by ---"
        case .invalidYaml(let original):
            return "invalid YAML: \(original)"
        case .missingField(let field):
            return "missing field `\(field)`"
        case .invalidField(let field, let reason):
            return "invalid \(field): \(reason)"
        }
    }
}

/// SKILL.md frontmatter 格式层（parser.rs 纯函数命名空间）。
enum SkillParser {

    /// parser.rs:4
    private static let maxNameLen = 64

    /// 子集解析器内部错误——仅作为 InvalidYaml 的"原始错误描述"载体，不直接外抛。
    private struct SubsetYamlError: Error {
        let message: String
    }

    /// serde `SkillFrontmatter`/`SkillFrontmatterMetadata`（parser.rs:6-20）的等价物：
    /// 全字段 Option、未知字段静默忽略（serde default 行为）。
    private struct SubsetFields {
        var name: String?
        var description: String?
        var shortDescription: String?
    }

    // MARK: - 主流程（parser.rs:44-92，顺序 1:1）

    /// Parses and validates the metadata frontmatter from `SKILL.md` contents.
    static func parseSkillFrontmatterMetadata(
        _ contents: String,
        defaultName: () -> String
    ) throws -> ParsedSkillFrontmatter {
        guard let frontmatter = extractFrontmatter(contents) else {
            throw SkillParseError.missingFrontmatter
        }

        let parsed: SubsetFields
        do {
            parsed = try parseSubsetYaml(frontmatter)
        } catch let error as SubsetYamlError {
            // 解析失败 → 行级修复 → 修复版再解析；仍失败 = 抛原始错误（parser.rs:50-62）。
            // 修复保持行级（line-oriented），使无关的非法 YAML 仍能浮出（原文 :53-55 注释语义）。
            let originalMessage = error.message
            if let repaired = repairFrontmatterScalarFields(frontmatter) {
                do {
                    parsed = try parseSubsetYaml(repaired)
                } catch {
                    throw SkillParseError.invalidYaml(originalMessage)
                }
            } else {
                throw SkillParseError.invalidYaml(originalMessage)
            }
        }

        // name：sanitize_single_line → 空 filter → default_name 闭包回退（parser.rs:64-69）
        var name = parsed.name.map(sanitizeSingleLine) ?? ""
        if name.isEmpty { name = defaultName() }
        // description：sanitize_single_line → unwrap_or_default（parser.rs:70-74）
        let description = parsed.description.map(sanitizeSingleLine) ?? ""
        // short_description：sanitize → 空 filter 为 None（parser.rs:75-80）
        // （Optional.map 后无 filter 方法——flatMap 承载空滤，等价 Rust
        // `.filter(|v| !v.is_empty())` 的 Option 语义）
        let shortDescription = parsed.shortDescription
            .map(sanitizeSingleLine)
            .flatMap { $0.isEmpty ? nil : $0 }

        try validateLen(name, maxLen: maxNameLen, fieldName: "name")
        // 空即 MissingField("description")（parser.rs:83-85）
        if description.isEmpty {
            throw SkillParseError.missingField("description")
        }

        return ParsedSkillFrontmatter(
            name: name,
            description: description,
            shortDescription: shortDescription
        )
    }

    // MARK: - 逐字辅助（parser.rs:94-96 / :183-198 / :200-221）

    /// 任意空白序列折叠为单空格（parser.rs:94-96：
    /// `raw.split_whitespace().collect::<Vec<_>>().join(" ")`）。
    static func sanitizeSingleLine(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 空 → MissingField；字符数超限 → InvalidField reason 逐字（parser.rs:183-198）。
    /// 平台差异登记：Rust `chars().count()` 计 Unicode 标量；Swift `String.count` 计
    /// 字素簇——仅对组合字素（emoji+变体选择器等）计数有差，≤64 边界判定语义一致。
    private static func validateLen(
        _ value: String,
        maxLen: Int,
        fieldName: String
    ) throws {
        if value.isEmpty {
            throw SkillParseError.missingField(fieldName)
        }
        if value.count > maxLen {
            throw SkillParseError.invalidField(
                field: fieldName,
                reason: "exceeds maximum length of \(maxLen) characters"
            )
        }
    }

    /// 首行 trim 后 == "---" → 收集至闭合 "---" 前的行；frontmatter 空或无闭合 = None
    /// （parser.rs:200-221）。
    static func extractFrontmatter(_ contents: String) -> String? {
        let lines = rustLines(contents)
        guard let first = lines.first, trim(first) == "---" else { return nil }

        var frontmatterLines: [String] = []
        var foundClosing = false
        for line in lines.dropFirst() {
            if trim(line) == "---" {
                foundClosing = true
                break
            }
            frontmatterLines.append(line)
        }

        if frontmatterLines.isEmpty || !foundClosing { return nil }
        return frontmatterLines.joined(separator: "\n")
    }

    // MARK: - 行级修复器（parser.rs:98-181，语义序 1:1）

    /// 逐行修复"非法但可读"的 YAML 标量行：未引号冒号/prose 行/非法 flow 形
    /// 补单引号包裹（内部 `'` → `''` 转义）。changed 才返回 Some，无任何改动
    /// 返回 None → 主流程不重试（parser.rs:180）。
    static func repairFrontmatterScalarFields(_ frontmatter: String) -> String? {
        var changed = false
        var blockScalarIndent: Int? = nil
        var repairedLines: [String] = []

        for line in rustLines(frontmatter) {
            let indent = leadingSpaceCount(line)

            // block scalar 跟踪：其后缩进更深（或空行）的行原样保留直至缩进回落（:107-113）
            if let blockIndent = blockScalarIndent {
                if trim(line).isEmpty || indent > blockIndent {
                    repairedLines.append(line)
                    continue
                }
                blockScalarIndent = nil
            }

            // 行内无 ':' → 原样保留（:115-118）
            guard let colonIdx = line.firstIndex(of: ":") else {
                repairedLines.append(line)
                continue
            }
            let key = String(line[..<colonIdx])
            let value = String(line[line.index(after: colonIdx)...])

            // key trim 后空 / value 首字符存在且非空白（key:value 紧贴形）→ 原样保留（:119-122）
            let valueStartsNonWhitespace: Bool
            if let first = value.first {
                valueStartsNonWhitespace = !first.isWhitespace
            } else {
                valueStartsNonWhitespace = false
            }
            if trim(key).isEmpty || valueStartsNonWhitespace {
                repairedLines.append(line)
                continue
            }

            // 注剥离：value 中首个"前面是空白或居首"的 '#' 之后内容记为 comment（:124-141）
            let trimmedStart = trimStart(value)
            let leadingWhitespace = String(value.prefix(value.count - trimmedStart.count))
            var scalar = trimmedStart
            var comment = ""
            scanComment: for (index, character) in trimmedStart.enumerated() {
                if character == "#" {
                    let atStart = index == 0
                    let previousIsWhitespace = index > 0
                        && trimmedStart[trimmedStart.index(trimmedStart.startIndex, offsetBy: index - 1)]
                            .isWhitespace
                    if atStart || previousIsWhitespace {
                        let beforeHash = String(trimmedStart.prefix(index))
                        let scalarEnd = trimEnd(beforeHash)
                        scalar = scalarEnd
                        comment = String(trimmedStart.dropFirst(scalarEnd.count))
                        break scanComment
                    }
                }
            }

            // scalar trim_end 后为空 → 原样保留（:143-147）
            let trimmedScalar = trimEnd(scalar)
            guard let firstChar = trimmedScalar.first else {
                repairedLines.append(line)
                continue
            }

            // 首字符 '|'/'>' → 进入 block 模式原样；'\''/'"' → 已引号原样（:148-156）
            if firstChar == "|" || firstChar == ">" {
                blockScalarIndent = indent
                repairedLines.append(line)
                continue
            }
            if firstChar == "'" || firstChar == "\"" {
                repairedLines.append(line)
                continue
            }

            // has_colon_separator：scalar 内存在"':' 后紧跟空白"→ 非法（YAML 会解析成 map）（:157-166）
            let hasColonSeparator = containsColonSeparator(trimmedScalar)
            // invalid_flow_like_scalar：首字符 '['/'{'/'@'/'`' 且整体 YAML 解析失败 → 非法（:167-168）
            let invalidFlowLikeScalar =
                (firstChar == "[" || firstChar == "{" || firstChar == "@" || firstChar == "`")
                && !yamlScalarParses(trimmedScalar)
            if !hasColonSeparator && !invalidFlowLikeScalar {
                repairedLines.append(line)
                continue
            }

            // 修复 = scalar 单引号包裹（内部 '\'' → "''" 转义）+ 重拼
            // `key:{原前导空白}{quoted}{comment}`（:174-178）
            let quotedScalar = "'" + trimmedScalar.replacingOccurrences(of: "'", with: "''") + "'"
            repairedLines.append("\(key):\(leadingWhitespace)\(quotedScalar)\(comment)")
            changed = true
        }

        return changed ? repairedLines.joined(separator: "\n") : nil
    }

    // MARK: - 平台自实现面：frontmatter 子集 YAML 解析
    //
    // codex 用 serde_yaml（parser.rs:50）；Swift 无对应物 → 自写子集解析器。
    // 前提：修复器先行后，行集只剩安全标量 / 已引号 / 块标量三类。覆盖范围：
    //   1. 顶层 `key: value` 标量（name/description 取值；其余键静默忽略）
    //   2. 一层嵌套：`metadata:` 下缩进的 `short-description: value`
    //   3. 单引号（'' 转义）/ 双引号（常用转义）值剥离
    //   4. 块标量（|/>）多行体收集（clip/strip/keep chomping + 显式缩进数字）
    // null 值（`key:` 空 / `key: # 注`）→ nil（serde Option null 等价）；未知字段
    // 的值仍须是可解析 YAML，否则整文档非法（对拍 serde 整文档解析行为）。

    private static func parseSubsetYaml(_ frontmatter: String) throws -> SubsetFields {
        var fields = SubsetFields()
        let lines = rustLines(frontmatter)
        var i = 0

        while i < lines.count {
            let line = lines[i]
            if trim(line).isEmpty { i += 1; continue }

            let indent = leadingSpaceCount(line)
            guard indent == 0 else {
                throw SubsetYamlError(message: "unexpected indentation at line \(i + 1)")
            }
            guard let colonIdx = line.firstIndex(of: ":") else {
                throw SubsetYamlError(message: "could not find expected ':' at line \(i + 1)")
            }
            let key = trim(String(line[..<colonIdx]))
            guard !key.isEmpty else {
                throw SubsetYamlError(message: "empty key at line \(i + 1)")
            }
            let rawValue = trimStart(String(line[line.index(after: colonIdx)...]))

            switch key {
            case "name", "description":
                let parsed = try parseScalarValue(
                    rawValue, lines: lines, keyLineIndex: i, keyIndent: indent,
                    allowCollection: false, fieldName: key
                )
                if key == "name" {
                    fields.name = parsed.value
                } else {
                    fields.description = parsed.value
                }
                i = parsed.nextIndex
            case "metadata":
                if trimEnd(rawValue).isEmpty {
                    // null / 空值 → 默认空结构（serde `#[serde(default)]` 等价）
                    i = try consumeMetadataSection(
                        lines: lines, startIndex: i + 1, sectionIndent: indent, into: &fields)
                } else {
                    throw SubsetYamlError(
                        message: "invalid type: `metadata` must be a mapping at line \(i + 1)")
                }
            default:
                // 未知字段静默忽略（serde 默认行为）；空值/块标量 → 整块嵌套体跳过
                if trimEnd(rawValue).isEmpty || rawValue.first == "|" || rawValue.first == ">" {
                    i = skipNestedBody(lines: lines, startIndex: i + 1, parentIndent: indent)
                } else {
                    try validateScalarValue(rawValue, allowCollection: true, line: i + 1)
                    i += 1
                }
            }
        }
        return fields
    }

    /// 已知字段取值：null/块标量/单引号/双引号/flow/plain 分派。
    private static func parseScalarValue(
        _ value: String,
        lines: [String],
        keyLineIndex: Int,
        keyIndent: Int,
        allowCollection: Bool,
        fieldName: String
    ) throws -> (value: String?, nextIndex: Int) {
        // 空值 / 纯注释 → null → nil（serde Option 等价）
        if trimEnd(value).isEmpty || value.first == "#" {
            return (nil, keyLineIndex + 1)
        }
        let first = value.first!
        // 块标量：多行体收集
        if first == "|" || first == ">" {
            let (body, next) = blockScalarBody(
                lines: lines, keyLineIndex: keyLineIndex, keyIndent: keyIndent, indicator: value)
            return (body, next)
        }
        // 单引号：'' 转义剥离
        if first == "'" {
            return (try parseSingleQuoted(value, line: keyLineIndex + 1), keyLineIndex + 1)
        }
        // 双引号：常用转义剥离
        if first == "\"" {
            return (try parseDoubleQuoted(value, line: keyLineIndex + 1), keyLineIndex + 1)
        }
        // flow 集合：已知字段为 String 类型 → 类型不匹配（serde invalid type 等价）
        if first == "[" || first == "{" {
            throw SubsetYamlError(
                message: "invalid type: `\(fieldName)` must be a string at line \(keyLineIndex + 1)")
        }
        // plain 标量：校验 + 剥 ` #` 尾注
        try validateScalarValue(value, allowCollection: allowCollection, line: keyLineIndex + 1)
        return (plainScalarValue(value), keyLineIndex + 1)
    }

    /// 值合法性校验（不取值）：引号值须闭合；plain/flow 值按 YAML 子集规则校验。
    private static func validateScalarValue(
        _ value: String,
        allowCollection: Bool,
        line: Int
    ) throws {
        guard let first = value.first else { return }
        if first == "'" {
            _ = try parseSingleQuoted(value, line: line)
            return
        }
        if first == "\"" {
            _ = try parseDoubleQuoted(value, line: line)
            return
        }
        if first == "[" || first == "{" {
            guard yamlScalarParses(value) else {
                throw SubsetYamlError(message: "invalid flow collection at line \(line)")
            }
            guard allowCollection else {
                throw SubsetYamlError(message: "invalid type: expected string at line \(line)")
            }
            return
        }
        // plain 标量：": " 或行尾 ':' 会生成 mapping → 非法（serde "mapping values are
        // not allowed in this context" 等价——这是修复器的触发面）
        if containsColonSeparator(value) || trimEnd(value).hasSuffix(":") {
            throw SubsetYamlError(
                message: "mapping values are not allowed in this context at line \(line)")
        }
        if first == "@" || first == "`" {
            throw SubsetYamlError(
                message: "reserved character cannot start a plain scalar at line \(line)")
        }
        if (first == "-" || first == "?" || first == ":")
            && value.count > 1 && value[value.index(after: value.startIndex)].isWhitespace {
            throw SubsetYamlError(
                message: "block collection entries are not allowed in this context at line \(line)")
        }
    }

    /// 单引号标量：'' → ' 转义；闭合引号后仅允许空白或注释；跨行不支持（子集限制）。
    private static func parseSingleQuoted(_ value: String, line: Int) throws -> String {
        var result = ""
        var idx = value.index(after: value.startIndex)
        while idx < value.endIndex {
            let character = value[idx]
            if character == "'" {
                let next = value.index(after: idx)
                if next < value.endIndex && value[next] == "'" {
                    result.append("'")
                    idx = value.index(after: next)
                    continue
                }
                let rest = trimStart(String(value[next...]))
                if !rest.isEmpty && !rest.hasPrefix("#") {
                    throw SubsetYamlError(
                        message: "unexpected content after quoted scalar at line \(line)")
                }
                return result
            }
            result.append(character)
            idx = value.index(after: idx)
        }
        throw SubsetYamlError(
            message: "unterminated single-quoted scalar at line \(line)")
    }

    /// 双引号标量：常用转义剥离；未知转义/跨行不支持（子集限制）。
    private static func parseDoubleQuoted(_ value: String, line: Int) throws -> String {
        var result = ""
        var idx = value.index(after: value.startIndex)
        while idx < value.endIndex {
            let character = value[idx]
            if character == "\"" {
                let rest = trimStart(String(value[value.index(after: idx)...]))
                if !rest.isEmpty && !rest.hasPrefix("#") {
                    throw SubsetYamlError(
                        message: "unexpected content after quoted scalar at line \(line)")
                }
                return result
            }
            if character == "\\" {
                let next = value.index(after: idx)
                guard next < value.endIndex else {
                    throw SubsetYamlError(
                        message: "unterminated double-quoted scalar at line \(line)")
                }
                switch value[next] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.append("\u{0008}")
                case "f": result.append("\u{000C}")
                case "0": result.append("\u{0000}")
                default:
                    throw SubsetYamlError(message: "invalid escape character at line \(line)")
                }
                idx = value.index(after: next)
                continue
            }
            result.append(character)
            idx = value.index(after: idx)
        }
        throw SubsetYamlError(
            message: "unterminated double-quoted scalar at line \(line)")
    }

    /// plain 标量取值：剥 ` #` 尾注（'#' 前须有空白）+ trimEnd。
    private static func plainScalarValue(_ value: String) -> String {
        let characters = Array(value)
        var end = characters.count
        if characters.count > 1 {
            for index in 1..<characters.count
            where characters[index] == "#" && characters[index - 1].isWhitespace {
                end = index
                break
            }
        }
        return trimEnd(String(characters[0..<end]))
    }

    /// YAML 标量可解析性探针（对拍 parser.rs:168 的
    /// `serde_yaml::from_str::<serde_yaml::Value>(scalar)` 探测）：flow 集合须配平
    /// 且不含保留字符（@/`）；'@'/'`' 起始恒失败；其余按 plain 标量可解析。
    private static func yamlScalarParses(_ scalar: String) -> Bool {
        guard let first = scalar.first else { return true }
        if first == "@" || first == "`" { return false }
        if first == "[" || first == "{" {
            var depth = 0
            for character in scalar {
                switch character {
                case "[", "{":
                    depth += 1
                case "]", "}":
                    depth -= 1
                    if depth < 0 { return false }
                case "@", "`":
                    return false
                default:
                    break
                }
            }
            return depth == 0
        }
        return true
    }

    /// `metadata:` 空值节的嵌套消费：一层缩进内的键值；short-description 取值，
    /// 其余键（含更深层嵌套/块标量体）整块跳过。
    private static func consumeMetadataSection(
        lines: [String],
        startIndex: Int,
        sectionIndent: Int,
        into fields: inout SubsetFields
    ) throws -> Int {
        var i = startIndex
        while i < lines.count {
            let line = lines[i]
            if trim(line).isEmpty { i += 1; continue }
            let indent = leadingSpaceCount(line)
            if indent <= sectionIndent { break }  // 缩进回落 → 节结束
            guard let colonIdx = line.firstIndex(of: ":") else {
                throw SubsetYamlError(message: "could not find expected ':' at line \(i + 1)")
            }
            let innerKey = trim(String(line[..<colonIdx]))
            guard !innerKey.isEmpty else {
                throw SubsetYamlError(message: "empty key at line \(i + 1)")
            }
            let innerValue = trimStart(String(line[line.index(after: colonIdx)...]))

            if innerKey == "short-description" {
                let parsed = try parseScalarValue(
                    innerValue, lines: lines, keyLineIndex: i, keyIndent: indent,
                    allowCollection: false, fieldName: "short-description"
                )
                fields.shortDescription = parsed.value
                i = parsed.nextIndex
            } else if trimEnd(innerValue).isEmpty || innerValue.first == "|"
                || innerValue.first == ">" {
                i = skipNestedBody(lines: lines, startIndex: i + 1, parentIndent: indent)
            } else {
                try validateScalarValue(innerValue, allowCollection: true, line: i + 1)
                i += 1
            }
        }
        return i
    }

    /// 跳过 parentIndent 更深的全部行（含空行），止于缩进回落。
    private static func skipNestedBody(
        lines: [String],
        startIndex: Int,
        parentIndent: Int
    ) -> Int {
        var i = startIndex
        while i < lines.count {
            let line = lines[i]
            if trim(line).isEmpty { i += 1; continue }
            if leadingSpaceCount(line) > parentIndent { i += 1; continue }
            break
        }
        return i
    }

    /// 块标量多行体收集：`|`/`>` + 可选 chomping（-/+)/显式缩进数字。
    /// 体缩进 = 首个非空行缩进（或 keyIndent+显式数字）；逐行去缩进，"\n" 连接。
    /// 平台简化登记：chomping clip(默认)/keep(+) 的行尾换行差异在 sanitize
    /// （split_whitespace 折叠）下无观测面——三个消费字段均过 sanitize。
    private static func blockScalarBody(
        lines: [String],
        keyLineIndex: Int,
        keyIndent: Int,
        indicator: String
    ) -> (value: String, nextIndex: Int) {
        var chomp = 0  // 0=clip, -1=strip, +1=keep
        var explicitIndent: Int? = nil
        var idx = indicator.index(after: indicator.startIndex)
        while idx < indicator.endIndex {
            let character = indicator[idx]
            if character == "-" {
                chomp = -1
            } else if character == "+" {
                chomp = 1
            } else if let digit = character.wholeNumberValue, digit >= 1, digit <= 9 {
                explicitIndent = digit
            } else {
                break
            }
            idx = indicator.index(after: idx)
        }

        var bodyLines: [String] = []
        var detectedIndent: Int? = nil
        var i = keyLineIndex + 1
        while i < lines.count {
            let line = lines[i]
            if trim(line).isEmpty {
                bodyLines.append("")
                i += 1
                continue
            }
            let indent = leadingSpaceCount(line)
            if indent <= keyIndent { break }
            let effectiveBodyIndent: Int
            if let explicit = explicitIndent {
                effectiveBodyIndent = keyIndent + explicit
            } else {
                if detectedIndent == nil { detectedIndent = indent }
                effectiveBodyIndent = detectedIndent!
            }
            if indent >= effectiveBodyIndent,
               line.prefix(effectiveBodyIndent).allSatisfy({ $0 == " " }) {
                bodyLines.append(String(line.dropFirst(effectiveBodyIndent)))
            } else {
                bodyLines.append(trimStart(line))
            }
            i += 1
        }

        var contentLines = bodyLines
        while let last = contentLines.last, last.isEmpty { contentLines.removeLast() }
        var body = contentLines.joined(separator: "\n")
        switch chomp {
        case -1:
            break  // strip：无行尾换行
        case 1:
            if !bodyLines.isEmpty { body += "\n" }  // keep
        default:
            if !contentLines.isEmpty { body += "\n" }  // clip
        }
        return (body, i)
    }

    // MARK: - 文本基元（Rust 语义对齐）

    /// Rust `str::lines()` 语义：\n 分割、剥行尾 \r、末尾换行不产生空行、空串 → []。
    private static func rustLines(_ string: String) -> [String] {
        var lines = string.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static func trim(_ string: String) -> String {
        trimEnd(trimStart(string))
    }

    private static func trimStart(_ string: String) -> String {
        guard let firstNonWhitespace = string.firstIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(string[firstNonWhitespace...])
    }

    private static func trimEnd(_ string: String) -> String {
        guard let lastNonWhitespace = string.lastIndex(where: { !$0.isWhitespace }) else {
            return ""
        }
        return String(string[...lastNonWhitespace])
    }

    /// 行首空格数（parser.rs:103-106 的 `take_while == ' '`）。
    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// scalar 内存在"':' 后紧跟空白"（parser.rs:157-166）。
    private static func containsColonSeparator(_ scalar: String) -> Bool {
        let characters = Array(scalar)
        guard characters.count > 1 else { return false }
        for index in 0..<(characters.count - 1) {
            if characters[index] == ":" && characters[index + 1].isWhitespace { return true }
        }
        return false
    }
}
