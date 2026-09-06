//
//  RetryPolicy.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/llm/llm-retry/src/index.ts（localDelay、
//  retryableCodes 白名单、providerRetryAfterMs 优先、先持久化再等待）。
//  指数退避 + jitter；「每次调度重试在其可取消等待之前先持久化」由
//  ChatTurnRunner 在等待前追加 llm/retry 事件保证（10-design §5.5 RetryPolicy）。
//

import Foundation

/// 重试策略（dsh ResolvedRetryPolicy 语义；不做跨模型故障转移——09 决策 #2）。
struct RetryPolicy: Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// 有限重试：受 maxRetries 与 retryableCodes 白名单约束。
        case normal
        /// 无限重试（不受白名单约束，仅信号取消终止；M1 不使用，保留词汇）。
        case always
    }

    var mode: Mode
    var maxRetries: Int
    var initialDelayMs: Int
    var maxDelayMs: Int
    var jitterRatio: Double

    init(mode: Mode = .normal,
         maxRetries: Int = 4,
         initialDelayMs: Int = 1_000,
         maxDelayMs: Int = 30_000,
         jitterRatio: Double = 0.1) {
        self.mode = mode
        self.maxRetries = maxRetries
        self.initialDelayMs = initialDelayMs
        self.maxDelayMs = maxDelayMs
        self.jitterRatio = jitterRatio
    }

    /// 可重试白名单（交付口径：网络类 / 5xx / 429）。AUTH/INVALID_REQUEST/QUOTA 等不可重试。
    static let retryableCodes: Set<String> = [
        "TRANSPORT",      // 连接/请求失败（网络）
        "TIMEOUT",        // 流空闲超时
        "STREAM_CLOSED",  // SSE 未收到 [DONE] 即中断（断流）
        "SERVER",         // 5xx
        "RATE_LIMIT",     // 429
    ]

    func isRetryable(code: String) -> Bool {
        switch mode {
        case .always:
            return true
        case .normal:
            return Self.retryableCodes.contains(code)
        }
    }

    /// dsh localDelay 1:1：min(initial * 2^(retry-1), max) × (1-r + 2r·rand)。
    func localDelayMs(retry: Int, random: (() -> Double)? = nil) -> Int {
        let jitterSample = random?() ?? Double.random(in: 0..<1)
        let exponent = min(retry - 1, 1024)
        let exponential = min(Int(Double(initialDelayMs) * pow(2.0, Double(exponent))), maxDelayMs)
        let jitter = 1 - jitterRatio + 2 * jitterRatio * jitterSample
        let delay = min(Double(exponential) * jitter, Double(maxDelayMs))
        return max(0, Int(delay))
    }

    /// 计算一次重试的等待时长：provider Retry-After 优先（dsh 语义：超过 maxDelay
    /// 在 normal 模式下视为不可等待——由调用方决定放行；M1 钳到 maxDelay）。
    func delayMs(retry: Int, providerRetryAfterMs: Int?) -> Int {
        if let afterMs = providerRetryAfterMs, afterMs > 0 {
            return min(afterMs, maxDelayMs)
        }
        return localDelayMs(retry: retry)
    }
}
