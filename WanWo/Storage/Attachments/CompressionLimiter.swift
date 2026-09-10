//
//  CompressionLimiter.swift
//  WanWo
//
//  【语义移植 · dsh】出处：attachment-local/src/compression-limiter.ts:4-43
//  CompressionLimiter 1:1 语义：实例级并发上限 + FIFO 等待队列；任务占槽至
//  结算，槽位在释放时直接移交给队首等待者（active 计数不回落再攀升）。
//  并发值取 dsh DEFAULT_IMAGE_COMPRESSION_CONCURRENCY = 2（index.ts:50）。
//

import Foundation

final class CompressionLimiter: @unchecked Sendable {
    private let concurrency: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    init(concurrency: Int) {
        precondition(concurrency > 0, "compression limiter requires positive concurrency")
        self.concurrency = concurrency
    }

    /// 槽位可用后执行任务（compression-limiter.ts:18-42 run 语义 1:1）。
    func run<T: Sendable>(_ task: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await task()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    /// 取槽：有空槽即占用；否则 FIFO 入队挂起（保序——数组 push/shift 队列）。
    private func acquire() async {
        lock.lock()
        if active < concurrency {
            active += 1
            lock.unlock()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
            lock.unlock()
        }
    }

    /// 释放：队首等待者直接继承槽位（resume 后其 acquire 已在挂起态返回）；
    /// 无等待者才真正回落计数。
    private func release() {
        lock.lock()
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            lock.unlock()
            next.resume()
            return
        }
        active -= 1
        lock.unlock()
    }
}
