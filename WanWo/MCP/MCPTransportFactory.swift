//
//  MCPTransportFactory.swift
//  WanWo
//
//  【语义移植 · dsh · M4-A 件2】出处：packages/mcp/mcp-client/src/transport.ts
//  :31-50 createTransport（按传输变体构造 MCP Transport；streamable-http
//  分支 = new StreamableHTTPClientTransport(new URL(config.url),
//  { requestInit: { headers: config.headers } })，:45-48）。
//  Swift SDK 0.12.1 构造签名（本地参照件 HTTPClientTransport.swift:110-130）：
//  init(endpoint:configuration:streaming:...:requestModifier:logger:)。
//  headers 注入 = requestModifier 闭包（TS requestInit.headers 的等价物）：
//  SDK 在设完全部内置头（Accept/Content-Type/MCP-Protocol-Version/
//  MCP-Session-Id/Last-Event-ID/Authorization）之后调用 requestModifier
//  （本地件 :266 send/:613 GET 流）——与 TS SDK「requestInit.headers 最后
//  合并、可覆盖内置头」的顺序语义一致（dsh transport.ts:47 同形）。
//  世代语义（connection.ts:228 注释原文）：一个 Client 一生一个 transport，
//  重连=新建世代——本工厂每次调用产出全新 transport 实例，件3 的
//  connectGeneration 每次连接尝试各自调用、不复用实例。
//

import Foundation
import SystemPackage
import MCP

/// MCP 传输工厂（dsh transport.ts createTransport 的 WanWo 形态；
/// M4-B B4 起 stdio 分支接通：spawn 长驻 guest 进程（raw-stdio 档）+
/// SDK StdioTransport 包 fd，返回类型放宽 any Transport。
/// 世代语义（connection.ts:228 注释原文）：一个 Client 一生一个 transport，
/// 重连=新建世代——本工厂每次调用产出全新 transport 实例，件3 的
/// connectGeneration 每次连接尝试各自调用、不复用实例；stdio 变体的
/// 「全新实例」=全新 guest 进程（spawnLongLivedRawStdioExecutable），
/// 旧世代进程与双 fd 的终结经 MCPStdioSessionLedger.reap（B5 监督面
/// 正式接管）。
/// B2：buildChildEnv 落位（transport.ts:21-23 1:1，本文件 stdio 分支消费）。
enum MCPTransportFactory {

    /// dsh transport.ts:21-23 buildChildEnv 的 WanWo 形态（M4-B B2 接线）：
    /// 子进程环境 = scrub 后 ambient 基座 + 显式 env 合并——extra 在基座
    /// 之上 = 用户显式值优先（transport.ts:22 展开顺序 1:1）。dsh 1:1
    /// 语义登记：显式 env 可重新引入敏感名键（buildChildEnv 不做二次
    /// 过滤——scrub 定义本体只清 ambient，extra 无条件展开在上）。
    /// 父环境取样缝（MCPEnvScrub.swift 头注预留点兑现，红线 R6）：dsh
    /// 的 buildChildEnv 经 scrubbedParentEnv() 无参读 process.env，取样
    /// 对位在调用侧——此处 parent 缺省即 ProcessInfo 取样；单测经入参
    /// 注入父环境（纯函数可测）。
    ///
    /// - Parameters:
    ///   - extra: 条目级显式 env（MCPServerEntry.env，entry() 解析层已
    ///     类型收窄为 [String: String]）。
    ///   - parent: 父环境注入缝（单测入参化）；nil = 调用侧 ProcessInfo
    ///     取样（红线 R6：全局环境读取只此一处）。
    /// - Returns: 合并后的子进程环境（键冲突时 extra 胜出）。
    static func buildChildEnv(
        _ extra: [String: String],
        parent: [String: String]? = nil
    ) -> [String: String] {
        let ambient = MCPEnvScrub.scrubbedParentEnv(
            parent ?? ProcessInfo.processInfo.environment)
        // transport.ts:22 展开顺序 1:1：{ ...scrubbedParentEnv(), ...extra }
        // ——JS spread 后者胜出，merging 闭包返回 extra 值同形。
        return ambient.merging(extra) { _, explicit in explicit }
    }

    /// 按 transport 变体构造全新 transport（dsh transport.ts:31-50 1:1）。
    ///
    /// - Parameter config: 已通过件1 加载校验的客户端配置。
    /// - Returns: 未连接的 transport——streamable-http 为 `HTTPClient-
    ///   Transport`（streaming=true——独立 GET 事件流 + POST 响应 SSE，
    ///   简报件2 指定形态）；stdio 为 SDK `StdioTransport`（fd 注入形态，
    ///   init(input:output:)——input=guest stdout 读端、output=guest stdin
    ///   写端，M4-B B4 raw-stdio spawn 产物）。
    /// - Throws: `MCPConfigurationError`——http：url 不是合法绝对 URL（dsh
    ///   `new URL(config.url)` transport.ts:46 对非绝对 URL 抛 TypeError 使
    ///   connect 失败走世代判负；Swift `URL(string:)` 宽松故显式校验保持
    ///   fail closed 同形）；stdio：cwd 非空（lead 裁决：nil=guest 默认目录，
    ///   spawn 路径不支持工作目录——fail loud 不静默忽略）、env 块超限
    ///   （executor envp_buf 8192 字节静默丢条目，入口侧预检 fail loud）、
    ///   spawn 失败。
    static func makeTransport(for config: MCPClientConfig) throws -> any Transport {
        switch config.transport {
        case .streamableHTTP(let urlString, let headers):
            guard let endpoint = URL(string: urlString),
                  endpoint.scheme != nil,
                  endpoint.host?.isEmpty == false else {
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): url is not a valid absolute URL")
            }
            return HTTPClientTransport(
                endpoint: endpoint,
                streaming: true,
                requestModifier: { request in
                    var request = request
                    for (field, value) in headers {
                        request.setValue(value, forHTTPHeaderField: field)
                    }
                    return request
                })
        case .stdio(let command, let args, let env, let cwd):
            // cwd fail closed（lead 裁决：维持 nil=guest 默认目录）：spawn
            // 路径无工作目录形态（平台差异登记 B1/B3），非空值显式拒绝——
            // 静默忽略会让用户配置与实际行为不一致。
            if let cwd, !cwd.isEmpty {
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): stdio cwd is not supported " +
                    "by the iSH spawn path (guest default cwd is used) — remove the cwd value")
            }
            // envp 长度预检（lead B3 裁决①）：executor envp_buf 8192 字节
            //（ISHShellExecutor.m:716），ENVP_APPEND 宏 headroom 256（:722
            // 同款），基座固定条目约 300B——自定义合并块上界取 7500B。超限
            // fail loud（executor 侧是静默丢条目——server 行为诡异的难查
            // 根因，必须在入口侧拦下）。
            let childEnv = buildChildEnv(env)
            let customEnvBytes = childEnv.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count + 2
            }
            guard customEnvBytes <= 7500 else {
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): stdio env block too large " +
                    "(\(customEnvBytes) bytes > 7500 limit) — trim env entries")
            }
            // 世代替换防泄漏：同 server 重 spawn（重连=新世代）前终结旧
            // 进程+关旧 fd（正式监督面=B5；此处只挡无界进程累积）。
            MCPStdioSessionLedger.shared.reap(serverName: config.serverName)
            var stdinWriteFd: Int32 = -1
            var stdoutReadFd: Int32 = -1
            guard let session = ISHShellExecutor.spawnLongLivedRawStdioExecutable(
                command,
                arguments: args,
                environment: childEnv,
                fsContext: 0,
                stdinWriteFd: &stdinWriteFd,
                stdoutReadFd: &stdoutReadFd,
                stderrLineCallback: nil,   // stderr AppLogger 聚合=M4-B B7
                exitHandler: nil) else {
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): stdio spawn failed " +
                    "(see ISHShellExecutor logs)")
            }
            guard stdinWriteFd >= 0, stdoutReadFd >= 0 else {
                session.terminate()
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): stdio spawn did not hand out pipes")
            }
            // 台账登记（B5 监督面/B6 deactivate 消费）：进程与双 fd 的
            // 所有权记账——SDK disconnect 不关注入 fd（三坑①），close 归属
            // 在 WanWo（ledger.reap）。
            MCPStdioSessionLedger.shared.register(
                serverName: config.serverName,
                entry: MCPStdioSessionLedger.Entry(
                    session: session,
                    pid: Int32(session.pid),
                    stdinWriteFd: stdinWriteFd,
                    stdoutReadFd: stdoutReadFd))
            // EOF→世代下行信号源：guest 死→stdout 读端 EOF→StdioTransport
            // readLoop 退出→messageContinuation finish→Client 消息循环退出
            //（SDK 源码 :147-150/:176）——B5 监督面据此判世代下行。
            return StdioTransport(
                input: FileDescriptor(rawValue: stdoutReadFd),
                output: FileDescriptor(rawValue: stdinWriteFd))
        }
    }
}
