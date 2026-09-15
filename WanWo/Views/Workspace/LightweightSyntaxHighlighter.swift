//
//  LightweightSyntaxHighlighter.swift
//  WanWo
//
//  【M6.6 新写（B4）】轻量语法高亮（AttributedString 关键字/字符串/注释/数字
//  四类着色）。SwiftUI 无现成高亮器——按派单口径做轻量实现并在批次报告标注
//  「轻量实现」；正式高亮（treesitter 等）随 M9 视觉面对齐批次再议。
//  纯函数（无 IO；着色面不进单测——UI 视觉面不强测）。
//

import SwiftUI

enum LightweightSyntaxHighlighter {

    /// 语言关键词集（按扩展名分派；轻量子集——覆盖常见可读性关键词）。
    private static let keywords: [String: Set<String>] = [
        "swift": ["import", "struct", "class", "enum", "func", "var", "let", "if",
                  "else", "guard", "return", "switch", "case", "for", "while",
                  "extension", "protocol", "init", "self", "nil", "true", "false",
                  "static", "private", "public", "internal", "throw", "throws",
                  "try", "async", "await", "in", "where", "deinit", "actor"],
        "js": ["const", "let", "var", "function", "return", "if", "else", "for",
               "while", "class", "extends", "import", "export", "from", "async",
               "await", "new", "this", "null", "undefined", "true", "false",
               "try", "catch", "throw", "switch", "case", "default", "of", "in"],
        "py": ["def", "class", "return", "if", "elif", "else", "for", "while",
               "import", "from", "as", "with", "try", "except", "finally",
               "raise", "lambda", "None", "True", "False", "and", "or", "not",
               "in", "is", "async", "await", "yield", "pass", "break", "continue"],
        "c": ["#include", "int", "char", "void", "float", "double", "long",
              "short", "unsigned", "signed", "struct", "union", "enum", "static",
              "const", "return", "if", "else", "for", "while", "switch", "case",
              "break", "continue", "sizeof", "typedef", "extern", "goto"],
        "sh": ["if", "then", "else", "elif", "fi", "for", "in", "do", "done",
               "while", "case", "esac", "function", "return", "export", "local",
               "echo", "cd", "set", "unset", "source"],
        "sql": ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
                "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "JOIN",
                "ON", "GROUP", "BY", "ORDER", "LIMIT", "AND", "OR", "NOT"],
    ]

    private static let extensionMap: [String: String] = [
        "swift": "swift", "js": "js", "jsx": "js", "ts": "js", "tsx": "js",
        "mjs": "js", "cjs": "js", "py": "py", "c": "c", "h": "c", "cpp": "c",
        "cc": "c", "hpp": "c", "m": "c", "sh": "sh", "bash": "sh", "zsh": "sh",
        "sql": "sql",
    ]

    /// 单行注释前缀（按语言）。
    private static let lineComments: [String: String] = [
        "swift": "//", "js": "//", "c": "//", "py": "#", "sh": "#", "sql": "--",
    ]

    /// 判定是否 Markdown（文件页默认渲染视图）。
    static func isMarkdown(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// 语法着色（未识别扩展名 → 无着色原文）。
    static func highlight(code: String, fileName: String) -> AttributedString {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let lang = extensionMap[ext], let words = keywords[lang] else {
            return AttributedString(code)
        }
        var result = AttributedString()
        let commentPrefix = lineComments[lang]
        var inBlockComment = false
        let blockOpen = lang == "py" || lang == "sh" ? nil : "/*"
        let blockClose = "*/"

        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = String(line)
            if inBlockComment {
                if let range = rest.range(of: blockClose) {
                    append(result: &result, text: String(rest[..<range.upperBound]),
                           color: .secondary)
                    rest = String(rest[range.upperBound...])
                    inBlockComment = false
                } else {
                    append(result: &result, text: rest + "\n", color: .secondary)
                    continue
                }
            }
            if let prefix = blockOpen, let range = rest.range(of: prefix) {
                append(result: &result, text: String(rest[..<range.lowerBound]))
                let head = String(rest[range.lowerBound...])
                if let close = head.range(of: blockClose, range: range.upperBound..<head.endIndex) {
                    append(result: &result, text: String(head[..<close.upperBound]),
                           color: .secondary)
                    rest = String(head[close.upperBound...])
                } else {
                    append(result: &result, text: head, color: .secondary)
                    inBlockComment = true
                    append(result: &result, text: "\n")
                    continue
                }
            } else if let prefix = commentPrefix,
                      let range = rest.range(of: prefix) {
                append(result: &result, text: String(rest[..<range.lowerBound]))
                append(result: &result, text: String(rest[range.lowerBound...]),
                       color: .secondary)
                append(result: &result, text: "\n")
                continue
            }
            highlightSegment(rest, words: words, into: &result)
            append(result: &result, text: "\n")
        }
        return result
    }

    /// 行内着色：字符串（单/双引号）→ 绿、数字 → 橙、关键词 → 蓝紫、其余原色。
    private static func highlightSegment(_ segment: String,
                                         words: Set<String>,
                                         into result: inout AttributedString) {
        var buffer = ""
        var index = segment.startIndex
        func flush() {
            if !buffer.isEmpty {
                append(result: &result, text: buffer)
                buffer = ""
            }
        }
        while index < segment.endIndex {
            let ch = segment[index]
            if ch == "\"" || ch == "'" {
                flush()
                var literal = String(ch)
                var cursor = segment.index(after: index)
                var closed = false
                while cursor < segment.endIndex {
                    let c = segment[cursor]
                    literal.append(c)
                    if c == ch {
                        closed = true
                        cursor = segment.index(after: cursor)
                        break
                    }
                    cursor = segment.index(after: cursor)
                }
                append(result: &result, text: literal, color: .green)
                if closed { index = cursor } else { index = segment.endIndex }
                continue
            }
            if ch.isNumber, index == segment.startIndex
                || !segment[segment.index(before: index)].isLetter {
                flush()
                var number = String(ch)
                var cursor = segment.index(after: index)
                while cursor < segment.endIndex,
                      segment[cursor].isNumber || segment[cursor] == "." {
                    number.append(segment[cursor])
                    cursor = segment.index(after: cursor)
                }
                append(result: &result, text: number, color: .orange)
                index = cursor
                continue
            }
            if ch.isLetter || ch == "_" || ch == "#" {
                var word = String(ch)
                var cursor = segment.index(after: index)
                while cursor < segment.endIndex,
                      segment[cursor].isLetter || segment[cursor].isNumber
                        || segment[cursor] == "_" {
                    word.append(segment[cursor])
                    cursor = segment.index(after: cursor)
                }
                if words.contains(word) {
                    flush()
                    append(result: &result, text: word, color: .purple)
                } else {
                    buffer += word
                }
                index = cursor
                continue
            }
            buffer.append(ch)
            index = segment.index(after: index)
        }
        flush()
    }

    private static func append(result: inout AttributedString,
                               text: String,
                               color: Color? = nil) {
        var piece = AttributedString(text)
        if let color {
            piece.foregroundColor = color
        }
        result += piece
    }
}
