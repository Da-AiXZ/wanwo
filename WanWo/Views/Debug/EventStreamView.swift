//
//  EventStreamView.swift
//  WanWo
//
//  【最小移植自 dsh ui-trajectory（09 #19）+ F060 M8.2 前置】出处：
//    - dsh packages/client/ui-trajectory（TrajectoryTable/TrajectoryCell/Timeline：
//      按时间线逐事件呈现、类型可辨（分类着色 + 图标）、载荷单行摘要截断；
//      M2.8 只移植「事件流表」最小面，不做 span 树/成本核算/过滤检索/实时订阅）
//  M2.8 范围（只读诊断页）：
//    - 数据源 = SessionLogScanner.scan（SessionStore/JsonlEventLog 的同一 replay
//      扫描器；reconcileIndex 的只读同款路径）。纯 Data 读取，不开任何可写句柄、
//      不写任何事件/文件（JsonlEventLog.open 读模式也会开写柄做 inode 校验，
//      此处刻意不走它，做到字面意义的只读）。
//    - 手动刷新全量 replay；List 惰性渲染 + 摘要预投影（长会话几千条不卡）。
//  M2.9 显示层聚合 + 剪贴板导出（数据层/JSONL 落盘零动）：
//    - chunk 聚合（语义出处：dsh apps/web ui-trajectory，09 #19 口径）：
//      相邻且同属一个块生命周期（block-start → deltas → block-end，或未配对
//      delta 按 块 index/类型 变化切组）的 assistant/chunk 事件合并为一行：
//      `assistant/chunk · reasoning · 47 段增量 · 1024 字符 · "首 30…尾 30"`；
//      usage/finish chunk 与 turn/step/user/tool/compaction 等其他事件行不变；
//      合并行 seq/时间取块生命周期首事件（原事件时间范围口径）。
//      页面顶部同时显示原始事件总数与聚合后行数，量级一眼可见。
//    - 剪贴板导出：工具栏「复制日志」把当前会话 .jsonl 全文（UTF-8 文本）
//      复制到 UIPasteboard.general.string；超 2MB 截断复制并提示用导出文件
//      取全文。与 ShareLink 并存（Files App 取 WanWo-Exports 文件本体亦有效）。
//      复制动作纯读文件，不产生任何事件。
//  ERR-025② 取证复制（独立的「复制取证」按钮，与「复制日志」分开）：
//    AgentLoop.logCacheForensics 的相邻请求逐项指纹对比输出进内存环形缓冲
//    （CacheForensicsBuffer，纯内存不落盘事件——事件词汇零新增），按钮整段
//    复制到剪贴板。与「复制日志」分开的原因：取证数据不在 .jsonl 事件流里
//    （os_log + 内存缓冲），语义、数据源、生命周期（App 进程内）均不同。
//  M2.8 排障增量（turn/end error 行显示 provider 抱怨原文 + 一键导出）：
//    - 错误态行（turn/end error、llm/retry、finish error）摘要追加
//      failure.message（截 300）与 causeText（provider 错误体原文，截 300）——
//      DeepSeek 400 的原始抱怨全文只在 causeText 里，不显示 = 排障不闭环（F060）。
//    - 工具栏 ShareLink 分享当前会话 .jsonl 原文件 = 设计 F070 会话导出的
//      最小前置形态（M9.3 ZIP 完整版之前）：复制到临时目录直分享原始日志，
//      不脱敏不加工（文件内无 API key，key 在 Keychain）。源文件只读；
//      导出副本写 Documents/WanWo-Exports/（Files App 可见），不触碰事件流。
//    - M8.2 再升级：span 树 / 成本 / 过滤检索 / 实时订阅（本文件刻意不含）。
//

import SwiftUI
import UIKit   // UIPasteboard（M2.9 剪贴板导出）

// MARK: - 只读加载器

/// 事件流只读加载器：SessionLogScanner 同款 replay，纯 Data 读取、零写句柄。
/// （出处：SessionStore.reconcileIndex 的只读扫描路径——M1 交付物零改动复用。
///  无状态 enum、静态方法默认 nonisolated，可安全放后台任务执行。）
enum EventStreamLoader {
    /// 一次全量 replay 投影的输出（Sendable，跨并发域回传）。
    struct Output: Sendable {
        var sessionID: String
        var createdAtMs: Int64
        var rows: [EventStreamRow]
        /// M2.9：原始事件总数（与聚合后行数对照显示）。
        var rawEventCount: Int
        /// 非致命扫描残记（torn tail 等；中部损坏走 failure）。
        var issue: String?
    }

    enum LoadError: Error, Equatable {
        case invalidSessionID(String)
        case logNotFound(String)
        case unreadable(String)
    }

    /// 全量 replay + 行投影（CPU 密集，调用方放后台任务）。
    static func loadAndProject(sessionID: String) -> Result<Output, LoadError> {
        do {
            // id 路径安全校验（与 SessionStore.fileURL 同口径，fail closed）。
            guard !sessionID.isEmpty,
                  sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else {
                return .failure(.invalidSessionID(sessionID))
            }
            let url = WanWoPaths.persistentBase
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.logNotFound(sessionID))
            }
            guard let data = try? Data(contentsOf: url) else {
                return .failure(.unreadable(sessionID))
            }
            let scan = try SessionLogScanner.scan(data: data)
            // 摘要字符串在本任务内一次建成，行渲染只拼现成字段（长会话惰性不卡的关键）。
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss.SSS"
            // M2.9 显示层聚合：块生命周期内相邻 assistant/chunk 合并为一行，其余原样。
            let rows = EventStreamAggregator.buildRows(events: scan.events,
                                                       timeFormatter: timeFormatter)
            let output = Output(sessionID: scan.header.id,
                                createdAtMs: scan.header.createdAtMs,
                                rows: rows,
                                rawEventCount: scan.events.count,
                                issue: scan.issue)
            return .success(output)
        } catch let error as SessionLogError {
            return .failure(.unreadable("\(error)"))
        } catch {
            return .failure(.unreadable("\(error)"))
        }
    }

    /// F070 会话导出的最小前置形态（M9.3 ZIP 完整版之前）：
    /// 把当前会话 .jsonl 原文件复制到临时目录（原样字节、不脱敏不加工），
    /// 供工具栏 ShareLink 直分享（存 Files / 隔空投送 / 发给自己）。
    /// 文件名带会话 id 前 8 位 + 时间戳，便于用户回传定位。
    /// 只读源文件 + 写 Documents/WanWo-Exports/ 副本；不触碰事件流、不产生任何事件。
    /// - Returns: 副本 URL；会话不存在或复制失败返回 nil（UI 隐藏分享入口）。
    static func makeExportCopy(sessionID: String) -> URL? {
        // id 路径安全校验（与 loadAndProject 同口径，fail closed）。
        guard !sessionID.isEmpty,
              sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            return nil
        }
        let source = WanWoPaths.persistentBase
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        guard FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        let idPrefix = String(sessionID.prefix(8))
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let fileName = "wanwo-\(idPrefix)-\(stamp.string(from: Date())).jsonl"
        // 副本写 Documents/WanWo-Exports/（用户 Files App 可见——tmp 目录经部分
        // 分享途径会被系统包装成 bookmark plist，用户拿到的是引用而非文件本体）。
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let exportDir = docs.appendingPathComponent("WanWo-Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let destination = exportDir.appendingPathComponent(fileName)
        // 同名残留先清（同分钟内二次导出覆盖旧副本）。
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// M2.9 剪贴板导出上限（2MB）：超过则截断复制，UI 提示用导出文件取全文。
    static let clipboardLimitBytes = 2 * 1_048_576

    /// M2.9 剪贴板导出的只读读取：当前会话 .jsonl 全文（UTF-8 文本）。
    /// 纯读文件，不写任何句柄/事件；超 2MB 取前 2MB。
    /// - Returns: (剪贴板文本, 文件全文字节数)；会话不存在或读取失败返回 nil。
    static func readLogText(sessionID: String) -> (text: String, fullByteCount: Int)? {
        // id 路径安全校验（与 loadAndProject 同口径，fail closed）。
        guard !sessionID.isEmpty,
              sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else {
            return nil
        }
        let url = WanWoPaths.persistentBase
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let fullByteCount = data.count
        let clipped = data.count > clipboardLimitBytes
            ? data.prefix(clipboardLimitBytes)
            : data[...]
        // 容错解码：截断点可能落在多字节 UTF-8 字符中间，lossy 替换而非失败。
        let text = String(decoding: clipped, as: UTF8.self)
        return (text, fullByteCount)
    }
}

// MARK: - chunk 聚合（M2.9 显示层）

/// assistant/chunk 显示层聚合（语义出处：dsh apps/web ui-trajectory，09 #19 口径）。
/// 数据层零动：只改诊断页行投影——相邻且同属一个块生命周期的 chunk 事件合并为一行。
/// 块生命周期边界信号：block-start / block-end 事件，或 delta 内 块 index/类型 变化。
private enum EventStreamAggregator {

    /// 一个待合并的块生命周期（block-start 起或首个未配对 delta 起，
    /// 至 block-end / 块 index·类型 变化 / 非块事件止）。
    private struct PendingGroup {
        let index: Int
        let kind: String                       // 显示名：reasoning / text / tool-call(name)
        var deltaCount = 0                     // 增量段数（仅 delta 类 chunk 计入）
        var text = ""                          // 累积正文（tool-call 块为参数 JSON 增量拼接）
        let firstEvent: SessionEvent           // 行 seq/时间取块生命周期首事件
    }

    /// 全事件流 → 聚合后行序列（其余事件行逐条原样）。
    static func buildRows(events: [SessionEvent], timeFormatter: DateFormatter) -> [EventStreamRow] {
        var rows: [EventStreamRow] = []
        rows.reserveCapacity(events.count)
        var pending: PendingGroup?

        // 落袋当前组为一行（合并行）；无组为空操作。
        func flush() {
            guard let group = pending else { return }
            pending = nil
            rows.append(mergedRow(from: group, timeFormatter: timeFormatter))
        }

        for event in events {
            guard case .assistantChunk(_, _, let chunk) = event.payload else {
                // turn/step/user/tool/compaction 等：先封组，再原样成行。
                flush()
                rows.append(EventStreamRowBuilder.build(event: event, timeFormatter: timeFormatter))
                continue
            }
            switch chunk {
            case .blockStart(let index, let blockType):
                flush()
                pending = PendingGroup(index: index, kind: blockType, firstEvent: event)
            case .textDelta(let index, let text):
                if var group = pending, group.index == index, group.kind == "text" {
                    group.deltaCount += 1
                    group.text += text
                    pending = group
                } else {
                    // 无 block-start 的未配对 delta，或块 index/类型变化：切新组。
                    flush()
                    pending = PendingGroup(index: index, kind: "text",
                                           deltaCount: 1, text: text, firstEvent: event)
                }
            case .reasoningDelta(let index, let text):
                if var group = pending, group.index == index, group.kind == "reasoning" {
                    group.deltaCount += 1
                    group.text += text
                    pending = group
                } else {
                    flush()
                    pending = PendingGroup(index: index, kind: "reasoning",
                                           deltaCount: 1, text: text, firstEvent: event)
                }
            case .toolCallDelta(let index, _, let name, let argumentsDelta):
                if var group = pending, group.index == index, group.kind.hasPrefix("tool-call") {
                    group.deltaCount += 1
                    group.text += argumentsDelta
                    pending = group
                } else {
                    flush()
                    pending = PendingGroup(index: index, kind: "tool-call(\(name ?? "?"))",
                                           deltaCount: 1, text: argumentsDelta, firstEvent: event)
                }
            case .blockEnd(let index, _):
                // 闭合同 id 块生命周期：block-end 并入该组（不额外成行）。
                if let group = pending, group.index == index {
                    pending = nil
                    rows.append(mergedRow(from: group, timeFormatter: timeFormatter))
                } else {
                    // 未配对的 block-end：封组后原样成行（torn tail 兜底）。
                    flush()
                    rows.append(EventStreamRowBuilder.build(event: event, timeFormatter: timeFormatter))
                }
            case .usage, .finish:
                // 非块生命周期 chunk：不合并，各自成行（finish error 红显在行构建器）。
                flush()
                rows.append(EventStreamRowBuilder.build(event: event, timeFormatter: timeFormatter))
            }
        }
        // 尾部未闭合（torn tail / 中断）：把残余组落为一行。
        flush()
        return rows
    }

    /// 合并行摘要：`reasoning · 47 段增量 · 1024 字符 · "首 30…尾 30"`。
    /// seq/时间取块生命周期首事件（原事件时间范围口径）；assistant 紫色分类不变。
    private static func mergedRow(from group: PendingGroup,
                                  timeFormatter: DateFormatter) -> EventStreamRow {
        let excerpt = excerptMiddle(group.text, limit: 30)
        var summary = "\(group.kind) · \(group.deltaCount) 段增量 · \(group.text.count) 字符"
        if !excerpt.isEmpty {
            summary += " · \"\(excerpt)\""
        }
        let category = EventStreamCategory.classify(wireType: "assistant/chunk")
        return EventStreamRow(id: group.firstEvent.seq,
                              seq: group.firstEvent.seq,
                              timeText: timeFormatter.string(from: Date(timeIntervalSince1970:
                                  TimeInterval(group.firstEvent.timeMs) / 1000.0)),
                              wireType: "assistant/chunk",
                              iconName: category.iconName,
                              tint: category.tint,
                              summary: summary,
                              isAlert: false)
    }

    /// 首 30 + 尾 30 摘录（换行折叠为空格；全文 ≤ 2×limit 时原样返回）。
    private static func excerptMiddle(_ text: String, limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > limit * 2 else { return flattened }
        let head = String(flattened.prefix(limit))
        let tail = String(flattened.suffix(limit))
        return head + "…" + tail
    }
}

// MARK: - 行模型

/// 事件流一行（dsh TrajectoryCell 最小面：seq · 类型标 · 摘要 · 时间）。
/// 字段在 replay 投影期一次算好，行视图零计算（几千条 List 惰性渲染不卡）。
struct EventStreamRow: Identifiable, Sendable {
    let id: Int          // = seq
    let seq: Int
    let timeText: String
    let wireType: String
    let iconName: String
    let tint: Color
    let summary: String
    /// 错误态行（tool/result isError、turn/end error、compaction/end error）红色醒目。
    let isAlert: Bool
}

/// 分类着色（照 dsh 轨迹视图 tagSystem/tagUser/tagMessage/tagTool 的分类着色思路，
/// 素净色板）：user 绿 / assistant 紫 / tool 橙 / 结构蓝 / 压缩青 / 控制灰 / 重试与错误红。
private enum EventStreamCategory {
    case user, assistant, tool, structure, compaction, control, retry

    var tint: Color {
        switch self {
        case .user: return .green
        case .assistant: return .purple
        case .tool: return .orange
        case .structure: return .blue
        case .compaction: return .teal
        case .control: return .gray
        case .retry: return .red
        }
    }

    var iconName: String {
        switch self {
        case .user: return "person"
        case .assistant: return "text.bubble"
        case .tool: return "wrench"
        case .structure: return "arrow.right.circle"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .control: return "info.circle"
        case .retry: return "arrow.triangle.2.circlepath"
        }
    }

    static func classify(wireType: String) -> EventStreamCategory {
        if wireType.hasPrefix("user/") { return .user }
        if wireType.hasPrefix("assistant/") { return .assistant }
        if wireType.hasPrefix("tool/") { return .tool }
        if wireType.hasPrefix("turn/") || wireType.hasPrefix("step/") { return .structure }
        if wireType.hasPrefix("compaction/") { return .compaction }
        if wireType.hasPrefix("llm/retry") { return .retry }
        return .control   // request/header、command/*、approval/*、system、session/title、ignored
    }
}

// MARK: - 摘要投影（dsh trajectory-event-projection 的最小面）

/// SessionEvent 载荷 → 单行摘要字符串（载荷前缀截断口径照规格：
/// user 60 字、tool/call 工具名+参数 80 字、assistant/message 正文 60 字+usage）。
private enum EventStreamRowBuilder {

    static func build(event: SessionEvent, timeFormatter: DateFormatter) -> EventStreamRow {
        let wireType = event.wireType
        let category = EventStreamCategory.classify(wireType: wireType)
        let (summary, isAlert) = summarize(event)
        return EventStreamRow(id: event.seq,
                              seq: event.seq,
                              timeText: timeFormatter.string(from: Date(timeIntervalSince1970:
                                  TimeInterval(event.timeMs) / 1000.0)),
                              wireType: wireType,
                              iconName: category.iconName,
                              tint: category.tint,
                              summary: summary,
                              isAlert: isAlert)
    }

    /// - Returns: (单行摘要, 是否错误态行)
    private static func summarize(_ event: SessionEvent) -> (String, Bool) {
        switch event.payload {
        case .turnStart(let turn):
            return ("turn \(turn)", false)
        case .turnEnd(let turn, let reason):
            var text = "turn \(turn) · \(turnReasonText(reason))"
            // 排障闭环：错误结局追加 provider 抱怨原文（message + 错误体 causeText）。
            if case .error(let failure) = reason {
                text += " · " + failureDetail(failure)
            }
            return (text, isTurnEndError(reason))
        case .stepStart(let turn, let step):
            return ("turn \(turn) · step \(step)", false)
        case .stepEnd(let turn, let step):
            return ("turn \(turn) · step \(step)", false)
        case .userMessage(let text):
            return (prefix(text, 60), false)
        case .assistantChunk(_, _, let chunk):
            return (chunkSummary(chunk), false)
        case .assistantMessage(_, _, let message, let usage, let interrupted):
            var parts: [String] = []
            if let body = firstText(message) {
                parts.append(prefix(body, 60))
            }
            if let usage {
                parts.append("in \(usage.inputTokens) out \(usage.outputTokens)")
            }
            if interrupted {
                parts.append("interrupted")
            }
            return (parts.joined(separator: " · "), false)
        case .requestHeader(let header, let reason):
            return ("\(header.config.model) · \(reason)", false)
        case .llmRetry(_, _, _, let provider, let mode, _, let retry, let maxRetries,
                       let delayMs, let failure):
            let maxText = maxRetries.map(String.init) ?? "-"
            return ("\(provider)/\(mode) retry \(retry)/\(maxText) "
                    + "wait \(delayMs)ms · \(failure.code) · "
                    + failureDetail(failure), true)
        case .llmRetryStarted(_, _, _, let retry):
            return ("retry \(retry) 重发请求", false)
        case .sessionTitle(let title, _):
            return (prefix(title, 60), false)
        case .system(let note):
            return (prefix(note, 80), false)
        case .toolCall(_, _, let callId, let name, let arguments):
            return ("\(name) args: \(prefix(arguments, 80)) · call \(callId)", false)
        case .toolResult(_, _, let callId, let content, let isError,
                         let errorName, let errorCode, _):
            var parts: [String] = [prefix(content, 60)]
            if let errorName, let errorCode {
                parts.append("\(errorName)/\(errorCode)")
            }
            parts.append("call \(callId)")
            return (parts.joined(separator: " · "), isError)
        case .compactionStart(let compactionId, let turn):
            return ("\(compactionId) · turn \(turn.map(String.init) ?? "回合外")", false)
        case .compactionSummary(let compactionId, let summary, let rangeStart,
                                let rangeEnd, let seqs, let tokens):
            // 替换范围 = 影子区间 + 被替换事件数 + 影子定价（规格：替换范围必显）。
            return ("\(compactionId) 替换 [\(rangeStart)…\(rangeEnd)] "
                    + "\(seqs.count) 事件 \(tokens) tok · \(prefix(summary, 40))", false)
        case .compactionEnd(let compactionId, _, let error):
            return ("\(compactionId) · \(error ?? "完成")", error != nil)
        case .compactionPrune(let seqs, let tokens):
            return ("prune \(seqs.count) 事件 \(tokens) tok", false)
        case .commandRun(_, let name, let args):
            return ("/\(name) \(args ?? "")", false)
        case .commandDone(_, let kind, let text):
            return ("[\(kind)] \(prefix(text ?? "-", 40))", kind != "success")
        case .approvalAsked(_, let tool, let reason):
            return ("\(tool) · \(reason ?? "-")", false)
        case .approvalDecided(_, let verdict):
            return (verdict, false)
        case .extensionEvent(let kind, let payload):
            // E1：扩展事件透传记录（kind + 载荷单行摘要；控制灰分类复用）。
            return ("\(kind) · \(prefix(extensionPayloadText(payload), 80))", false)
        case .ignored(let kind):
            return ("外来事件透传 · \(kind)", false)
        }
    }

    /// extension payload 紧凑 JSON 文本（编码失败按 "{}" 兜底——诊断页不抛）。
    private static func extensionPayloadText(_ payload: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "{}" }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
    }

    private static func turnReasonText(_ reason: TurnEndReason) -> String {
        switch reason {
        case .completed: return "completed"
        case .aborted(let cause): return "aborted(\(cause))"
        case .blocked: return "blocked"
        case .error(let failure): return "error \(failure.code)"
        case .maxTokens: return "max-tokens"
        case .interrupted: return "interrupted"
        }
    }

    /// 错误原文段（排障闭环 F060）：message 原文截 300 + status +
    /// causeText（provider 错误体原文，DeepSeek 400 的完整 body 在此）截 300。
    private static func failureDetail(_ failure: LlmFailure) -> String {
        var parts = [prefix(failure.message, 300)]
        if let status = failure.status {
            parts.append("HTTP \(status)")
        }
        if let cause = failure.causeText, !cause.isEmpty {
            parts.append("body: \(prefix(cause, 300))")
        }
        return parts.joined(separator: " · ")
    }

    private static func isTurnEndError(_ reason: TurnEndReason) -> Bool {
        if case .error = reason { return true }
        return false
    }

    private static func chunkSummary(_ chunk: StreamChunk) -> String {
        switch chunk {
        case .blockStart(let index, let blockType):
            return "block-start #\(index) \(blockType)"
        case .textDelta(_, let text):
            return "text: \(prefix(text, 60))"
        case .reasoningDelta(_, let text):
            return "thinking: \(prefix(text, 60))"
        case .toolCallDelta(_, let id, let name, let argumentsDelta):
            return "toolΔ \(name ?? id): \(prefix(argumentsDelta, 60))"
        case .blockEnd(let index, let block):
            let kind: String
            switch block {
            case .text: kind = "text"
            case .reasoning: kind = "reasoning"
            case .toolCall(_, let name, _): kind = "tool-call(\(name))"
            }
            return "block-end #\(index) \(kind)"
        case .usage(let usage):
            return "usage in \(usage.inputTokens) out \(usage.outputTokens)"
        case .finish(let reason):
            switch reason {
            case .stop: return "finish stop"
            case .toolCalls: return "finish tool-calls"
            case .maxTokens: return "finish max-tokens"
            case .error(let failure):
                return "finish error \(failure.code) · \(failureDetail(failure))"
            }
        }
    }

    /// 第一个 text/reasoning 块正文（assistant/message 摘要用）。
    private static func firstText(_ message: AssistantMessage) -> String? {
        for block in message.content {
            switch block {
            case .text(let text), .reasoning(let text):
                return text
            case .toolCall:
                continue
            }
        }
        return nil
    }

    /// 单行截断：前 `limit` 个字符 + 省略号（新行折叠为空格保证单行）。
    private static func prefix(_ text: String, _ limit: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        if flattened.count <= limit {
            return flattened
        }
        let head = String(flattened.prefix(limit))
        return head + "…"
    }
}

// MARK: - ViewModel

/// 事件流诊断页模型：会话选择 + 手动全量 replay（只读；无实时订阅，M8.2 升级）。
@MainActor
final class EventStreamViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var selectedSessionID: String?
    @Published private(set) var rows: [EventStreamRow] = []
    /// 原始事件总数（replay 全量；M2.9 与聚合后行数对照显示）。
    @Published private(set) var rawEventCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var scanIssue: String?
    @Published private(set) var lastLoadedAt: Date?
    /// F070 最小前置：当前会话 .jsonl 临时副本（ShareLink 分享用；nil = 无可分享文件）。
    @Published private(set) var exportFileURL: URL?
    /// M2.9 复制/加载结果提示（toast 文案；nil = 不显示，2.5s 自动消失）。
    @Published private(set) var toastMessage: String?

    private var toastTask: Task<Void, Never>?
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// 进入页面：拉会话列表（默认选最近一个）+ 首次 replay。
    func onAppear() async {
        await reloadSessions()
        await loadEvents()
    }

    /// 重拉会话列表；当前选择已失效（被删）则落回最近一个。
    func reloadSessions() async {
        sessions = await environment.loadSessions()
        if let selected = selectedSessionID,
           sessions.contains(where: { $0.id == selected }) {
            return
        }
        selectedSessionID = sessions.first?.id
    }

    /// 手动刷新：全量 replay + 聚合投影（扫描/聚合放后台，主线程只收结果）。
    func loadEvents() async {
        guard let id = selectedSessionID else {
            rows = []
            rawEventCount = 0
            errorMessage = sessions.isEmpty ? "暂无会话" : nil
            scanIssue = nil
            exportFileURL = nil
            lastLoadedAt = Date()
            return
        }
        isLoading = true
        defer { isLoading = false }
        let result = await Task.detached(priority: .userInitiated) {
            EventStreamLoader.loadAndProject(sessionID: id)
        }.value
        switch result {
        case .success(let output):
            rows = output.rows
            rawEventCount = output.rawEventCount
            scanIssue = output.issue
            errorMessage = nil
            // 导出副本（F070 最小前置）：只读源文件 + Documents 副本，随刷新同步更新。
            exportFileURL = await Task.detached(priority: .utility) {
                EventStreamLoader.makeExportCopy(sessionID: id)
            }.value
        case .failure(let error):
            rows = []
            rawEventCount = 0
            scanIssue = nil
            errorMessage = "读取失败：\(error)"
            exportFileURL = nil
        }
        lastLoadedAt = Date()
    }

    /// M2.9 剪贴板导出：当前会话 .jsonl 全文（UTF-8 文本）复制到系统剪贴板。
    /// 纯读文件，不产生任何事件；超 2MB 截断复制并提示用导出文件取全文。
    /// （UIPasteboard 仅主线程访问：读文件放后台，落剪贴板在 MainActor。）
    func copyLogToClipboard() async {
        guard let id = selectedSessionID, !isLoading else { return }
        let outcome = await Task.detached(priority: .userInitiated) {
            EventStreamLoader.readLogText(sessionID: id)
        }.value
        guard let outcome else {
            showToast("读取日志失败")
            return
        }
        UIPasteboard.general.string = outcome.text
        if outcome.fullByteCount > EventStreamLoader.clipboardLimitBytes {
            let fullMB = String(format: "%.1f", Double(outcome.fullByteCount) / 1_048_576)
            showToast("已复制前 2MB（全文 \(fullMB) MB），请用导出文件")
        } else {
            showToast("已复制全文（\(outcome.fullByteCount) 字节）")
        }
    }

    /// ERR-025②「复制取证」：cache-forensics 环形缓冲整段复制到剪贴板。
    /// 与「复制日志」分开的独立入口：取证输出在 os_log + 内存环形缓冲
    /// （CacheForensicsBuffer），不在 .jsonl 事件流里。纯内存读，不产生事件。
    func copyForensicsToClipboard() {
        guard let text = CacheForensicsBuffer.shared.exportText() else {
            showToast("暂无取证记录（至少发起两次模型请求后才有相邻请求对比）")
            return
        }
        UIPasteboard.general.string = text
        let byteCount = text.utf8.count
        if byteCount > EventStreamLoader.clipboardLimitBytes {
            let fullMB = String(format: "%.1f", Double(byteCount) / 1_048_576)
            showToast("已复制取证（\(fullMB) MB，含 512 行环形缓冲上限内的记录）")
        } else {
            showToast("已复制取证（\(byteCount) 字节）")
        }
    }

    /// toast 显示 2.5s 后自动消失；连续触发时重置计时。
    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}

// MARK: - 视图

/// 「当前会话事件流」只读诊断视图（dsh ui-trajectory 时间线最小移植）。
struct EventStreamView: View {
    @StateObject private var model: EventStreamViewModel

    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: EventStreamViewModel(environment: environment))
    }

    var body: some View {
        List {
            sessionSection
            eventListSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("事件流")
        .toolbar { debugToolbar }
        .refreshable { await model.loadEvents() }
        .task { await model.onAppear() }
        .onChange(of: model.selectedSessionID) { _ in
            Task { await model.loadEvents() }
        }
        // 只读诊断页不持写柄：本视图不触碰 SessionStore.openWriter，也不写任何事件/文件。
    }

    // MARK: - 子视图（拆分表达式，避免 SwiftUI type-check 超时）

    @ViewBuilder
    private var sessionSection: some View {
        Section("会话") {
            Picker("查看会话", selection: sessionBinding) {
                if model.sessions.isEmpty {
                    Text("暂无会话").tag("")
                }
                ForEach(model.sessions) { summary in
                    Text(sessionLabel(summary)).tag(summary.id)
                }
            }
            HStack {
                // M2.9：原始事件总数 + 聚合后行数对照（如「1894 事件 · 聚合后 37 行」）。
                Text("共 \(model.rawEventCount) 事件 · 聚合后 \(model.rows.count) 行")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if let loadedAt = model.lastLoadedAt {
                    Text(loadedLabel(loadedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let issue = model.scanIssue {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var eventListSection: some View {
        Section("事件流（时间线）") {
            if model.rows.isEmpty && !model.isLoading && model.errorMessage == nil {
                Text("该会话暂无事件")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                EventStreamRowView(row: row)
            }
        }
    }

    @ToolbarContentBuilder
    private var debugToolbar: some ToolbarContent {
        // ERR-025②「复制取证」：cache-forensics 环形缓冲整段复制（与
        // 「复制日志」分开——取证数据在内存缓冲，不在 .jsonl 事件流里）。
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                model.copyForensicsToClipboard()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .accessibilityLabel("复制缓存取证到剪贴板")
        }
        // M2.9 剪贴板导出：.jsonl 全文（UTF-8）复制到 UIPasteboard，与 ShareLink 并存；
        // 纯读文件不产生事件；> 2MB 截断复制并 toast 提示用导出文件。
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                Task { await model.copyLogToClipboard() }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .disabled(model.selectedSessionID == nil || model.isLoading)
            .accessibilityLabel("复制日志到剪贴板")
        }
        // F070 最小前置（M9.3 ZIP 完整版之前）：分享当前会话 .jsonl 原文件。
        // iOS 16+ ShareLink；源文件只读，副本在 Documents/WanWo-Exports/。
        ToolbarItem(placement: .navigationBarTrailing) {
            if let exportURL = model.exportFileURL {
                ShareLink(item: exportURL,
                          preview: SharePreview(exportURL.lastPathComponent)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出会话日志")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                Task { await model.loadEvents() }
            } label: {
                if model.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(model.isLoading || model.selectedSessionID == nil)
            .accessibilityLabel("刷新事件流")
        }
    }

    private func sessionLabel(_ summary: SessionSummary) -> String {
        let title = summary.title ?? "新会话"
        return title + " · " + String(summary.eventCount) + " 事件"
    }

    private func loadedLabel(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute().second())
        return "刷新于 " + time
    }

    /// 空会话列表时以 "" 兜底（Picker 需要 stable tag）。
    private var sessionBinding: Binding<String> {
        Binding(get: { model.selectedSessionID ?? "" },
                set: { newValue in
                    model.selectedSessionID = newValue.isEmpty ? nil : newValue
                })
    }
}

/// 单行：seq · 分类图标 · wire 名（着色）· 单行摘要截断 · 时间。
private struct EventStreamRowView: View {
    let row: EventStreamRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(row.seq))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Image(systemName: row.iconName)
                .foregroundStyle(row.isAlert ? Color.red : row.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.wireType)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(row.isAlert ? Color.red : row.tint)
                    .lineLimit(1)
                Text(row.summary)
                    .font(.footnote)
                    .foregroundStyle(row.isAlert ? Color.red : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(row.timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
