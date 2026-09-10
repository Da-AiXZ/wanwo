//
//  SessionModelSelection.swift
//  WanWo
//
//  【语义移植 · dsh · T2.4 P1-3】会话级模型选择值宿主。
//  出处（packages/client/ui-model-selection/src/client/ModelSelect.tsx:1-13）：
//    state.current = per-session ModelSelection{provider, model, reasoningEffort?}
//    ——选择随会话（切会话各归各），不落盘、不落事件（dsh 为 per-session host
//    状态）；effectiveEffort = current?.reasoningEffort ?? defaultEffort（:83）。
//  WanWo 形态：
//    · 选择 = 端点 id + 会话 effort（provider/model 由端点配置承载）；
//    · nil = 未选择（App 级缺省 = 活动端点，新会话初始化）；
//    · NSLock 保护的 @unchecked Sendable 值宿主——makeAdapter 是 @Sendable 缝
//      （AgentLoop 后台线程按请求调用），UI 写侧在 MainActor，需线程安全。
//  EndpointStore.reasoningEffort（端点级字段）随本改动废弃：新写入不再设置，
//  旧值解码兼容但被会话选择覆盖/忽略（取舍见 T2.4 报告）。
//

import Foundation

final class SessionModelSelection: @unchecked Sendable {
    /// 选择值（dsh ModelSelection 的 WanWo 形态：端点 + 会话 effort）。
    struct Value: Equatable, Sendable {
        var endpointID: UUID
        /// nil = provider default 不透传（dsh defaultEffort 缺席语义）。
        var reasoningEffort: String?
    }

    private let lock = NSLock()
    private var value: Value?

    init(initial: Value? = nil) {
        self.value = initial
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value?) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
