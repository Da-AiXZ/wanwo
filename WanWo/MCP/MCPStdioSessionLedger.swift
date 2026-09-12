//
//  MCPStdioSessionLedger.swift
//  WanWo
//
//  【M4-B B4 · stdio spawn 产物所有权台账】MCPTransportFactory stdio 分支
//  每次连接尝试 spawn 全新 guest 进程（dsh transport.ts:31-39 createTransport
//  每次调用全新 transport 的世代语义 1:1——connection.ts:228「一个 Client
//  一生一个 transport，重连=新建世代」）。SDK StdioTransport 是 fd 注入形态
//  （init(input:output:)，0.12.1 本地参照件 :66-83）且 disconnect 不关注入
//  的 fd（三坑①，SDK 源码 :179-187 disconnect 只停 loop）——进程与双 fd 的
//  所有权必须在 WanWo 侧记账。本台账=最小交接面：
//    · B4（本件）：世代替换防泄漏——同 server 重 spawn 前 reap 旧会话；
//    · B5：监督面消费 entry（startup 看门狗读 startupTimeoutSeconds、
//      世代下行信号=StdioTransport EOF）；
//    · B6：deactivate 收尾——核对结论（零新增代码）：deactivate→
//      supervisor.dispose→reapStdioSession("disposed")（MCPConnection
//      dispose 顶部，B5 落点）→ledger.reap→session.terminate() 杀进程组
//      +双 fd close，链路已闭合；MCPRuntime.deactivateAll/deinit 均经
//      McpClient.deactivate 到达同一链。
//  【场景2 修复 · 发现②（跨栈 ledger 竞态）】原设计条目仅按 serverName 单键
//  无归属身份——多会话栈（每栈一个 supervisor 同名 server）共用一条目：
//  新栈 spawn 前 reap 误杀旧栈进程、旧栈 supervisor 不识「已被替代」继续
//  重试并反向 reap 新栈健康进程（exitCode=-1 error=-4 杀球循环，测3/测4
//  实锤）+ 跨栈 fd 关闭（Bad file descriptor）。归属模型（lead 批准）：
//    · 条目带 ownerID（每 supervisor 一个 UUID）——任何回收点必须通过
//      归属核对（reap(serverName:expecting:)），只能回收自己的条目
//      （消除跨栈 fd 关闭）；
//    · 「最新栈获胜」收敛为显式 takeover：新栈首 spawn 经 takeover 回收
//      旧栈条目并通知其 onSuperseded——旧栈 supervisor stand down
//      （dispose 收敛，不进重试循环）；
//    · register 对不同 owner 的既有条目同构处理（last-registration-wins，
//      takeover→register 间隙竞态的兜底闭环）；
//    · 同栈内世代重连原语义不变（dsh 1:1 面不回退）：世代下行→reap
//      (expecting: self)→重 spawn→register，全链同一 owner。
//  线程模型：NSLock 守护字典（factory 在 connection actor 上调用、reap 的
//  terminate 是同步 ObjC 调用可从任意线程发起——T-shell-stop-blocked-by-actor
//  纪律，停止路径不经 actor）。onSuperseded 回调恒在锁外调用（回调链会
//  重入 ledger——dispose→reap，锁内调用即自锁死锁）。
//

import Foundation

/// 栈身份（发现② 归属模型的传递形态）：每 supervisor 构造时生成一个实例
/// （UUID 唯一 + 被替代收敛回调）。Sendable 值类型——supervisor→factory→
/// ledger 全链传递无需共享可变状态。
struct MCPStdioLedgerOwner: Sendable {
    let id: UUID
    /// 本条目被新栈 takeover/register 替代时的收敛回调（旧 supervisor
    /// stand down：dispose 收敛、不进重试循环）。构造方以 weak 捕获
    /// supervisor——台账不持强引用（栈释放后回调变 no-op）。
    let onSuperseded: @Sendable () -> Void
}

final class MCPStdioSessionLedger: @unchecked Sendable {

    /// 一条 stdio 会话的全所有权记录。
    struct Entry {
        /// 长驻会话句柄（terminate=杀进程组+finalize；raw-stdio 档下
        /// writeToStdin/closeStdin 为空转——stdin 写端已移交调用方）。
        let session: ISHShellLongLivedSession
        /// guest 根进程 PID（诊断与 B5 监督面用）。
        let pid: Int32
        /// guest stdin 写端（StdioTransport 的 output；WanWo 负责 close）。
        let stdinWriteFd: Int32
        /// guest stdout 读端（StdioTransport 的 input；WanWo 负责 close）。
        let stdoutReadFd: Int32
        /// 归属栈身份（发现②：归属核对与被替代通知的键+回调本体）。
        let owner: MCPStdioLedgerOwner
        /// 归属 id 便捷面（reap 核对用）。
        var ownerID: UUID { owner.id }
    }

    static let shared = MCPStdioSessionLedger()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    /// 记录 server 的活跃会话（键=serverName）。不同 owner 的既有条目=
    /// 被替代：回收旧进程+双 fd 并触发旧 owner 的 onSuperseded（锁外）。
    /// 同 owner 重注册=本栈世代替换（调用方应先 reap——factory 固定顺序；
    /// 此处兜底回收，防 takeover→register 间隙的进程泄漏）。
    func register(serverName: String, owner: MCPStdioLedgerOwner, entry: Entry) {
        lock.lock()
        let old = entries.updateValue(entry, forKey: serverName)
        lock.unlock()
        dispose(entry: old, newOwnerID: owner.id)
    }

    func entry(for serverName: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[serverName]
    }

    /// 「最新栈获胜」的显式接管（新栈首 spawn 前调用）：回收既有条目
    /// （无论归属），异主条目附加触发旧 owner 的 onSuperseded（旧栈
    /// supervisor stand down）。同 owner 条目=本栈上一世代的残留
    /// （generationDown 已 reap 的常态下为 no-op）。
    /// - Returns: 是否实际回收了一条记录（降噪用）。
    @discardableResult
    func takeover(serverName: String, owner: MCPStdioLedgerOwner) -> Bool {
        lock.lock()
        let old = entries.removeValue(forKey: serverName)
        lock.unlock()
        guard let old else { return false }
        dispose(entry: old, newOwnerID: owner.id)
        return true
    }

    /// 归属核对回收（发现② 核心）：仅当条目归属 expecting 时回收——
    /// 世代下行/dispose/giveUp/失败世代兜底各落点只终结自己的进程组并
    /// 关闭自己的 fd，异主条目（新栈健康进程）绝不动。
    /// - Returns: 是否实际回收了一条记录（http 条目/已回收/非本栈= false
    ///   ——调用方据此降噪日志，避免 stdio 专属事件刷屏）。
    @discardableResult
    func reap(serverName: String, expecting ownerID: UUID) -> Bool {
        lock.lock()
        guard let current = entries[serverName], current.ownerID == ownerID else {
            lock.unlock()
            return false
        }
        entries.removeValue(forKey: serverName)
        lock.unlock()
        terminate(entry: current)
        return true
    }

    // MARK: - 私有（回收与通知）

    /// 回收旧条目（进程组+双 fd）并按归属差异触发被替代通知。
    /// dispose 与 terminate 传入的条目已从字典移除——此处的 close/terminate
    /// 是回收的唯一执行点（幂等：进程已死/ fd 已关时为 errno 噪音，不深究）。
    private func dispose(entry old: Entry?, newOwnerID: UUID) {
        guard let old else { return }
        terminate(entry: old)
        if old.ownerID != newOwnerID {
            // 异主=被替代：锁外通知（回调链重入 ledger——dispose→reap）。
            old.owner.onSuperseded()
        }
    }

    private func terminate(entry: Entry) {
        entry.session.terminate()
        if entry.stdinWriteFd >= 0 { close(entry.stdinWriteFd) }
        if entry.stdoutReadFd >= 0 { close(entry.stdoutReadFd) }
    }
}
