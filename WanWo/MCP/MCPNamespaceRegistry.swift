//
//  MCPNamespaceRegistry.swift
//  WanWo
//
//  【语义移植 · dsh · M4-A 件1】出处：packages/mcp/mcp-client/src/index.ts
//  :40-45（activeServerNames = WeakMap<object, Set<string>>——「Agent-scoped
//  的 MCP server 可在另一个 Agent 复用同一命名空间；全局实例与同一 Agent
//  内的重复互斥」）+:152-168（reserve effect——重复 serverName 使新实例加载
//  即失败且带可行动的错误文案，既有实例不受影响；dispose 回调释放）。
//  Swift 侧以「带所有者弱键的注册表」实现 WeakMap 语义：所有者销毁后其
//  条目失效（惰性清理）。
//

import Foundation

/// serverName 命名空间预留表（scope 级互斥）。
///
/// dsh 语义（index.ts:40-44 注释原文语义）：同 scope 内重复 serverName 在
/// 加载时即报错且不影响已存在实例；跨 scope 可复用。WanWo 的 "scope 所有
/// 者" = 装载这组 server 的对象（如 AppEnvironment 实例）。
final class MCPNamespaceRegistry: @unchecked Sendable {
    /// 弱所有者条目（WeakMap 语义：所有者释放即整体失效）。
    private struct Entry {
        weak var owner: AnyObject?
        var names: Set<String>
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// 预留一个 serverName（index.ts:154-168 effect 语义）。同所有者重复 →
    /// 抛错（新实例加载失败、既有实例不动）。
    /// 错误文案 = index.ts:162-164 逐字（唯一平台适配：cordis.yml →
    /// servers.json——dsh 的配置载体名，属产品命名层适配，语义不变）。
    func reserve(owner: AnyObject, serverName: String) throws {
        try lock.withLock {
            purgeStaleLocked()
            let key = ObjectIdentifier(owner)
            var entry = entries[key] ?? Entry(owner: owner, names: [])
            if entry.names.contains(serverName) {
                throw MCPConfigurationError(
                    "mcp-client: serverName \"\(serverName)\" is already in use by "
                        + "another mcp-client instance — pick a unique serverName in servers.json")
            }
            entry.names.insert(serverName)
            entries[key] = entry
        }
    }

    /// 释放（index.ts:167 dispose 回调语义；实例销毁时以所有者身份键调用——
    /// 所有者已释放时条目已被惰性清除，本调用为幂等 no-op）。
    func release(ownerID: ObjectIdentifier, serverName: String) {
        lock.withLock {
            guard var entry = entries[ownerID] else { return }
            entry.names.remove(serverName)
            if entry.names.isEmpty {
                entries.removeValue(forKey: ownerID)
            } else {
                entries[ownerID] = entry
            }
        }
    }

    /// WeakMap 语义的落地：所有者已释放的条目惰性清除（下次访问时回收，
    /// 与 JS WeakMap「无强引用即回收」的观测语义等价）。
    private func purgeStaleLocked() {
        entries = entries.filter { $0.value.owner != nil }
    }
}
