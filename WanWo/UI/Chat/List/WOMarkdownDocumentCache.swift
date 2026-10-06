//
//  WOMarkdownDocumentCache.swift
//  WanWo
//
//  【批 1 · 件 4】Markdown 渲染"滚回秒出"——NSCache 文档级外挂。
//
//  实查结论（_mdlib_probe，SPM revision 5f7c04e 同源）：
//    · `MarkdownView(text:config:)` 只吃 raw 文本（内部自建
//      MarkdownViewController，每次实例 .task(id: text) 重 parse）；
//    · **`DocumentView(renderableDocument:config:)` 是 public**，直接吃
//      预解析产物 `RenderableDocument`（Equatable + Sendable）；
//    · `MarkdownParserImpl().parse(text:config:) async -> RenderableDocument`
//      是公开解析缝（MarkdownView 内部同一 API）。
//  → 可行形：settled（落盘非流式）正文经本缓存直喂 DocumentView；命中 =
//  零解析零重渲（滚回秒出），未命中 = 异步 parse 一次后入缓存。
//  流式正文（live 槽 + 补打期）**不进缓存**——块级 diff 原地更新语义是
//  既有流式重构成果（红线），继续走 MarkdownView(text:)。
//  缓存参数照 lody ChatParseCache:13-16（256 条 / 8MB，成本=文本字节数）。
//  半截修复 JS 不做（批 0 判卷已定：万我前缀快照天然容忍）。
//

import SwiftUI
import SwiftStreamingMarkdown

// MARK: - 文档缓存（NSCache 线程安全；解析 async 在协作线程池，主线程只取）

final class WOMarkdownDocumentCache: @unchecked Sendable {
    static let shared = WOMarkdownDocumentCache()

    /// 【批4 真机修复】解析完成广播名——core 订阅后对匹配行 remeasure
    ///（量高 host / 未显示行的池高度从 Text 近似值收敛到真文档值，
    /// contentSize 稳定、贴底落点准；修复前该收敛只能靠"行滚进视口
    /// → 显示 cell 回传"驱动，未滚到的行高度假值固化 = 空白洞/偏移）。
    static let documentParsedNotification =
        Notification.Name("WOMarkdownDocumentParsed")

    private final class Box {
        let document: RenderableDocument
        init(_ document: RenderableDocument) { self.document = document }
    }

    private let cache = NSCache<NSString, Box>()

    /// 配置代际（chatMarkdownConfig 是 static 单例；若未来配置可变，代际
    /// 入 key 自动失效旧文档）。
    private static let configTag = "v1"

    private init() {
        cache.countLimit = 256
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    /// 缓存键（流式/非流式分开命名空间是 lody 语义——本缓存只收非流式，
    /// 键内不再带流式位）。
    static func key(_ text: String) -> NSString {
        "\(Self.configTag)\u{0}\(text)" as NSString
    }

    func document(for text: String) -> RenderableDocument? {
        cache.object(forKey: Self.key(text))?.document
    }

    /// 解析并入库（未命中路径；命中直接返回缓存文档）。
    func parseAndStore(_ text: String,
                       config: MarkdownRenderConfig) async -> RenderableDocument {
        let key = Self.key(text)
        if let cached = cache.object(forKey: key)?.document { return cached }
        let parser = MarkdownParserImpl()
        let document = await parser.parse(text: text, config: config)
        cache.setObject(Box(document), forKey: key, cost: text.utf8.count)
        // 【批4 真机修复】解析完成广播（见 documentParsedNotification 注）。
        NotificationCenter.default.post(
            name: Self.documentParsedNotification, object: nil,
            userInfo: ["text": text])
        return document
    }
}

// MARK: - 缓存直喂视图（settled 正文渲染端；DocumentView 与 MarkdownView
// body 同源——同一 BlockView 渲染管线，视觉零变化）

struct WOCachedMarkdown: View {
    let text: String
    let config: MarkdownRenderConfig

    @State private var document: RenderableDocument?

    /// 【CI修48】缓存命中同步初始化：首帧即真文档（量高一次到位，滚回场景
    /// 消灭"空态→内容"的高度跳变）。未命中保持 nil 起步（.empty 占位），
    /// task 解析完成后经 WOHeightReporting 高度回传修正 cell frame。
    init(text: String, config: MarkdownRenderConfig) {
        self.text = text
        self.config = config
        _document = State(initialValue: WOMarkdownDocumentCache.shared.document(for: text))
    }

    var body: some View {
        // 【批4 诊断实证修 2026-10-06】每帧求值**同步查缓存**（NSCache 读
        // 微秒级；list-diag.log 实证两态分叉：#130 同一行 23→946→横跳、
        // "最后一轮总结正常"=恰在缓存命中）。缓存优先于 @State，治三态：
        // ①量高 host 的 .task 永不执行（离屏无 appearance）→ State 恒 nil
        // → stale 重测/宽度重测恒量近似值，把显示面已修正的真值**写回假值**
        // （高度横跳根源）；②NSCache 内存逐出后显示 cell 重建 State(nil)
        // 而同文本行已被别的 cell 解析入库；③State 保留陷阱（.id 不变时
        // State(initialValue:) 不再求值）。@State 降级为"缓存 miss 后的
        // 异步解析承接位"。
        let resolved = WOMarkdownDocumentCache.shared.document(for: text) ?? document
        if let resolved {
            DocumentView(renderableDocument: resolved, config: config)
        } else {
            Text(text)
                .font(.system(size: 17))
                .lineSpacing(4)
                .task(id: text) {
                    let parsed = await WOMarkdownDocumentCache.shared
                        .parseAndStore(text, config: config)
                    // 任务竞态防御：文本已变/视图已离场时丢弃过期解析结果。
                    guard !Task.isCancelled else { return }
                    document = parsed
                }
        }
    }
}
