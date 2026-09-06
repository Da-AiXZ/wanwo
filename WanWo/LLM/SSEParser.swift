//
//  SSEParser.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/llm/llm-deepseek/src/sse.ts。
//  dsh 用 eventsource-parser 做帧装配（spec-strict：空行终止才 dispatch，
//  注释行只作传输活动脉冲，多 data: 行以 \n 连接，BOM/CRLF 归一）；
//  Swift 侧语义等价重写：AsyncLineSequence 已按行拆分（含 \r\n），
//  这里只做 data: 装配。EOF 前未见 [DONE] 由调用方抛 STREAM_CLOSED。
//

import Foundation

/// SSE 装配结果。
enum SSEConsumeResult: Equatable {
    /// 一个完整的 event data 载荷（多 data: 行已合并）。
    case payload(String)
    /// 注释行等传输活动（仅作空闲看门狗 pulse，不进入载荷流）。
    case activity
    /// 该行不产生任何结果（空行但无待发载荷等）。
    case none
}

/// SSE 行 → data 载荷装配器（有状态；每个流一份）。
struct SSEAssembler {
    private var pendingDataLines: [String] = []

    mutating func consume(line rawLine: String) -> SSEConsumeResult {
        var line = rawLine
        // BOM（dsh：UTF-8/CRLF/BOM 处理交给帧层；行序列已去 \r\n，这里去 BOM）
        if line.hasPrefix("\u{FEFF}") {
            line.removeFirst()
        }
        // 注释行：仅活动脉冲
        if line.hasPrefix(":") {
            return .activity
        }
        if line.isEmpty {
            // 空行 = dispatch 终止符
            guard !pendingDataLines.isEmpty else { return .none }
            let payload = pendingDataLines.joined(separator: "\n")
            pendingDataLines.removeAll()
            return .payload(payload)
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst("data:".count))
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
            pendingDataLines.append(value)
            return .none
        }
        // event:/id:/retry: 及其他字段：跳过（M1 不需要 event 类型区分）
        return .none
    }
}

/// OpenAI 兼容流的终止载荷（dsh sse.ts DONE）。
enum SSE {
    static let done = "[DONE]"
}
