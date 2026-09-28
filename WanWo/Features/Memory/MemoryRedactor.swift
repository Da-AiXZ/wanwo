//
//  MemoryRedactor.swift
//  WanWo
//
//  【语义移植 · codex · M7 件 G · F043】出处（repos/codex-rust-v0.153.0-alpha.6
//  codex-rs/secrets/src/sanitizer.rs 逐条 1:1）：
//    - OPENAI_KEY_REGEX     r"sk-[A-Za-z0-9]{20,}"
//    - AWS_ACCESS_KEY_ID    r"\bAKIA[0-9A-Z]{16}\b"
//    - BEARER_TOKEN         r"(?i:\bBearer)[ \t]+[A-Za-z0-9._~+/-]{16,}=*"
//      → 替换为 "Bearer [REDACTED_SECRET]"（保 Bearer 词干）
//    - SECRET_ASSIGNMENT    r"(?i)\b(api[_-]?key|token|secret|password)\b(\s*[:=]\s*)(["']?)[^\s"']{8,}"
//      → 替换为 "$1$2$3[REDACTED_SECRET]"（保键名/分隔符/引号）
//  应用位（phase1.rs :321-323 + :430）：rollout 序列化整体、Stage1 三字段输出
//  各自独立 redact——顺序与 codex 相同（先序列化整体、后输出字段）。
//

import Foundation

/// redact_secrets（sanitizer.rs 1:1；best-effort 正则替换）。
enum MemoryRedactor {
    /// 替换产物标记（sanitizer.rs 逐字）。
    static let marker = "[REDACTED_SECRET]"

    /// 四正则按 codex 应用次序执行：Bearer → OpenAI key → AWS key → 键值赋值。
    static func redact(_ input: String) -> String {
        var out = input
        out = replace(in: out,
                      pattern: #"(?i:\bBearer)[ \t]+[A-Za-z0-9._~+/-]{16,}=*"#,
                      template: "Bearer \(marker)")
        out = replace(in: out,
                      pattern: #"sk-[A-Za-z0-9]{20,}"#,
                      template: marker)
        out = replace(in: out,
                      pattern: #"\bAKIA[0-9A-Z]{16}\b"#,
                      template: marker)
        // 键值赋值：保 $1（键名）$2（分隔符）$3（引号），仅替换值。
        out = replace(in: out,
                      pattern: #"(?i)\b(api[_-]?key|token|secret|password)\b(\s*[:=]\s*)(["']?)[^\s"']{8,}"#,
                      template: "$1$2$3\(marker)")
        return out
    }

    /// NSRegularExpression 全局替换（模板中 $N 反向引用语义与 regex crate 一致）。
    private static func replace(in text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range,
                                              withTemplate: template)
    }
}
