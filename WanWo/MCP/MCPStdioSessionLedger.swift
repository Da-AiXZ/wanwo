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
//    · B6：deactivate 经 entry.session.terminate() 杀进程组。
//  线程模型：NSLock 守护字典（factory 在 connection actor 上调用、reap 的
//  terminate 是同步 ObjC 调用可从任意线程发起——T-shell-stop-blocked-by-actor
//  纪律，停止路径不经 actor）。
//

import Foundation

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
    }

    static let shared = MCPStdioSessionLedger()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {}

    /// 记录 server 的活跃会话（键=serverName；同键重注册=世代替换，调用方
    /// 应先 reap 旧条目——factory stdio 分支的固定顺序）。
    func register(serverName: String, entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entries[serverName] = entry
    }

    func entry(for serverName: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[serverName]
    }

    /// 取消记录并终结旧会话+关闭双 fd（Best-effort close，errno 不深究——
    /// guest 已死时 close 收 EINTR/EINVAL 属常态）。世代下行/重 spawn 前调用。
    func reap(serverName: String) {
        lock.lock()
        let old = entries.removeValue(forKey: serverName)
        lock.unlock()
        guard let old else { return }
        old.session.terminate()
        if old.stdinWriteFd >= 0 { close(old.stdinWriteFd) }
        if old.stdoutReadFd >= 0 { close(old.stdoutReadFd) }
    }
}
