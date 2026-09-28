//
//  SubagentEdgeStore.swift
//  WanWo
//
//  【语义移植 · codex · M7.3 件 H · F050】出处：
//    - agent-graph-store/src/types.rs —— ThreadSpawnEdgeStatus（Open/Closed，
//      serde snake_case wire 名 "open"/"closed"）。
//    - agent-graph-store/src/store.rs —— AgentGraphStore trait 四方法语义：
//      upsert（child 至多一父，重插替换 parent+status）/ setStatus（缺 child =
//      成功 no-op）/ list children（status 过滤）/ list descendants（BFS，
//      过滤作用于沿途每条边——Closed 边之下的 Open 后代不可达）。
//    - agent-graph-store/src/local.rs —— 稳定排序契约：list 方法返回稳定序
//      （descendants = 逐层广度优先，层内按 thread id 升序；local.rs:248-343
//      测试期望为准绳）。
//
//  万我适配裁定（登记）：
//    - 存储宿主 = SessionDatabase（GRDB threadSpawnEdges 边表，0021 迁移
//      1:1 列结构）；本文件只放 trait 等价协议 + 纯函数树遍历（单测直呼）。
//    - ThreadId → String（万我会话 id 即 childId）。
//    - async future 面 → 同步 throws（GRDB DatabaseQueue 同步 API；
//      SubagentRuntime actor 内调用）。
//

import Foundation

/// Lifecycle status attached to a directional thread-spawn edge（types.rs:7-12）。
/// `open` = 子会话仍存活或可作为 open spawned agent 恢复；`closed` = 已从
/// 父子图视角显式关闭。
enum ThreadSpawnEdgeStatus: String, Equatable, Sendable {
    case open
    case closed
}

/// 边表行（upsert/list 的最小承载）。
struct SubagentSpawnEdge: Equatable, Sendable {
    var parent: String
    var child: String
    var status: ThreadSpawnEdgeStatus
}

/// Storage-neutral boundary for persisted thread-spawn parent/child topology
///（store.rs:17 AgentGraphStore trait 1:1）。实现必须返回稳定排序，调用方
/// 据此合并持久图状态与活内存状态而不引入非确定性输出。
protocol SubagentEdgeStoring: Sendable {
    /// Insert or replace the directional parent/child edge（store.rs:22-27）。
    /// child 至多一个持久父；重插同 child 应同时更新 parent 与 status。
    func upsertThreadSpawnEdge(parent: String, child: String,
                               status: ThreadSpawnEdgeStatus) throws

    /// Update the persisted lifecycle status of a spawned thread's incoming
    /// edge（store.rs:32-36）。缺 child = 成功 no-op。
    func setThreadSpawnEdgeStatus(child: String,
                                  status: ThreadSpawnEdgeStatus) throws

    /// List direct spawned children（store.rs:43-47）。statusFilter 非 nil 时
    /// 仅返回该精确 status 的边。
    func listThreadSpawnChildren(parent: String,
                                 statusFilter: ThreadSpawnEdgeStatus?) throws -> [String]

    /// List spawned descendants breadth-first by depth, then by thread id
    ///（store.rs:55-59）。statusFilter 作用于沿途每条边。
    func listThreadSpawnDescendants(root: String,
                                    statusFilter: ThreadSpawnEdgeStatus?) throws -> [String]
}

/// descendants 遍历纯函数（local.rs list_thread_spawn_descendants 语义 +
/// :248-343 测试期望对拍：逐层广度优先，层内按 child id 升序；过滤作用于
/// 沿途每条边——Closed 边之下即使自身边 Open 也不可达）。
enum SubagentEdgeTree {
    /// 从边集合计算 root 的后代序列（层序；层内升序；child 至多一父故无环）。
    static func descendants(edges: [SubagentSpawnEdge], root: String,
                            statusFilter: ThreadSpawnEdgeStatus?) -> [String] {
        var childrenByParent: [String: [String]] = [:]
        for edge in edges where statusFilter == nil || edge.status == statusFilter {
            childrenByParent[edge.parent, default: []].append(edge.child)
        }
        var current = Array(Set(childrenByParent[root] ?? [])).sorted()
        var visited: Set<String> = []
        var out: [String] = []
        while !current.isEmpty {
            out.append(contentsOf: current)
            visited.formUnion(current)
            var next: Set<String> = []
            for id in current {
                for child in childrenByParent[id] ?? [] where !visited.contains(child) {
                    next.insert(child)
                }
            }
            current = next.sorted()
        }
        return out
    }
}
