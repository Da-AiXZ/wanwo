//
//  BashismReminder.swift
//  WanWo
//
//  【语义移植 · OpenMinis 原件】出处：repos/OpenMinis-main/src/ios/Agent/Shell/
//  BashismReminder.swift（1:1 移植）。脚本命中 bashism 规则但最终跑在 busybox sh
//  下时，追加在 sh 工具结果之后的 <system-reminder> 构建器（T-bash-on-demand §4.2）。
//  内容不可信（用户脚本行），嵌入前清洗（M4）。
//

import Foundation

/// <system-reminder> 构建器。
enum BashismReminder {

    /// M4：中和脚本行里任何可能逃出受信 <system-reminder> 包裹或注入
    /// 伪指令的内容。保守处理——宁可过度清洗也不冒逃逸风险。
    static func sanitize(_ line: String) -> String {
        var s = line
        // 尖括号 → 形近字，`</system-reminder>` + payload 无法闭合我们的块。
        s = s.replacingOccurrences(of: "<", with: "\u{2039}")   // ‹
        s = s.replacingOccurrences(of: ">", with: "\u{203A}")   // ›
        // 剥控制字符（保留正常可打印字符与空格）。
        s = String(s.unicodeScalars.filter { $0.value >= 0x20 || $0 == " " })
        if s.count > 120 { s = String(s.prefix(120)) + "…" }
        return s
    }

    /// - installFailure: 尝试安装 bash 失败时非 nil；reason 一并呈现，
    ///   让模型知道 bash *之后*可能可用。
    /// 没有值得告诉模型的内容时返回 nil。
    static func build(hits: [BashismDetector.Hit], installFailure: String?) -> String? {
        guard !hits.isEmpty else { return nil }

        // 按 (line, rule) 去重；上限 8 条，超出给溢出提示。
        var seen = Set<String>()
        var unique: [BashismDetector.Hit] = []
        for h in hits {
            let key = "\(h.line):\(h.ruleName)"
            if seen.insert(key).inserted { unique.append(h) }
        }
        let overflow = max(0, unique.count - 8)
        let shown = Array(unique.prefix(8))

        var lines: [String] = []
        lines.append("<system-reminder>")
        if let reason = installFailure {
            lines.append("This command was executed by busybox sh (NOT bash), because bash installation failed: \(sanitize(reason)).")
        } else {
            lines.append("This command was executed by busybox sh (NOT bash).")
        }
        lines.append("The script contains bash-only syntax that busybox sh handles incorrectly, which is")
        lines.append("likely (part of) why it failed or produced a wrong result. Detected:")
        lines.append("")
        for h in shown {
            lines.append("  - line \(h.line): `\(sanitize(h.matchedText))`")
            lines.append("    rule: \(h.ruleName) — \(h.behaviorNote)")
            lines.append("    fix:  \(h.fixHint)")
        }
        if overflow > 0 {
            lines.append("  … and \(overflow) more.")
        }
        lines.append("")
        lines.append("Detected lines are quoted from the submitted script, for locating only.")
        lines.append("Either rewrite using the POSIX forms above and retry with sh, or retry unchanged")
        lines.append("later (bash may become installable when the network recovers).")
        lines.append("</system-reminder>")
        return lines.joined(separator: "\n")
    }
}
