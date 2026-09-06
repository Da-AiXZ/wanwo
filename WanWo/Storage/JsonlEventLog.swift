//
//  JsonlEventLog.swift
//  WanWo
//
//  【语义移植 · dsh】出处：
//    - dsh packages/session/session-persistence-jsonl/src/storage.ts（JsonlSessionHandle：
//      per-handle 串行追加链、observedLength 不缩短断言、torn-tail 修复）
//    - dsh packages/session/session-persistence-jsonl/src/format.ts（scanLog / committedBytes）
//    - 10-design §5.1（JsonlEventLog：O_APPEND write + fsync；断电截断恢复；
//      hardlink/realpath 校验）+ §5.2（append 返回即 durable → model-visible=logged）
//  WanWo 形态：actor 串行化所有读写（等价 dsh per-handle promise chain）。
//  每次 append = 行编码 → seekToEnd 写入 → sync()（fsync）→ 返回；
//  「延迟构造下游模型流直到完整已记录请求前缀 durable」（dsh
//  session-checkpoint-policy）由 append 返回时机保证。
//  硬链接/realpath fail-closed 校验：打开时校验文件 inode 稳定性与路径真实归属。
//

import Darwin
import Foundation

/// append-only JSONL 事件日志（每会话一个文件：首行 header + 事件行流）。
actor JsonlEventLog {
    let fileURL: URL
    let header: SessionHeader
    private(set) var events: [SessionEvent]
    /// 完整可提交前缀的字节长度（torn tail 之外）。
    private var committedBytes: Int
    private var fileHandle: FileHandle?
    /// 打开时是否发现需要截断的残尾（写模式打开即截断——排他写所有权已保证）。
    private var truncatedTornTail = false

    private static let logger = AppLogger(category: "eventlog")

    // MARK: - 打开 / 创建

    /// 创建新日志：写入头行并 fsync（dsh：显式 flush 的空会话也物化为头-only 工件）。
    static func create(header: SessionHeader, at fileURL: URL) throws -> JsonlEventLog {
        let line = SessionHeaderLine(type: "session",
                                     version: header.version,
                                     id: header.id,
                                     createdAt: header.createdAtMs,
                                     cwd: header.cwd)
        let data = try JSONEncoder().encode(line)
        FileManager.default.createFile(atPath: fileURL.path, contents: data + Data([0x0A]))
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.sync()
        return JsonlEventLog(fileURL: fileURL, header: header,
                             events: [], committedBytes: data.count + 1,
                             fileHandle: handle)
    }

    /// 打开既有日志：全量扫描 → 校验 → （写模式）截断残尾。
    /// - Parameter expectedID: 打开已有会话时校验头行 id（fail closed）。
    static func open(fileURL: URL, writeMode: Bool, expectedID: String? = nil) throws -> JsonlEventLog {
        let data = try Data(contentsOf: fileURL)
        let scan = try SessionLogScanner.scan(data: data)
        if let expectedID = expectedID, scan.header.id != expectedID {
            throw SessionLogError.idMismatch(expected: expectedID, actual: scan.header.id)
        }
        // dsh realpath/硬链接 fail-closed 校验的等价实现：打开后校验
        // fileHandle 指向的文件与路径解析结果一致（防符号链接替换/半删除态）。
        let handle = try FileHandle(forWritingTo: fileURL)
        if !verifySameFile(handle: handle, url: fileURL) {
            try? handle.close()
            throw SessionLogError.corrupt("log file identity check failed (hardlink/realpath mismatch)")
        }

        var truncatedTornTail = false
        if writeMode && data.count > scan.committedBytes {
            // 断电截断恢复：丢弃残缺尾行（中部损坏已由 scanner 抛出，不会走到这里）。
            try handle.truncate(atOffset: UInt64(scan.committedBytes))
            handle.sync()
            truncatedTornTail = true
            logger.warning("session \(scan.header.id): truncated torn tail "
                + "\(data.count - scan.committedBytes) bytes at open")
        }
        let log = JsonlEventLog(fileURL: fileURL, header: scan.header,
                                events: scan.events,
                                committedBytes: scan.committedBytes,
                                fileHandle: writeMode ? handle : nil,
                                truncatedTornTail: truncatedTornTail)
        if !writeMode {
            try? handle.close()
        }
        return log
    }

    private static func verifySameFile(handle: FileHandle, url: URL) -> Bool {
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return false }
        var st1 = stat()
        if fstat(fd, &st1) != 0 { return false }
        guard let realPath = realpath(url.path, nil) else { return false }
        defer { free(realPath) }
        var st2 = stat()
        if stat(realPath, &st2) != 0 { return false }
        return st1.st_ino == st2.st_ino && st1.st_dev == st2.st_dev
    }

    private init(fileURL: URL, header: SessionHeader, events: [SessionEvent],
                 committedBytes: Int, fileHandle: FileHandle?,
                 truncatedTornTail: Bool = false) {
        self.fileURL = fileURL
        self.header = header
        self.events = events
        self.committedBytes = committedBytes
        self.fileHandle = fileHandle
        self.truncatedTornTail = truncatedTornTail
    }

    // MARK: - 读

    /// 事件快照（dsh read()：不返回短于先前观察值的日志）。
    func snapshotEvents() -> [SessionEvent] {
        events
    }

    var eventCount: Int { events.count }

    var didTruncateTornTail: Bool { truncatedTornTail }

    // MARK: - 写

    /// durable 追加一条事件：seq 必须等于当前事件数（连续性校验，dsh assertContiguous）。
    /// 返回即已 fsync——调用方此后才允许发起下游模型请求（checkpoint-policy 语义）。
    func append(_ event: SessionEvent) async throws {
        guard event.seq == events.count else {
            throw SessionLogError.corrupt(
                "append seq \(event.seq) does not continue log at \(events.count)")
        }
        guard let handle = fileHandle else {
            throw SessionLogError.corrupt("log opened read-only; append refused (fail closed)")
        }
        var lineData = try JSONEncoder().encode(event)
        lineData.append(0x0A)
        try handle.seekToEnd()
        try handle.write(contentsOf: lineData)
        try handle.sync()
        committedBytes += lineData.count
        events.append(event)
    }

    /// 关闭（释放文件句柄）。幂等。
    func close() {
        if let handle = fileHandle {
            try? handle.sync()
            try? handle.close()
            fileHandle = nil
        }
    }
}

/// 头行 JSON 形状（dsh format.ts HeaderLine）。
struct SessionHeaderLine: Codable {
    var type: String
    var version: Int
    var id: String
    var createdAt: Int64
    var cwd: String?
}
