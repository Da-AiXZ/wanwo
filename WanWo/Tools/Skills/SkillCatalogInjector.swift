//
//  SkillCatalogInjector.swift
//  WanWo
//
//  【M4-D 件 D4 · F030 会话目录注入（渐进一级）】语义移植 · dsh 契约：
//  skills.md:229-235（durable user 消息 `<available_skills>` 仅 name+XML 转义
//  description；单条 description ≤500=catalogDescriptionMaxLength；digest 步进
//  替换；压缩影子化后重建）。预算：10-design:507"目录 2%" + codex render.rs
//  :18/:20（MAX_CONFIGURED_SKILL_METADATA_TOKEN_BUDGET=10_000 / 2% 窗口）。
//
//  形态（lead 派单钉死）：user/message 事件，text=`<system-reminder>` 包装 +
//  内含 `<available_skills>` 标签对；标签内逐技能两行（name + XML 转义
//  description）；条目按 name 字典序；不含 body/路径/source/whenToUse；
//  全删 → 显式空替换 `<available_skills></available_skills>`。
//
//  digest 基线（lead 指定派生面）：每步从 DeriveFold 产物（派生视角=未影子化
//  消息序列）找最后一个含 `<available_skills>` 的 user/message——目录消息被
//  压缩影子化时派生序列里没有 → 基线丢失 → 下个快照自动重建（dsh :233 同
//  语义天然成立）。对比口径 = 渲染消息全文全等（增/删/改描述任一变化即触发）。
//
//  预算三档简化（lead 授权）：codex render.rs :317-366 三档（全量/round-robin
//  均分/保最小行+Omitted）→ WanWo 第一版两档：全量装得下 → 全量；装不下 →
//  贪心装全条目 + 末尾 omission marker（codex :1151-1153 文案逐字）+ 登记
//  round-robin 不做。token 估算 = Compactor.estimateText（UTF-8/3，M2 估计器）。
//  预算口径登记：第一版固定 cap 10k tokens（codex 上限常量）；"2% 窗口"动态面
//  需模型窗口元数据（M8 TokenMeter/模型面可用时接 tokenBudget 参数）。
//
//  R2：目录消息=user/message 既有词汇；投影过滤=ConversationProjector.
//  markerPrefixes 扩 `<system-reminder>` 前缀（简报暴露项 2，runtime-context
//  §5.9 归属识别同位）。
//

import Foundation

/// 技能目录注入（纯函数命名空间 + 无状态投影；每步从事件流重导基线，
/// 零 AgentLoop 状态——派生面即状态）。
enum SkillCatalogInjector {

    /// 归属标记（消息含此标记即目录消息；投影过滤与基线识别共用）。
    static let ownershipMarker = "<available_skills>"
    /// 单条 description 上限（dsh catalogDescriptionMaxLength；超限截断）。
    static let catalogDescriptionMaxLength = 500
    /// 整目录 token 预算（codex render.rs:18 上限常量；"2% 窗口"动态面登记见头注）。
    static let defaultTokenBudget = 10_000
    /// 截断后缀（codex render.rs:22 TRUNCATED_SKILL_DESCRIPTION_SUFFIX 逐字）。
    static let truncatedSuffix = "..."

    // MARK: 消息渲染

    /// 快照 → 目录消息全文。空快照 → 显式空替换（`<available_skills></available_skills>`）。
    static func message(for snapshot: SkillSnapshot,
                        tokenBudget: Int = SkillCatalogInjector.defaultTokenBudget) -> String {
        "<system-reminder>\n" + availableSkillsBlock(for: snapshot, tokenBudget: tokenBudget)
            + "\n</system-reminder>"
    }

    /// `<available_skills>` 块（不含 system-reminder 包装；测试锚点）。
    static func availableSkillsBlock(for snapshot: SkillSnapshot,
                                     tokenBudget: Int = SkillCatalogInjector.defaultTokenBudget) -> String {
        // 逐技能两行：name 行 + XML 转义 description 行（≤500）；条目按 name
        // 字典序（契约自持——不依赖上游 scan 的排序，防御性重排）。
        let fullLines = snapshot.summaries
            .sorted { $0.name < $1.name }
            .map { summary -> String in
                summary.name + "\n" + catalogDescription(summary.description)
            }
        let fullBody = fullLines.joined(separator: "\n")

        // 档一：全量装得下。
        if Compactor.estimateText(fullBody) <= tokenBudget {
            return wrapBody(fullBody)
        }

        // 档二（简化授权）：贪心装全条目 + Omitted marker（codex :1151-1153 文案）。
        // D6 顺手补（D4 review 登记项）：marker 自身 token 成本计入预算——装不下
        // 时从尾部回退条目给 marker 让位（codex 保底语义：marker 必现，宁可少装
        // 条目也不让 marker 超预算）；空目录回退到底时 marker 超预算仍输出。
        var included: [(entry: String, cost: Int)] = []
        var used = 0
        var omitted = 0
        for entry in fullLines {
            let separatorCost = included.isEmpty ? 0 : Compactor.estimateText("\n")
            let cost = Compactor.estimateText(entry) + separatorCost
            if used + cost <= tokenBudget {
                included.append((entry, cost))
                used += cost
            } else {
                omitted += 1
            }
        }
        if omitted > 0 {
            // marker 让位循环：回退尾条目直至 marker 装得下（marker 文案随
            // omitted 数变化，逐轮重估；条目成本按登记值精确回收）。
            while true {
                let markerCost = Compactor.estimateText(omissionMarker(omitted))
                    + (included.isEmpty ? 0 : Compactor.estimateText("\n"))
                if used + markerCost <= tokenBudget { break }
                guard let last = included.popLast() else { break }
                omitted += 1
                used -= last.cost
            }
            // CI 第十轮实证：body 拼接必须**在让位循环之后**（popLast 回退只改
            // included 数组，先拼的 body 字符串不会跟着缩——原时序把被回退的
            // 条目留在了 body 里）。
            body = included.map(\.entry).joined(separator: "\n")
            let marker = omissionMarker(omitted)
            body += (body.isEmpty ? "" : "\n") + marker
        }
        return wrapBody(body)
    }

    private static func wrapBody(_ body: String) -> String {
        body.isEmpty ? "<available_skills></available_skills>"
                     : "<available_skills>\n\(body)\n</available_skills>"
    }

    /// codex render.rs:1151-1153 逐字（单复数）。
    static func omissionMarker(_ omitted: Int) -> String {
        let skillWord = omitted == 1 ? "skill" : "skills"
        return "- \(omitted) additional \(skillWord) omitted from this bounded skills list."
    }

    /// description 归一：XML 转义 + ≤500 截断（前缀 497 + "..."，codex
    /// TRUNCATED_SKILL_DESCRIPTION_SUFFIX 语义）。
    static func catalogDescription(_ description: String) -> String {
        let escaped = xmlEscape(description)
        guard escaped.count > catalogDescriptionMaxLength else { return escaped }
        let prefixCount = catalogDescriptionMaxLength - truncatedSuffix.count
        return String(escaped.prefix(prefixCount)) + truncatedSuffix
    }

    /// XML 转义（dsh "normalized, XML-escaped"：& < > " ' 五实体）。
    static func xmlEscape(_ text: String) -> String {
        var result = text
        // & 必须最先（避免二次转义）。
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    // MARK: 派生面基线与投影

    /// 派生视角基线（lead 指定）：DeriveFold 产物（未影子化序列）中最后一个
    /// 含 `<available_skills>` 的 user/message 全文；无 → nil。目录消息被压缩
    /// 影子化 → 派生序列无此消息 → 基线丢失 → 快照重建（dsh :233 同语义）。
    static func baselineText(events: [SessionEvent]) -> String? {
        for message in DeriveFold(events).messages.reversed() {
            guard message.role == .user,
                  message.content.contains(ownershipMarker) else { continue }
            return message.content
        }
        return nil
    }

    /// 组装期投影：返回需要追加注入的目录消息全文；nil = 无变化不注入。
    /// - 空快照且历史上从无目录消息 → nil（空态零噪音，dsh 首注=non-empty）。
    /// - 空快照但历史有 → 显式空替换（dsh 全删语义）。
    static func project(snapshot: SkillSnapshot,
                        events: [SessionEvent],
                        tokenBudget: Int = SkillCatalogInjector.defaultTokenBudget) -> String? {
        let candidate = message(for: snapshot, tokenBudget: tokenBudget)
        let baseline = baselineText(events: events)
        if snapshot.summaries.isEmpty && baseline == nil { return nil }
        if candidate == baseline { return nil }
        return candidate
    }
}
