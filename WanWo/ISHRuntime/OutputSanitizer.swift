//
//  OutputSanitizer.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §5.4（OutputSanitizer 一行）+
//  §十一 M0.4（"OutputSanitizer 最小版"）。M0 只实现最小管线：
//    \r 折叠 → ANSI/VT 转义剥离 → 头尾截断(15000)
//  （UTF-8 边界安全由 Swift String 天然保证；0.2s 节流 flush 由
//  ShellTestView 的显示层负责）。完整六段管线在 M2.4 补齐。
//

import Foundation

enum OutputSanitizer {
    /// 单段输出清洗：折叠 \r（含 \r\n）、剥离 ANSI/VT 转义序列、限长截断。
    static func sanitize(_ raw: String) -> String {
        // 1. \r 折叠：CR/LF 归一为 \n（iSH 行回调通常已去 \n，防御裸 \r）
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // 2. ANSI/VT 剥离：CSI 序列（ESC [ ... 终止符）+ OSC 序列 + 其余 ESC 开头序列
        text = stripANSIEscapes(text)

        // 3. 头尾截断（§5.4：15000）
        if text.count > 15_000 {
            let head = String(text.prefix(7_500))
            let tail = String(text.suffix(7_500))
            text = head + "\n…(truncated)…\n" + tail
        }
        return text
    }

    /// 剥离 ANSI 转义：CSI（ESC[ 参数/中间字节+终止符 @-~）、OSC（BEL/ST 终止）、
    /// 以及其余 ESC + 单字符序列（如 \u{1B}M、\u{1B}7）。
    private static func stripANSIEscapes(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var iterator = text.unicodeScalars.makeIterator()

        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI 序列：吞到 0x40–0x7E 终止字节
                while let c = iterator.next() {
                    if c.value >= 0x40 && c.value <= 0x7E { break }
                }
            } else if next == "]" {
                // OSC 序列：吞到 BEL 或 ST（ESC \）
                while let c = iterator.next() {
                    if c == "\u{07}" { break }
                    if c == "\u{1B}" { _ = iterator.next(); break }
                }
            }
            // 其余 ESC + 单字符：直接丢弃
        }
        return String(out)
    }
}
