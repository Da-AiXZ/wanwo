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
/// 修 M1（实战轮修复批 2，2026-10-21）：缺省参数对齐 dsh retry-policy.ts
/// DEFAULT_*（packages/llm/llm/src/retry-policy.ts:14-17）——maxRetries=5 /
/// initialDelayMs=500 / maxDelayMs=10_000 / jitterRatio=0.1。旧缺省
/// （4 次 / 1s 起 / 30s 封顶）与 dsh 默认策略偏离，实测大 prefill 超时
/// -1001 场景重试覆盖不足，统一收敛 dsh 默认值。
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
         maxRetries: Int = 5,
         initialDelayMs: Int = 500,
         maxDelayMs: Int = 10_000,
         jitterRatio: Double = 0.1) {
        self.mode = mode
        self.maxRetries = maxRetries
        self.initialDelayMs = initialDelayMs
        self.maxDelayMs = maxDelayMs
        self.jitterRatio = jitterRatio
    }

    /// 可重试白名单（修 M1 后与 dsh DEFAULT_RETRYABLE_CODES 对齐核对：超时 /
    /// 传输类 / 5xx / 429 全覆盖；差异两项如实登记——dsh 含 EMPTY_RESPONSE，
    /// 万我该错误经 finish(.error) 在 runStep 落点抛出（流已收 [DONE] 后），
    /// 不在请求错误重试面，不扩面；万我另含 STREAM_CLOSED（SSE 未收 [DONE]
    /// 即断流——零字节收到的断流属传输类可重试，收到字节后由首 chunk 守卫
    /// 禁重试，见 AgentLoop.streamWithRetry 修 M1 边界）。
    static let retryableCodes: Set<String> = [
        "TRANSPORT",      // 连接/请求失败（网络）——含 NSURLErrorTimedOut(-1001) 包装
        "TIMEOUT",        // 流空闲超时（看门狗）
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
