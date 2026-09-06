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
}

/// 一次日志扫描的结果：头 + 可提交事件前缀 + 安全截断字节偏移。
struct SessionLogScan {
    var header: SessionHeader
    var events: [SessionEvent]
    /// 完整可提交前缀的字节长度（断电截断恢复：追加应从这里开始）。
    var committedBytes: Int
    /// 非致命损坏描述（torn tail；中部损坏会直接抛 SessionLogError.corrupt）。
    var issue: String?
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

            events.append(event)
            committedBytes = lineEndOffset
        }

        return SessionLogScan(header: header, events: events,
                              committedBytes: committedBytes, issue: issue)
    }

    /// 仅解析头行（轻量列表/对账用）。
    static func parseHeader(data: Data) throws -> SessionHeader {
        guard let headerEnd = data.firstIndex(of: 0x0A) else {
            throw SessionLogError.emptyOrHeaderless
        }
        return try parseHeaderLine(data.subdata(in: data.startIndex..<headerEnd))
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
