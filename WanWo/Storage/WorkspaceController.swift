//
//  WorkspaceController.swift
//  WanWo
//
//  【M6.5 新写 · 语义源 dsh workspace-controller 七动词（workspace.zh.md :192-241）】
//  面向 GUI 的工作区 CRUD 门面（dsh ctx.workspaceController 的 WanWo 本地对应）：
//    create / rename / delete / insertBefore / insertSessionBefore / archiveSession /
//    follow（流式：基线 + 有序增量 → WanWo 形态 = AsyncStream 快照帧）。
//
//  follow 形态差异（报告登记）：dsh 为远端流式协议（baseline + ordered increments）；
//  WanWo 单进程无 RPC 层——折算为「订阅即发基线快照，此后每次接受型变更发全量
//  快照帧」的 AsyncStream（消费侧语义等价：任何时刻最新帧即完整状态）。
//

import Foundation

/// follow 帧的 WanWo 形态：全量快照（消费侧以最新帧为完整状态）。
struct WorkspaceFollowFrame: Sendable {
    var workspaces: [WorkspaceRecord]
    /// 帧序号（单调递增；0 = 基线）。
    var sequence: Int
}

/// 工作区控制器（App 级，挂 AppEnvironment；dsh ctx.workspaceController 同位）。
@MainActor
final class WorkspaceController: ObservableObject {

    private let registry: WorkspaceRegistry
    private let logger = AppLogger(category: "workspace-controller")

    /// follow 订阅续流池（每订阅一个 continuation；registry.onChange 广播）。
    private var continuations: [UUID: AsyncStream<WorkspaceFollowFrame>.Continuation] = [:]
    private var frameSequence = 0
    private var changeHandlerInstalled = false

    init(registry: WorkspaceRegistry) {
        self.registry = registry
    }

    // MARK: - 七动词

    /// create：注册或幂等解析一个已存在目录上的工作区。
    /// 返回 (工作区, 本次调用是否新建)（dsh WorkspaceCreateValue 同语义）。
    func create(path: String, title: String?) throws -> (workspace: WorkspaceRecord, created: Bool) {
        let before = registry.resolveByPath(path: path)
        let ws = try registry.create(path: path, title: title)
        let created = (before == nil) || (before?.id != ws.id)
        return (ws, created)
    }

    /// rename：改显示标题（任意非空字符串；跨工作区允许重复）。
    /// GRDB 直写收口在 WorkspaceRegistry.renameTitle（本层不 import GRDB）。
    func rename(id: String, to title: String) throws -> WorkspaceRecord {
        try registry.renameTitle(id: id, title: title)
    }

    /// delete：移除注册（保留目录与会话）；返回是否实际删除。
    func delete(id: String) throws -> Bool {
        try registry.delete(id)
    }

    /// insertBefore：注册表序内移动工作区。
    func insertBefore(id: String, beforeId: String?) throws -> [String] {
        try registry.insertBefore(id, before: beforeId)
        return registry.list().map(\.id)
    }

    /// insertSessionBefore：组内账本移动会话。
    func insertSessionBefore(sessionId: String, beforeSessionId: String?,
                             in workspaceId: String) throws -> WorkspaceRecord {
        try registry.insertSessionBefore(sessionId: sessionId,
                                         beforeSessionId: beforeSessionId,
                                         in: workspaceId)
        guard let ws = registry.get(workspaceId) else {
            throw WorkspaceRegistryError.moveInvalid
        }
        return ws
    }

    /// archiveSession：按会话维度归档。
    func archiveSession(sessionId: String) throws {
        try registry.archiveSession(sessionId: sessionId)
    }

    /// follow：基线快照 + 后续每次接受型变更的有序快照帧（AsyncStream）。
    /// 返回 (流, 取消句柄)——取消句柄调用即摘除订阅并终止流。
    func follow() -> (stream: AsyncStream<WorkspaceFollowFrame>, cancel: () -> Void) {
        installChangeHandler()
        let subscriptionID = UUID()
        let stream = AsyncStream<WorkspaceFollowFrame> { continuation in
            continuations[subscriptionID] = continuation
            // 基线帧（sequence 0）。
            continuation.yield(WorkspaceFollowFrame(workspaces: registry.list(), sequence: 0))
        }
        let cancel: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.removeSubscription(subscriptionID)
            }
        }
        return (stream, cancel)
    }

    // MARK: - 内部

    private func installChangeHandler() {
        guard !changeHandlerInstalled else { return }
        changeHandlerInstalled = true
        registry.onChange = { [weak self] in
            // onChange 可能来自任意线程（registry 变更缝）；帧构造与续流派发
            // 收敛到 MainActor（本类隔离域），跳转经 Task 保证安全。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frameSequence += 1
                let frame = WorkspaceFollowFrame(
                    workspaces: self.registry.list(),
                    sequence: self.frameSequence)
                for continuation in self.continuations.values {
                    continuation.yield(frame)
                }
            }
        }
    }

    private func removeSubscription(_ id: UUID) {
        continuations[id]?.finish()
        continuations.removeValue(forKey: id)
    }
}
