//
//  RepeatCallAdviser.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh repeat-tool-reminder（阈值 [3,5,8] advisory：
//  同名同参数重复调用在命中阈值时给模型一段提醒文本；只提醒不拦截、不改变执行）
//  + 10-design §5.3（RepeatCallAdviser F020）。
//

import Foundation

/// 同参数重复调用提醒器（F020）。阈值 [3,5,8]：第 3/5/8 次（及此后每 5 次）
/// 命中时返回 advisory 文本；其余返回 nil。只提醒——执行决策不变。
actor RepeatCallAdviser {
    static let thresholds: [Int] = [3, 5, 8]

    /// key = 工具名 + 规范化参数文本 → 已见次数。
    private var counters: [String: Int] = [:]

    /// 记录一次调用并按需返回提醒。
    /// - Returns: 命中阈值时的 advisory 文本；否则 nil。
    func advise(tool: String, canonicalArgs: String) -> String? {
        let key = "\(tool)\u{1F}\(canonicalArgs)"
        let count = (counters[key] ?? 0) + 1
        counters[key] = count

        let thresholds = Self.thresholds
        if thresholds.contains(count) {
            return Self.reminderText(tool: tool, count: count)
        }
        if count > thresholds[thresholds.count - 1], (count - thresholds[thresholds.count - 1]) % 5 == 0 {
            return Self.reminderText(tool: tool, count: count)
        }
        return nil
    }

    /// 新回合重置（每个回合的重复计数独立）。
    func reset() {
        counters.removeAll()
    }

    private static func reminderText(tool: String, count: Int) -> String {
        """
        <advisory>You have already made this exact \(tool) call \(count) times in this turn \
        with identical arguments. The result will be the same. Do NOT repeat the call: \
        change the arguments, use a different tool, or end your turn with an answer.</advisory>
        """
    }
}
