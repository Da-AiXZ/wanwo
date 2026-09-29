//
//  ContextSummarizer.swift
//  WanWo
//
//  【边界锚点 + 锚点承载装饰器 · M8 批2 件B2】出处：
//    - 锚点消息：claudecode-compact-template-verify.md §②d（isCompactSummary 合成 user
//      消息逐字，三源交叉一致：juejin snipCompact / blog.fsck.com JSONL 实测 / gist v2.1.68）
//    - 锚点承载归属：b1-report.md §五/偏差 #4——锚点文案由 ContextSummarizer.summarize
//      返回值承载，B1 投影原样插入 `<compaction-summary>` 信封 + summaryOffset 定位
//  登记见 analysis/m8-fix/b2-report.md §八：协议声明已归位 B1（CondensationRecord.swift，
//  签名逐字一致），本文件只留锚点纯函数与装饰器（B2 白名单内）。
//

import Foundation

// MARK: - 边界锚点合成消息（交付 B1 消费的纯函数）

/// 锚点组装：prefix + "\n\n" + summary（claudecode §②d："[<summary> 内容（剥离
/// analysis 后）]" = 插槽语义；summary 参数为剥离 analysis 后的摘要正文）。
func continuationAnchorMessage(summary: String) -> String {
    ContextSummarizerAnchor.prefix + "\n\n" + summary + "\n\n" + ContextSummarizerAnchor.suffix
}

/// 锚点常量（claudecode §②d 原文逐字；测试逐字断言用）。
enum ContextSummarizerAnchor {
    static let prefix =
        "This session is being continued from a previous conversation that ran out of context. "
        + "The summary below covers the earlier portion of the conversation."
    /// auto 场景追加句（manual 场景不拼——claudecode §②d「若 auto-compact 追加」语义）。
    static let suffix =
        "Please continue the conversation from where we left off without asking the user any further "
        + "questions. Continue with the last task that you were asked to work on."
}

// MARK: - 锚点承载装饰器（b1 偏差 #4 的 B2 侧落点）

/// 包裹任意 ContextSummarizer：把内层摘要正文装进锚点合成消息后返回（B1 投影
/// 原样入 `<compaction-summary>` 信封）。装配组合建议（b1-report §五.6）：
/// `AnchorCarryingSummarizer(base: 复合 conformer(结构化主 → basic 兜底), …)`。
/// - includeContinuationDirective = true（auto 压缩）：suffix 追加句在位；
///   = false（manual /compact）：只带 prefix（§②d「若 auto-compact 追加」语义；
///   tombstone 无 reason 字段，场景判定由装配调用侧自理——b1 对齐消息第 2 条）。
/// - 内层返回 nil（失败）→ 原样透传 nil（B1 熔断计数不受装饰影响）。
/// - 登记后果：tombstone.summary 含锚点前缀，下一轮 previousSummary 亦然——
///   增量折叠 Previous summary 段将含锚点文案（Cline :139-151 语义下可接受，登记）。
struct AnchorCarryingSummarizer: ContextSummarizer {
    let base: ContextSummarizer
    let includeContinuationDirective: Bool

    func summarize(serializedEvents: [String], previousSummary: String?) async -> String? {
        guard let summary = await base.summarize(serializedEvents: serializedEvents,
                                                 previousSummary: previousSummary) else {
            return nil
        }
        if includeContinuationDirective {
            return continuationAnchorMessage(summary: summary)
        }
        return ContextSummarizerAnchor.prefix + "\n\n" + summary
    }
}
