//
//  MCPDiagnosticsLog.swift
//  WanWo
//
//  【M4-B 场景2 取证 · 方案乙最小化（lead 批准提前落地）】MCP 事件流诊断日志
//  文件化——进程死亡原因（激活成功→秒死）的 os.log 探针用户摸不到（无 Mac
//  连线条件），本件把关键事件同步追加到 Application Support 下的 JSONL 文件，
//  设置页"导出诊断日志"按钮（ShareLink）交用户自助取回。
//    · 事件集（全部为既有日志点的同步追加，零语义变更）：guest exited
//      （探针 A，死因三态）/ stdio process terminated (reason)（B5 回收落点）/
//      重连循环（retry/give-up）/ 激活成功失败（MCPRuntime.activateAll）。
//    · 环形：~100KB 上界，超限保留后半行原子重写（事件频率=激活/世代级，
//      重写成本可忽略）。
//    · 隐私（lead 要求③）：只追加本仓错误文案与自产事件文案；每行再过
//      MCPLastActivationStore.sanitized 兜底（Bearer 抹除+截断，fail closed
//      双保险）；headers/凭据永不进诊断文件。
//    · 故障面：本件任何 I/O 失败静默（诊断件自身故障不得影响主链）。
//

import Foundation

final class MCPDiagnosticsLog: @unchecked Sendable {

    static let shared = MCPDiagnosticsLog()

    /// 环形上界（字节）。事件为激活/世代级低频，100KB ≈ 数百条记录。
    private static let maxBytes = 100 * 1024

    private let lock = NSLock()
    private let fileURL: URL
    private let fileManager = FileManager.default

    private init() {
        fileURL = WanWoPaths.persistentBase
            .appendingPathComponent("mcp-diagnostics.log")
    }

    /// 诊断文件位置（设置页导出按钮用）。
    var url: URL { fileURL }

    /// 确保文件存在（导出按钮前置——空文件也可分享）。
    func ensureFile() {
        lock.lock()
        defer { lock.unlock() }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    /// 追加一条事件（线程安全；每行即落盘；I/O 失败静默）。
    /// - Parameters:
    ///   - level: "info" / "warn" / "error"（对齐 AppLogger 词汇）。
    ///   - category: 来源组件（对齐 AppLogger category，便于与 os.log 对读）。
    ///   - server: MCP server 名（可空=栈级事件）。
    ///   - event: 事件文案（本仓错误文案或自产文案；sanitized 兜底）。
    func record(level: String, category: String, server: String?, event: String) {
        var payload: [String: String] = [
            "time": Self.localTimestamp(Date()),
            "level": level,
            "category": category,
            "event": MCPLastActivationStore.sanitized(event),
        ]
        if let server {
            payload["server"] = server
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        lock.lock()
        defer { lock.unlock() }
        appendLine(data)
        trimIfNeeded()
    }

    // MARK: - 私有（调用方已持锁）

    private func appendLine(_ data: Data) {
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        var line = data
        line.append(0x0A)   // JSONL 换行
        try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// 环形截断：超限保留后半行，原子重写（低频事件路径，成本可忽略）。
    private func trimIfNeeded() {
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > Self.maxBytes else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1 else { return }
        let kept = lines.suffix(lines.count / 2)
        let trimmed = kept.joined(separator: "\n") + "\n"
        try? Data(trimmed.utf8).write(to: fileURL, options: .atomic)
    }

    /// 本地时区 ISO8601（与 MCPServerConfigTool.localTimestamp 同语义——
    /// fefbd8a UTC 修正的同族展示层；每调用现建 formatter 避 static 非
    /// Sendable 面）。
    private static func localTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
