//
//  OutputSanitizer.swift
//  WanWo
//
//  【语义移植 · OpenMinis AIChatViewModel+ISHCommand.swift sanitizeTerminalOutput
//  1:1 + 10-design §5.4 完整六段管线】M0 只实现了最小版；M2.4 补齐：
//    1. \r 折叠（模拟 TTY 光标回列：同行只保留最后非空段——终端最终显示的文本）
//    2. 折叠遗留连续空行收敛
//    3. ANSI/VT 转义剥离（CSI / OSC / Fe 单字符 / 裸 ESC）
//    4. UTF-8 边界安全（Swift String 标量级处理天然保证；截断按 Character 切）
//    5. 头尾 15000 截断（head + tail 双保留 + 截断说明）
//    6. 0.2s 节流 flush 由 UI 层负责（ShellTestView / ChatViewModel 的 0.2s 模式）
//
//  出处细节：OpenMinis AIChatViewModel+ISHCommand.swift sanitizeTerminalOutput
//  （Pass 1 CR 折叠 + Pass 2 ANSI 正则剥离）与 kMaxToolResultChars 截断语义。
//

import Foundation

enum OutputSanitizer {

    /// §5.4：单段输出最大 15000 字符。
    static let maxOutputChars = 15_000

    /// 单段输出清洗（完整版）：\r 折叠 → ANSI/VT 剥离 → 头尾截断。
    static func sanitize(_ raw: String) -> String {
        // Pass 1+2：CR 折叠 + 转义剥离。
        var text = sanitizeTerminalOutput(raw)
        // Pass 3：头尾截断（§5.4：15000；head+tail 双保留，模型看得见首尾）。
        if text.count > maxOutputChars {
            let totalChars = text.count
            let totalLines = text.components(separatedBy: "\n").count
            let halfLen = maxOutputChars / 2
            let head = String(text.prefix(halfLen))
            let tail = String(text.suffix(halfLen))
            text = head
                + "\n\n…\n\n"
                + tail
                + "\n\n[OUTPUT TRUNCATED] Showing first & last \(halfLen) of \(totalChars) chars "
                + "(\(totalLines) lines total). Use the read tool to inspect specific sections."
        }
        return text
    }

    /// 终端输出净化（OpenMinis sanitizeTerminalOutput 1:1）。
    ///
    /// **Pass 1 — 回车折叠**
    /// 真实 TTY 处理 `\r` 是把光标移到列 0，后续字符覆盖同行已有内容。管道捕获的
    /// 输出没有 TTY，每个 `\r` 更新都原样入库。yt-dlp/curl/wget/rsync 等工具会吐
    /// 出成百行进度噪声。按同一光标逻辑回放：每个换行分块内按 `\r` 切分，只保留
    /// 最后一个非空段——终端最终显示的文本。
    ///
    /// **Pass 2 — ANSI/VT 转义剥离**
    /// CR 折叠后的文本仍可能带 ANSI SGR 颜色/样式码（`\033[1;32m`、`\033[0m`）、
    /// 光标移动序列（`\033[A`、`\033[2K`、`\033[G`）与其他 CSI/OSC/ST 控制序列。
    /// 纯文本里它们都不承载语义；剥掉即得干净输出。
    static func sanitizeTerminalOutput(_ raw: String) -> String {
        // ── Pass 1: 回车折叠 ──────────────────────────────────────────
        let crFolded: String
        if !raw.contains("\r") {
            crFolded = raw
        } else {
            var lines: [String] = []
            for chunk in raw.components(separatedBy: "\n") {
                if !chunk.contains("\r") {
                    lines.append(chunk)
                } else {
                    // 按 \r 切分；最后非空段即终端显示的内容。
                    let segments = chunk.components(separatedBy: "\r")
                    let final = segments.last(where: { !$0.isEmpty }) ?? segments.last ?? ""
                    lines.append(final)
                }
            }
            // 收敛折叠遗留的连续空行。
            var collapsed: [String] = []
            var blankRun = 0
            for line in lines {
                if line.isEmpty {
                    blankRun += 1
                    if blankRun <= 1 { collapsed.append(line) }
                } else {
                    blankRun = 0
                    collapsed.append(line)
                }
            }
            crFolded = collapsed.joined(separator: "\n")
        }

        // ── Pass 2: ANSI/VT 转义剥离 ─────────────────────────────────
        // 覆盖：
        //   CSI 序列   \033[ … <终止字节 0x40-0x7E>（颜色、光标移动、擦除）
        //   OSC 序列   \033] … \007 或 \033] … \033\\（窗口标题、超链接）
        //   单字符 Fe  \033[A-Z@\[\\\]^_]（如 \033M 反向索引）
        //   裸 ESC     \033（不匹配上述任何后继）
        guard crFolded.contains("\u{1B}") else { return crFolded }

        // 单条 NSRegularExpression 应用开销很低；模式锚定在 ESC 上。
        let pattern = "\u{1B}(?:\\[[0-9;]*[A-Za-z@`]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_]|\u{1B})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return crFolded }
        let range = NSRange(crFolded.startIndex..., in: crFolded)
        return regex.stringByReplacingMatches(in: crFolded, range: range, withTemplate: "")
    }
}
