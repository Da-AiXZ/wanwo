//
//  ToolSearchActivation.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs core/src/models.rs:845/:1060/:1136（激活 =
//  协议级 tool_search_call/tool_search_output 项进对话历史，append-only 随历史
//  持久化，resume 回放自然恢复）。WanWo 等价物（平台差异最大环，gap11 §八.2
//  已批判定）：chat completions 无此协议项 → 激活 = 命中 spec 注入下一请求
//  tools 数组（M4-C5）。
//  激活集推导（C5 拍板项 1A = 事件流重放推导）：
//    a. 扫事件流中 name=="tool_search" 的 .toolCall 及配对 .toolResult → 解析
//       result 文本（C1 输出 = function spec object 的 JSON 数组文本）→ 提取
//       {name, description, parameters} 并入激活集；
//    b. 按工具名幂等去重（同名重复激活不重复注入；保留首见 spec——append-only
//       语义，codex 协议项随历史恒存的 WanWo 等价）；
//    c. 注入形态：请求 tools 数组 = registry.schemas() 组装产物（Direct 集，
//       toolOrder 排序原样透传不重排）+ 激活集（首见序追加尾部、激活集内不重排
//       ——前缀缓存 append-only 纪律，拍板项 5 落地）；
//    d. model-visible=logged 不变量：注入内容全部来源于已落盘的 toolResult ✓；
//    e. resume/replay 免费恢复：推导为纯函数消费 writer.events（SessionWriter
//       init 即 JSONL replay 全量快照），resume 后首个 runStep 自动重推导——
//       零新存储、零新事件词汇（R2）、零 resume 接入点（最小改动面裁决：无需
//       单独的 seed 重建钩子，逐步推导即逐步收敛的 resume 等价）。
//  容错（fail closed）：result 文本非 JSON / 非 JSON 数组 / 条目缺 name 或
//  description 或 parameters 非 object → 跳过该条（整段 result 解析失败跳过该
//  段），绝不崩 replay、绝不抛穿 loop（§十三.2）。
//  平台差异登记：
//    · codex 激活项是协议项（模型上下文显式可见）→ WanWo 激活只进 tools 数组
//      （模型经 function schema 感知），无对话历史协议项；
//    · 激活 spec 不校验 registry 在位性（model-visible=logged 优先：历史上
//      激活过的工具即便 MCP 世代换手后离场仍注入；调用落空由 ToolPipeline
//      UNKNOWN_TOOL 合成失败路径 fail closed 承载）；
//    · 已知截断源（登记不处理）：tool_search 输出 >50KB 触发 F037 spill 替换、
//      RepeatCallAdviser advisory 后缀——两者都会破坏 JSON 数组完整性，按本件
//      容错语义整段跳过（激活缺失 fail closed，不误注入残缺 spec）。
//

import Foundation

/// tool_search 激活面（M4-C5）。纯函数推导：无状态、无锁、线程安全——
/// 每步组装前由 AgentLoop.runStep 消费 writer.events 快照调用。
enum ToolSearchActivation {

    private static let logger = AppLogger(category: "ToolSearchActivation")

    /// tool_search 元工具名（与 ToolSearchTool.name 同源锚——激活推导只认本名
    /// 的 tool/call+tool/result 事件对）。
    static let toolSearchName = "tool_search"

    // MARK: - 注入形态（C5c）

    /// 请求 tools 数组组装：Direct 集（调用方 PromptAssembler 产物，原样透传
    /// ——不与激活集重排）+ 激活集（首见序追加尾部）。零激活 = 原样返回
    /// （零开销跳过；侧会话 hidden 不进语料 ⇒ 无 tool_search 调用 ⇒ 恒走本分支）。
    static func inject(into direct: [ToolSchemaEntry],
                       events: [SessionEvent]) -> [ToolSchemaEntry] {
        let activated = activatedSpecs(events: events,
                                       excluding: Set(direct.map { $0.name }))
        guard !activated.isEmpty else { return direct }
        return direct + activated
    }

    // MARK: - 激活集推导（C5a/b）

    /// 从事件流派生激活集：tool_search 的成功 result 文本 → spec 列表，按名
    /// 幂等去重（首见 spec 保留），首见序输出。
    /// - Parameters:
    ///   - events: 已落盘事件快照（writer.events；model-visible=logged 数据源）。
    ///   - excluding: 不注入的名字集（调用方传 Direct 集名——同名冲突时
    ///     Direct 在位者胜，防止 tools 数组重名破坏 chat completions 协议）。
    static func activatedSpecs(events: [SessionEvent],
                               excluding: Set<String> = []) -> [ToolSchemaEntry] {
        // a①: 收集 tool_search 调用的 callId（配对面）。
        var searchCallIds = Set<String>()
        for event in events {
            if case .toolCall(_, _, let callId, let name, _) = event.payload,
               name == Self.toolSearchName {
                searchCallIds.insert(callId)
            }
        }
        guard !searchCallIds.isEmpty else { return [] }

        // a②: 逐条消费配对 result（append-only 事件流按 seq 顺序扫描——
        //      首见序 = 事件流时间序）；isError result（INVALID_ARGS 等合成
        //      失败）不进语料。压缩只影子化不删除（shadowedSeqs 仅派生历史
        //      折叠面），原始事件恒在 → 激活集永不收缩（append-only 铁律）。
        var byName: [String: ToolSchemaEntry] = [:]
        var firstSeenOrder: [String] = []
        for event in events {
            guard case .toolResult(_, _, let callId, let content, let isError,
                                   _, _, _) = event.payload,
                  searchCallIds.contains(callId),
                  !isError else { continue }
            for spec in Self.parseSpecs(fromText: content) {
                if byName[spec.name] == nil {
                    byName[spec.name] = spec
                    firstSeenOrder.append(spec.name)
                }
            }
        }
        // b: 幂等去重已完成（首见保留）；excluding 过滤在输出面（激活集
        //    本身保持全集形态——Direct 集变化时无需重扫事件流）。
        return firstSeenOrder.compactMap { name in
            excluding.contains(name) ? nil : byName[name]
        }
    }

    // MARK: - C1 输出文本 → spec 解析（容错面）

    /// 解析 tool_search result 文本为 spec 列表（C1 输出 = function spec
    /// object 的 JSON 数组文本，ToolSearchTool.renderOutput 产物）。
    /// 逐条 fail closed：非 JSON / 非数组 → 空列表；条目缺 name（或空）/缺
    /// description / parameters 非 object → 跳过该条。永不抛。
    static func parseSpecs(fromText text: String) -> [ToolSchemaEntry] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let items = value.arrayItems else {
            return []
        }
        var specs: [ToolSchemaEntry] = []
        for item in items {
            guard let fields = item.objectFields,
                  let name = fields["name"]?.stringValue,
                  !name.isEmpty,
                  let description = fields["description"]?.stringValue,
                  let parameters = fields["parameters"]?.objectFields else {
                Self.logger.info("tool_search activation: skipping malformed spec entry")
                continue
            }
            specs.append(ToolSchemaEntry(name: name, description: description,
                                         parameters: .object(parameters)))
        }
        return specs
    }
}
