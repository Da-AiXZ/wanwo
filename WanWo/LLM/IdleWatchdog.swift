//
//  IdleWatchdog.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/llm/llm-deepseek/src/adapter.ts
//  （idleWatchdog + DEFAULT_STREAM_IDLE_TIMEOUT_MS = 300_000）。
//  流空闲 5 分钟语义：一次读挂起期间连续 5 分钟无活动脉冲 → 判超时（TIMEOUT），
//  经 TaskGroup 取消消费子任务使 URLSession.bytes 读终止（结构化并发；
//  替代 dsh 的 AbortSignal.any 融合）。
//

import Foundation

/// 传输活动跟踪器：SSE 每行/每载荷 pulse 一次；看门狗子任务按 0.5s 周期检查空闲。
final class ActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = Date()
    private var timedOut = false

    /// 记录一次传输活动。
    func pulse() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    /// 距上次活动的秒数。
    func idleSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastActivity)
    }

    /// 标记空闲超时已判定（供错误分类）。
    func markTimeout() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}
