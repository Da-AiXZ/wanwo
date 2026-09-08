//
//  SessionLogScanner.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/session/session-persistence-jsonl/src/format.ts
//  （SessionLogScanner / scanLog / refuseForeignFormatVersion）。
//  断电截断恢复语义 1:1：
//    - 增量扫描完整 JSONL 行；只有完整行才解码；末尾无换行的残帧 = torn tail，
//      忽略其内容，committedBytes 停在最后一个完整可解码行末尾。
//    - seq 不连续 / 解析失败 → 记 issue、不推进 committedBytes；若其后某行解码出
//      turn/end（说明损坏在日志中部而非断电尾）→ 抛 corrupt，拒绝重建。
//  头行版本校验：version != 0 → 拒绝（"升级 App"，绝不读成"日志损坏"）。
//

import Foundation

/// 存储层 fail-closed 异常体系（dsh session-persistence 异常分类子集）。
enum SessionLogError: Error, Equatable {
    /// 空文件或无头行。
    case emptyOrHeaderless
    /// 头行不是合法 JSON 或形状不符。
    case corruptHeader(String)
    /// 头行带本构建不读的格式版本（提示升级，而非"损坏"）。
    case unsupportedFormatVersion(id: String, version: Int)
    /// 事件区损坏（且被后续 turn/end 证明在日志中部）。
    case corrupt(String)
    /// 头行 id 与期望不符。
    case idMismatch(expected: String, actual: String)
    /// append 的 pre-write 守卫失败（seq 连续性 / 只读拒绝）——行尚未写入，
    /// 重试不会产生重复行（ERR-021 防御①的重试判定依据；I/O 失败不用此错误，
    /// 因为 seek/write/fsync 失败时行可能已部分或完整落盘，盲目重写会损坏 JSONL）。
    case appendRetryable(String)
}

/// 一次日志扫描的结果：头 + 可提交事件前缀 + 安全截断字节偏移。
struct SessionLogScan {
    var header: SessionHeader
    var events: [SessionEvent]
    /// 完整可提交前缀的字节长度（断电截断恢复：追加应从这里开始）。
    var committedBytes: Int
    /// 非致命损坏描述（torn tail；中部损坏会直接抛 SessionLogError.corrupt）。
    var issue: String?
    /// E1：未注册 kind 的 extension 事件计数（透传保留在流内——保 seq 连续性，
    /// 消费侧跳过；此处仅观测「旧版本读新日志」口径）。
    var skippedExtensionCount: Int = 0
    /// E1：被计数的未注册 kind 集合（诊断页展示）。
    var skippedExtensionKinds: Set<String> = []
}

enum SessionLogScanner {
    /// 头行 JSON 形状（type:"session" 标记，dsh format.ts HeaderLine）。
    private struct HeaderLine: Codable {
        var type: String
        var version: Int
        var id: String
        var createdAt: Int64
        var cwd: String?
    }

    /// 解析完整日志字节（头行 + 事件行）。
    static func scan(data: Data) throws -> SessionLogScan {
        guard let headerEnd = data.firstIndex(of: 0x0A) else {
            throw SessionLogError.emptyOrHeaderless
        }
        let headerData = data.subdata(in: data.startIndex..<headerEnd)
        let header = try parseHeaderLine(headerData)

        var events: [SessionEvent] = []
        var committedBytes = headerEnd + 1
        var issue: String?
        var lineNumber = 0
        var skippedExtensionCount = 0
        var skippedExtensionKinds = Set<String>()

        var cursor = data.index(after: headerEnd)
        while cursor < data.endIndex {
            guard let lineEnd = data[cursor...].firstIndex(of: 0x0A) else {
                // 末尾无换行 = torn tail（断电截断）：整段忽略。
                break
            }
            lineNumber += 1
            let lineData = data.subdata(in: cursor..<lineEnd)
            let lineEndOffset = data.distance(from: data.startIndex, to: lineEnd) + 1
            cursor = data.index(after: lineEnd)

            let decoded: SessionEvent?
            do {
                decoded = try JSONDecoder().decode(SessionEvent.self, from: lineData)
            } catch {
                if issue == nil {
                    issue = "unparsable committed event at line \(lineNumber)"
                }
                decoded = nil
            }

            guard let event = decoded else {
                // 已有 issue：继续扫描，仅当后续出现 turn/end 才判中部损坏。
                continue
            }

            if issue != nil {
                if event.wireType == "turn/end" {
                    throw SessionLogError.corrupt(issue ?? "corrupt session log")
                }
                continue
            }

            if event.seq != events.count {
                let expected = events.count
                let message = "seq gap in committed region at line \(lineNumber) "
                    + "(expected \(expected), got \(event.seq))"
                if event.wireType == "turn/end" {
                    throw SessionLogError.corrupt(message)
                }
                if issue == nil { issue = message }
                continue
            }

            // E1：未注册 kind 的 extension 事件计数（事件仍保留在流内——纪律：
            // 中部事件不可局部丢弃，否则其后全部事件因 seq gap 被连坐丢弃；
            // 消费侧按未注册一律跳过，此处仅观测计数）。
            if case .extensionEvent(let kind, _) = event.payload,
               !ExtensionEventRegistry.shared.isRegistered(kind) {
                skippedExtensionCount += 1
                skippedExtensionKinds.insert(kind)
            }

            events.append(event)
            committedBytes = lineEndOffset
        }

        return SessionLogScan(header: header, events: events,
                              committedBytes: committedBytes, issue: issue,
                              skippedExtensionCount: skippedExtensionCount,
                              skippedExtensionKinds: skippedExtensionKinds)
    }

    /// 仅解析头行（轻量列表/对账用）。
    static func parseHeader(data: Data) throws -> SessionHeader {
        guard let headerEnd = data.firstIndex(of: 0x0A) else {
            throw SessionLogError.emptyOrHeaderless
        }
        return try parseHeaderLine(data.subdata(in: data.startIndex..<headerEnd))
    }

    // MARK: - 轻量索引探针（持久索引增量校验 / 兜底快速重建专用）

    /// 一次轻量探测的结果（header + 行计数 + 尾部事件摘要）。
    struct SessionIndexProbe {
        var header: SessionHeader
        /// 已提交事件行数（按换行字节计数；torn tail 无换行不计入）。
        /// 注：若日志中部存在不可解码行（openWriter 全量扫描前无法发现），
        /// 本计数为物理行口径，可能略高于可解码事件数——投影用途可接受，
        /// 打开会话时由既有全量扫描口径纠正。
        var eventCount: Int
        /// 尾部窗口内最后一条已提交事件的时间；无事件（头-only 日志）为 nil。
        var lastTimeMs: Int64?
        /// 尾部窗口内最新的 session/title 标题；窗口内没有为 nil（调用方应
        /// 保留索引既有标题，见 SessionStore.verifyIncremental）。
        var title: String?
    }

    /// 轻量探测一个 JSONL 会话文件（持久索引路径专用；**禁止全文件读入内存 +
    /// 全事件解析**）：
    ///   1. 只读首行 → header（64KB 上限防御异常文件）；
    ///   2. 256KB 分块正向扫，仅统计换行字节 → eventCount（零事件解码）；
    ///   3. FileHandle seek 末尾读至多 64KB 窗口，只解码窗口内完整行：
    ///      取最后一条已提交事件的 timeMs + 窗口内最新 session/title；
    ///      无换行结尾的残帧 = torn tail，忽略（与 scan 语义一致）。
    /// 内存上界 O(256KB)，事件解码上界 O(64KB 窗口)。
    static func probeLightweight(fileURL: URL) throws -> SessionIndexProbe {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        // 1) header：只读首行。
        guard let firstChunk = try handle.read(upToCount: 64 * 1024),
              !firstChunk.isEmpty else {
            throw SessionLogError.emptyOrHeaderless
        }
        guard let headerEnd = firstChunk.firstIndex(of: 0x0A) else {
            throw SessionLogError.emptyOrHeaderless
        }
        let header = try parseHeaderLine(
            firstChunk.subdata(in: firstChunk.startIndex..<headerEnd))

        // 2) 行计数：从首行末尾起分块扫，仅数换行字节（不做任何事件解码）。
        var eventCount = 0
        try handle.seek(toOffset: UInt64(headerEnd + 1))
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 256 * 1024),
                      !read.isEmpty else { break }
                chunk = read
            } catch {
                break // I/O 失败：行计数停留在已读部分（投影口径可接受）。
            }
            for byte in chunk where byte == 0x0A {
                eventCount += 1
            }
        }

        // 3) 尾部窗口：seek 末尾读至多 64KB，只解码完整行。
        var lastTimeMs: Int64?
        var title: String?
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let window = min(Int(fileSize), 64 * 1024)
        if window > 0 {
            try handle.seek(toOffset: UInt64(fileSize - UInt64(window)))
            let tail = (try? handle.read(upToCount: window)) ?? Data()
            var lines: [Data] = []
            var cursor = tail.startIndex
            while let nl = tail[cursor...].firstIndex(of: 0x0A) {
                lines.append(tail.subdata(in: cursor..<nl))
                cursor = tail.index(after: nl)
            }
            // 末尾无换行的残帧不会进入 lines（torn tail 忽略）。
            let decoder = JSONDecoder()
            for line in lines.reversed() {
                guard let event = try? decoder.decode(SessionEvent.self, from: line) else {
                    continue
                }
                if lastTimeMs == nil { lastTimeMs = event.timeMs }
                if case .sessionTitle(let t, _) = event.payload {
                    title = t
                    break
                }
            }
        }
        return SessionIndexProbe(header: header, eventCount: eventCount,
                                 lastTimeMs: lastTimeMs, title: title)
    }

    private static func parseHeaderLine(_ lineData: Data) throws -> SessionHeader {
        guard !lineData.isEmpty else { throw SessionLogError.emptyOrHeaderless }
        let line: HeaderLine
        do {
            line = try JSONDecoder().decode(HeaderLine.self, from: lineData)
        } catch {
            throw SessionLogError.corruptHeader("header line is not a session header")
        }
        guard line.type == "session" else {
            throw SessionLogError.corruptHeader("first line is not a session header")
        }
        // 未来版本：提示升级，绝不读成损坏（dsh refuseForeignFormatVersion 语义）。
        guard line.version == SessionHeader.currentVersion else {
            throw SessionLogError.unsupportedFormatVersion(id: line.id, version: line.version)
        }
        return SessionHeader(id: line.id, createdAtMs: line.createdAt, cwd: line.cwd)
    }
}
