//
//  ConversationProjector.swift
//  WanWo
//
//  【M3 E2 · live/replay 统一投影】出处：dsh packages/client/ui-conversation/
//  src/client/conversation/assembler.ts——live 增量（append :220-242）与 replay
//  全量（replaceWindow :192-213）走同一套 definition.match 折叠（matchInput
//  :386-436），视图节点按 startSeq 排序（replayContexts :554-565；
//  indexStartedContext :688-696），「节点位置 = 起始事件 seq」对两个投影恒成立。
//  WanWo 形态：事件→气泡折叠收敛为本文件唯一纯函数；live 路径不再按到达序
//  自行追加工具卡（E2 前的分叉点），统一到事件时间序。
//  瞬态字段（liveOutput/statusNote，不在事件流中）按 callId 续接——对应 dsh
//  assembler 的 current map + dirty upsert（只重建 dirty 节点、未变节点保状态，
//  buildTargetUpserts :809-826）。
//

import Foundation

enum ConversationProjector {

    // MARK: - 产物类型（原 ChatViewModel 嵌套类型；live/replay 共用折叠的产物）

    /// 工具卡状态（dsh 工具卡 M2 素净版；正式卡片族 = M9）。
    struct ToolCard: Identifiable, Equatable {
        /// Identifiable（ForEach/差分用；callId 全局唯一即 id）。
        var id: String { callId }

        let callId: String
        var name: String
        var title: String
        var detail: String?
        /// 【批2 2B 件5 DetailsPanel 对齐】模型原始参数 JSON 文本（tool/call
        /// 的 arguments 原文；详情展开态 pretty 化呈现——dsh DetailsPanel
        /// input 段 material.argsRaw 同语义）。
        var argsRaw: String?
        /// 流式输出（shell 行等；E2：环形窗口封顶，见 ChatViewModel 纪律）。
        var liveOutput: String = ""
        /// 结果文本（收敛后）。
        var resultText: String?
        var isError: Bool = false
        /// 【批2 2B 件5】结构化失败身份（dsh DetailsPanel error.name:code 行）。
        var errorName: String?
        var errorCode: String?
        var isRunning: Bool = true
        /// 交互状态行（M3 T1：审批 waiting/结算态、提问 waiting——dsh 流内
        /// toolview 行的 WanWo 形态；琥珀语义行）。
        var statusNote: String?
    }

    struct Bubble: Identifiable, Equatable {
        enum Kind: Equatable {
            /// F042：user 气泡携带图片引用（E1 attachment/images 挂接产物；
            /// 空数组 = 纯文本消息）。
            case user(String, [ImageAttachmentRef])
            case assistant(String)
            case reasoning(String)
            case tool(ToolCard)
            case command(kind: String, text: String)
            case note(String)
            /// 【批2 2B 件4】轮次用量/用时 pill（TurnUsagePanel.tsx:99-235
            /// 语义——轮次尾 pill，点开明细）。
            case turnUsage(TurnUsageSummary)
        }

        let id: String
        var kind: Kind
    }

    // MARK: 批2 2B 件4：轮次用量投影（TurnUsagePanel 数据面）

    /// 单轮用量/用时折叠（事件流 turnStart→turnEnd 区间；数据源核实结论：
    /// assistantMessage 每 step 落盘 TokenUsage——inputTokens=uncached 口径
    /// （LLMTypes.swift:18-25 mapUsage 对齐），TTFT/decode 时长事件流无记录
    /// → 吞吐/TTFT 行缺席（dsh「组缺席」语义，同 StatsLine 头注口径）。
    struct TurnUsageSummary: Equatable {
        let turn: Int
        /// uncached 输入（TokenUsage.inputTokens 原口径）。
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens: Int?
        var reasoningTokens: Int?
        /// 计费输入（dsh TurnUsagePanel cacheHit 分母 = total-output 三桶口径；
        /// WanWo cacheWrite 恒 0 → uncached + cacheRead，同 StatsLine billedInput）。
        var billedInputTokens: Int { inputTokens + (cacheReadTokens ?? 0) }
        /// 消耗总量（dsh totalTokens = billedInput + output）。
        var totalTokens: Int { billedInputTokens + outputTokens }
        /// 轮次墙钟（turnStart → turnEnd；ms；turnStart 缺失 = 0 不显示）。
        var runMs: Int64 = 0
    }

    // MARK: - 注入/标记消息过滤（F038/F039/F040 + 压缩摘要呈现；不渲染气泡）

    /// M4-D D4：`<system-reminder>` = 技能目录消息包装前缀（简报暴露项 2——
    /// SkillCatalogInjector 产物不渲染用户气泡；§5.9 归属识别同位扩展）。
    /// M4-D D6：`<skill ` = 显式触发正文注入消息前缀（SkillMentionInjector
    /// 产物，同不渲染）。
    static let markerPrefixes = ["<runtime-context>", "<agents-md-update>",
                                 "<compaction-summary>", "<file>",
                                 "<permission-update>", "<plan-mode-update>",
                                 "<system-reminder>", "<skill ",
                                 // 真机批 B4：作业完成纸条（JobCompletionNotice——
                                 // 给 AI 的中间事件）对用户隐藏（无感）。
                                 "【系统通知】"]

    static func isMarkerMessage(_ text: String) -> Bool {
        markerPrefixes.contains { text.hasPrefix($0) }
    }

    // MARK: - 折叠（唯一规则）

    /// 事件流 → 气泡（纯函数；live 重投影与 replay 打开共用同一条规则——
    /// dsh assembler 语义：append 与 replaceWindow 同一 matchInput）。
    ///
    /// - Parameters:
    ///   - events: 已落盘事件（append-only；seq 升序）。
    ///   - registry: 工具注册表（presentCall/presentResult 纯函数复现）。
    ///   - callArgs: callId → (name, args) 缓存（presentResult 复现用；inout 累积）。
    ///   - previousCards: 上一投影的现存工具卡快照（瞬态字段续接源）。
    static func project(events: [SessionEvent],
                        registry: ToolRegistry?,
                        callArgs: inout [String: (name: String, args: JSONValue)],
                        previousCards: [String: ToolCard] = [:]) -> [Bubble] {
        var result: [Bubble] = []
        // 【批2 2B 件4】轮次用量累积（turn → 累积值 + 起始墙钟）。
        var turnUsage: [Int: TurnUsageSummary] = [:]
        var turnStartMs: [Int: Int64] = [:]
        for event in events {
            switch event.payload {
            case .turnStart(let turn):
                turnStartMs[turn] = event.timeMs
                turnUsage[turn] = TurnUsageSummary(turn: turn)

            case .userMessage(let text):
                guard !isMarkerMessage(text) else { continue }
                result.append(Bubble(id: "u\(event.seq)", kind: .user(text, [])))

            case .extensionEvent(let kind, let payload)
                where kind == AttachmentStore.imagesEventKind:
                // F042：附件引用回填归属 userMessage 气泡（引用事件紧随其
                // userMessage 落盘，载荷声明归属 seq）。未命中/解析失败即忽略
                // ——呈现退化为纯文本（fail closed；live 乐观气泡先纯文本，
                // 本回填发生在 reproject 或紧随的乐观气泡之后同轮投影）。
                if let parsed = AttachmentStore.refsFromPayload(payload),
                   !parsed.refs.isEmpty,
                   let index = result.lastIndex(where: { $0.id == "u\(parsed.seq)" }),
                   case .user(let text, _) = result[index].kind {
                    result[index].kind = .user(text, parsed.refs)
                }

            case .assistantMessage(let turn, let step, let message, let usage, _):
                // 【批2 2B 件4】轮次用量累积（assistantMessage usage = 每 step
                // 落盘的 TokenUsage；缺 turnStart 的旧流兜底建桶）。
                if usage != nil, turnUsage[turn] == nil {
                    turnUsage[turn] = TurnUsageSummary(turn: turn)
                }
                if var summary = turnUsage[turn], let usage {
                    summary.inputTokens += usage.inputTokens
                    summary.outputTokens += usage.outputTokens
                    // cacheRead/reasoning 逐 step 可选——任一 step 出现即汇总
                    // （nil = 该维度事件流无记录，呈现面缺席）。
                    if let read = usage.cacheReadTokens {
                        summary.cacheReadTokens = (summary.cacheReadTokens ?? 0) + read
                    }
                    if let reasoning = usage.reasoningTokens {
                        summary.reasoningTokens = (summary.reasoningTokens ?? 0) + reasoning
                    }
                    turnUsage[turn] = summary
                }
                // 思考/回复按块分立（E2）：块序 = content 数组序；气泡 id 锚定
                // 事件 seq + 块下标（对前后事件增删稳定——LazyVStack 身份不抖，
                // 长文本不被无谓重建）。
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .text(let t):
                        result.append(Bubble(id: "a\(event.seq)-b\(blockIndex)",
                                             kind: .assistant(t)))
                    case .reasoning(let t):
                        result.append(Bubble(id: "a\(event.seq)-b\(blockIndex)",
                                             kind: .reasoning(t)))
                    case .toolCall:
                        break // 工具卡由 tool/call 事件渲染
                    }
                }

            case .toolCall(let turn, let step, let callId, let name, let arguments):
                let args = ToolCallScheduler.parseArgs(arguments)
                callArgs[callId] = (name, args)
                let intent = registry?.get(name)?.presentCall(args)
                    ?? ToolCardIntent(title: name)
                var card = ToolCard(callId: callId, name: name,
                                    title: intent.title,
                                    detail: intent.detail ?? "turn \(turn) · step \(step)",
                                    // 【批2 2B 件5】模型原始参数 JSON 随卡
                                    //（DetailsPanel input 段 argsRaw 语义）。
                                    argsRaw: arguments)
                // 瞬态续接（dsh current map 语义）：liveOutput/statusNote 不在
                // 事件流中，按 callId 从上一投影带入。
                if let previous = previousCards[callId] {
                    card.liveOutput = previous.liveOutput
                    card.statusNote = previous.statusNote
                }
                // 卡 id 锚定 callId（live 与 replay 同 id）——重投影不再整表换
                // 身份，SwiftUI 差分保持卡片视图身份。
                result.append(Bubble(id: "tc-\(callId)", kind: .tool(card)))

            case .toolResult(_, _, let callId, let content, let isError,
                             let errorName, let errorCode, let meta):
                // 收敛同名 running 卡（投影顺序保证先 call 后 result）。
                if let index = result.lastIndex(where: {
                    if case .tool(let card) = $0.kind { return card.callId == callId }
                    return false
                }), case .tool(var card) = result[index].kind {
                    let args = callArgs[callId]?.args ?? .null
                    let output = ToolOutput(text: content, isError: isError,
                                            errorName: errorName, errorCode: errorCode,
                                            meta: meta)
                    if let intent = registry?.get(card.name)?.presentResult(args, output) {
                        card.title = intent.title
                        card.detail = intent.detail
                    }
                    card.resultText = content
                    card.isError = isError
                    // 【批2 2B 件5】结构化失败身份随卡（DetailsPanel
                    // error.name:code 头行语义）。
                    card.errorName = errorName
                    card.errorCode = errorCode
                    card.isRunning = false
                    // 结算态即事件可证状态：审批未通过（NOT_APPROVED）琥珀行；
                    // 其余瞬态行（等待审批/N/M 已回答）让位于 presentResult 复现
                    // 标题（信息在 title/detail 中保留，M3 T1 口径不变）。
                    card.statusNote = (isError && errorCode == "NOT_APPROVED")
                        ? "未获批准" : nil
                    result[index].kind = .tool(card)
                }

            case .turnEnd(let turn, _):
                // 【批2 2B 件4】轮次尾用量 pill 发射（TurnUsagePanel 轮次尾
                // 锚定语义）。零用量轮（无 assistantMessage，如空轮）不发射
                // ——dsh「无数据组缺席」同口径。
                guard var summary = turnUsage[turn],
                      summary.inputTokens > 0 || summary.outputTokens > 0
                else { break }
                if let started = turnStartMs[turn] {
                    summary.runMs = max(0, event.timeMs - started)
                }
                result.append(Bubble(id: "tu-\(turn)", kind: .turnUsage(summary)))

            case .commandRun(_, let name, _):
                result.append(Bubble(id: "cr\(event.seq)", kind: .command(kind: "run", text: name)))

            case .commandDone(_, let kind, let text):
                result.append(Bubble(id: "cd\(event.seq)",
                                     kind: .command(kind: kind, text: text ?? "")))

            case .compactionSummary(let compactionId, _, _, _, _, _):
                result.append(Bubble(id: "cs\(event.seq)",
                                     kind: .note("上下文已压缩（\(compactionId.prefix(8))）")))

            case .extensionEvent(let kind, let payload):
                // E1：log-only 默认不渲染（未注册 kind 同为 log-only——消费侧
                // 跳过口径，v2.4 修订①）。model-visible 注册项以 note 气泡
                // 呈现（机制位；首个 model-visible 业务事件可按需升级专属视图）。
                guard ExtensionEventRegistry.shared.projectionRule(for: kind) == .modelVisible
                else { break }
                result.append(Bubble(id: "x\(event.seq)",
                                     kind: .note("扩展事件 \(kind)："
                                         + Self.extensionPayloadSummary(payload))))

            default:
                break
            }
        }
        return result
    }

    /// extension payload 单行摘要（紧凑 JSON，拍平换行、截 80 字符）。
    private static func extensionPayloadSummary(_ payload: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "{}" }
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
        return text.count <= 80 ? text : String(text.prefix(80)) + "…"
    }

    // MARK: 批2 2B 件3：轮次过程折叠投影（TurnProcessNodeView.tsx:7-60）

    /// 折叠摘要组（turn-process 节点）。
    struct TurnProcessGroup: Equatable {
        let id: String
        var toolCallCount = 0
        /// 中间消息计数（WanWo 词汇 = reasoning 块；dsh messageCount 同位）。
        var messageCount = 0
        /// 子代理计数——WanWo 事件词汇无 subagent 事件，恒 0（标签缺席，
        /// dsh count>0 才 push 的语义同形；已核实登记报告）。
        var subagentCount = 0
        /// 折叠成员（展开态原样渲染）。
        var bubbles: [Bubble] = []
    }

    /// 展示节点 = 平铺气泡 | 折叠组（视图层消费；bubbles 本体保持平铺——
    /// ChatViewModel setCardStatus/toolCards 续接面不动）。
    enum DisplayNode: Identifiable, Equatable {
        case plain(Bubble)
        case process(TurnProcessGroup)

        var id: String {
            switch self {
            case .plain(let bubble): return bubble.id
            case .process(let group): return group.id
            }
        }
    }

    /// 气泡流 → 展示节点流（纯函数；锚点 TurnProcessNodeView.tsx:7-60 +
    /// 派单简报 2B 件3）。规则：极大连续 tool/reasoning 游程折叠为摘要行；
    /// 游程 ≥2 才折叠（单工具卡保持平铺——万我工具卡自带完成收敛态，单卡
    /// 再折叠徒增一次点按；偏差登记报告）。摘要文案在视图层组表
    /// （TurnProcessRowView），本函数只产计数。
    static func foldTurnProcess(_ bubbles: [Bubble]) -> [DisplayNode] {
        var out: [DisplayNode] = []
        var run: [Bubble] = []
        func flush() {
            guard run.count >= 2 else {
                out.append(contentsOf: run.map(DisplayNode.plain))
                run.removeAll()
                return
            }
            var group = TurnProcessGroup(id: "tp-\(run.first!.id)")
            for bubble in run {
                switch bubble.kind {
                case .tool: group.toolCallCount += 1
                case .reasoning: group.messageCount += 1
                default: break
                }
            }
            group.bubbles = run
            out.append(.process(group))
            run.removeAll()
        }
        for bubble in bubbles {
            switch bubble.kind {
            case .tool, .reasoning:
                run.append(bubble)
            default:
                flush()
                out.append(.plain(bubble))
            }
        }
        flush()
        return out
    }

    // MARK: 批2 2B 件5：DetailsPanel 对齐（pretty JSON 纯函数）

    /// 参数 JSON pretty 化（DetailsPanel.tsx:32-38 pretty 同语义：可解析则
    /// 2 空格缩进重排，不可解析原样返回——模型原始 arguments 非法 JSON 时
    /// 兜底直呈）。
    static func prettyJSON(_ raw: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return raw }
        return text
    }
}
