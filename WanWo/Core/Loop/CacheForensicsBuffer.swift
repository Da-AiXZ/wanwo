//
//  CacheForensicsBuffer.swift
//  WanWo
//
//  【按设计新写 · ERR-025②】cache-forensics 环形缓冲（诊断页「复制取证」的数据源）。
//  背景：ERR-024 取证输出（AgentLoop.logCacheForensics 的相邻请求逐项指纹对比）
//  原本只进 os_log——真机上不连 Console 就看不到，取证链路不闭环（ERR-025 台账
//  修复③：诊断页加「复制取证」按钮，与「复制日志」分开的独立入口）。
//  约束（红线）：
//    · 纯内存环形缓冲，不落盘、不写事件——事件词汇零新增（§2.7 / ERR-024 口径）；
//    · 有界（容量 512 行、单行截 4000 字符）——长会话不膨胀；
//    · 线程安全（AgentLoop static 上下文写、EventStreamView 主线程读）。
//

import Foundation

/// cache-forensics 取证环形缓冲（线程安全）。
final class CacheForensicsBuffer: @unchecked Sendable {
    /// 缓冲行数上限（超限丢最老——FIFO 环形）。
    static let capacity = 512
    /// 单行字符上限（dump 行含全部 item 指纹，可能很长；截断保可读可复制）。
    static let lineCharLimit = 4_000

    static let shared = CacheForensicsBuffer()

    private let lock = NSLock()
    private var lines: [String] = []

    private init() {}

    /// 追加一行（超容量丢最老；超长截断；换行折叠保证单行语义）。
    func append(_ line: String) {
        var trimmed = line.replacingOccurrences(of: "\n", with: " ")
        if trimmed.count > Self.lineCharLimit {
            trimmed = String(trimmed.prefix(Self.lineCharLimit)) + "…"
        }
        lock.lock()
        defer { lock.unlock() }
        lines.append(trimmed)
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }

    /// 当前缓冲行快照（时间序：最老在前、最新在后）。
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// 诊断页「复制取证」导出文本：头部说明 + 行序列。
    /// - Returns: nil = 缓冲为空（尚无任何模型请求指纹）。
    func exportText() -> String? {
        let current = snapshot()
        guard !current.isEmpty else { return nil }
        var out = "cache-forensics dump (\(current.count) lines, oldest first; "
        out += "fingerprint = label#fnv1a64#utf8bytes)\n"
        out += current.joined(separator: "\n")
        return out
    }
}
