//
//  BashismDetector.swift
//  WanWo
//
//  【语义移植 · OpenMinis 原件】出处：repos/OpenMinis-main/src/ios/Agent/Shell/
//  BashismDetector.swift（1:1 移植；仅改 bundle 资源读取与日志类别字符串）。
//  检出 busybox-ash 不兼容的 bash 语法，shell 工具据此按需装 bash 并切换解释器
//  （T-bash-on-demand）。规则与修复提示在共享 JSON（bashism_rules.json，iOS 与
//  Android 共用同一份）——本类型只是匹配引擎。
//
//  算法（design §1）：
//    1. 剥离 heredoc 体（是数据——python/awk/SQL——不是 shell 语法；
//       扫描它们会造成 F1 假阳性风暴），
//    2. 对剩余 shell 层文本逐行正则扫描，
//    3. 50ms 墙钟熔断（fail-open）+ 4KB 单行上限（M2 ReDoS 防护）。
//

import Foundation

private let logger = AppLogger(category: "Bashism")

enum BashismDetector {

    enum Tier: String { case S, E, T1 }

    struct Rule {
        let name: String
        let tier: Tier
        let regex: NSRegularExpression
        let behaviorNote: String
        let fixHint: String
    }

    struct Hit {
        let line: Int          // 1-based，相对原始脚本
        let ruleName: String
        let tier: Tier
        let matchedText: String  // 清洗 + 截断的命中行片段
        let behaviorNote: String
        let fixHint: String
    }

    struct Result {
        let hits: [Hit]
        /// 任何命中 → 确认/安装 bash。
        var needsBash: Bool { !hits.isEmpty }
        /// 需要把解释器切到 bash 的命中（S 或 E；T1 是"脚本自己要求 bash"，不算）。
        var mustSwitchInterpreter: Bool { hits.contains { $0.tier == .S || $0.tier == .E } }
        var hasSilent: Bool { hits.contains { $0.tier == .S } }
    }

    // MARK: - 规则加载

    private static let heredocOpen = try! NSRegularExpression(
        pattern: "<<-?\\s*[\"']?(\\w+)[\"']?")

    private static let rules: [Rule] = loadRules()
    /// 供 reminder 构建器按名取修复提示。
    static var rulesByName: [String: Rule] {
        Dictionary(rules.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func loadRules() -> [Rule] {
        guard let url = Bundle.main.url(forResource: "bashism_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["rules"] as? [[String: Any]] else {
            logger.error("[Bashism] bashism_rules.json missing or malformed — detector disabled")
            return []
        }
        var out: [Rule] = []
        for r in arr {
            guard let name = r["name"] as? String,
                  let tierRaw = r["tier"] as? String, let tier = Tier(rawValue: tierRaw),
                  let pattern = r["pattern"] as? String else { continue }
            guard let rx = try? NSRegularExpression(pattern: pattern) else {
                logger.error("[Bashism] rule '\(name)' has an invalid regex — skipped")
                continue
            }
            out.append(Rule(name: name, tier: tier, regex: rx,
                            behaviorNote: r["behaviorNote"] as? String ?? "",
                            fixHint: r["fixHint"] as? String ?? ""))
        }
        logger.info("[Bashism] loaded \(out.count) rules")
        return out
    }

    // MARK: - Heredoc 剥离（F1）

    /// 返回每行原文与待扫描文本的配对；heredoc 体行（含定界符行）返回 nil 跳过，
    /// 行号保持与原始脚本对齐。
    static func shellLayerLines(_ script: String) -> [(line: Int, text: String?)] {
        let lines = script.components(separatedBy: "\n")
        var out: [(Int, String?)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            out.append((i + 1, line))  // 开启行属于 shell 层
            // 按顺序收集本行打开的每个 heredoc 定界符。
            let ns = line as NSString
            var delims: [String] = []
            for m in heredocOpen.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if m.numberOfRanges > 1 {
                    delims.append(ns.substring(with: m.range(at: 1)))
                }
            }
            i += 1
            for delim in delims {
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != delim {
                    out.append((i + 1, nil))  // 体行——不扫描
                    i += 1
                }
                if i < lines.count {   // 定界符行本身
                    out.append((i + 1, nil))
                    i += 1
                }
            }
        }
        return out
    }

    // MARK: - 检测

    static func detect(_ script: String, fuseMs: Double = 50) -> Result {
        guard !rules.isEmpty else { return Result(hits: []) }
        let start = Date()
        var hits: [Hit] = []
        for (lineNo, maybeText) in shellLayerLines(script) {
            guard let text = maybeText, !text.isEmpty else { continue }
            let scan = text.count > 4096 ? String(text.prefix(4096)) : text
            let ns = scan as NSString
            let range = NSRange(location: 0, length: ns.length)
            for rule in rules {
                if Date().timeIntervalSince(start) * 1000 > fuseMs {
                    logger.info("[Bashism] scan fuse tripped at \(hits.count) hits — fail-open")
                    return Result(hits: hits)
                }
                if rule.regex.firstMatch(in: scan, range: range) != nil {
                    hits.append(Hit(line: lineNo, ruleName: rule.name, tier: rule.tier,
                                    matchedText: scan.trimmingCharacters(in: .whitespaces),
                                    behaviorNote: rule.behaviorNote, fixHint: rule.fixHint))
                }
            }
        }
        return Result(hits: hits)
    }
}
