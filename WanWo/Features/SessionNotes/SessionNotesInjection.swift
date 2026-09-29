//
//  SessionNotesInjection.swift
//  WanWo
//
//  【语义移植 · Cline Memory Bank · M8 批2 件 B3】注入槽（PromptAssembler
//  新槽——memorySummary 槽同款形态，登记差异）：
//    · memorySummary 先例（AppEnvironment.makeAgentStack :1313-1318）为装配期
//      一次性静态读文件 → PromptSection；常驻笔记的语义是"每请求确定性注入"
//      （派单拍板），故走 DynamicPromptSection（assemble 时求值，AgentLoop
//      :1153 每次模型请求组装即重读桶内两文件）。
//    · 注入面 = activeContext + progress 两件（每请求确定性注入，各截 2000
//      字符，超限截断 + 尾注记指向 guest 全文路径——登记）；brief/tech/system
//      不自动注入（@引用或压缩时并入——工具面另批，登记）。
//    · 读不到文件 / 空文件 = 槽位缺省零扰动（段文本为空 → assemble 空段落
//      丢弃，PromptAssembler.swift:238 同语义）。
//
//  槽位排序（登记）：SECTION_ORDERS.sessionNotes = 930 —— memorySummary(920)
//  之后、toolBash(1000) 之前，与 memory:read-path / wanwo:link-guide 同属
//  "模型可见持久上下文/路径体系"主题族（920 位先例：PromptAssembler.swift:58-62）。
//

import Foundation

enum SessionNotesInjection {
    /// 每请求确定性注入段（动态段落；文本空 = 本请求零扰动）。
    static func dynamicSection(store: SessionNotesStore) -> DynamicPromptSection {
        DynamicPromptSection(
            name: SessionNotesConstants.sectionName,
            order: SECTION_ORDERS.sessionNotes,
            provider: { [weak store] in
                guard let store else { return "" }
                return sectionText(from: store) ?? ""
            })
    }

    /// 段文本构造（纯函数，测试直测）：
    ///   · 两件全空 → nil（零扰动）；
    ///   · 每件 ≤ 2000 字符，超限截断 + 尾注记（含 guest 全文路径，nil 则省略）。
    static func sectionText(from store: SessionNotesStore) -> String? {
        var blocks: [String] = []
        if let active = store.readBody(.activeContext) {
            blocks.append(renderBlock(title: "activeContext（当前工作焦点）",
                                      body: active,
                                      fileName: SessionNoteFile.activeContext.fileName,
                                      guestPath: store.guestNotesPath))
        }
        if let progress = store.readBody(.progress) {
            blocks.append(renderBlock(title: "progress（进度与已知问题）",
                                      body: progress,
                                      fileName: SessionNoteFile.progress.fileName,
                                      guestPath: store.guestNotesPath))
        }
        guard !blocks.isEmpty else { return nil }
        let ref = store.guestNotesPath.map { "（桶：\($0)/，可由用户手编）" } ?? ""
        return "[常驻笔记] 本项目持久笔记\(ref)\n\n" + blocks.joined(separator: "\n\n")
    }

    /// 单块渲染：标题 + 正文（截断 + 尾注记）。
    private static func renderBlock(title: String, body: String,
                                    fileName: String, guestPath: String?) -> String {
        let limit = SessionNotesConstants.injectionCharLimit
        if body.count > limit {
            let tailNote = guestPath.map {
                "（已截断至 \(limit) 字符，完整内容见 \($0)/\(fileName)）"
            } ?? "（已截断至 \(limit) 字符）"
            return "## \(title)\n" + String(body.prefix(limit)) + "\n" + tailNote
        }
        return "## \(title)\n" + body
    }
}
