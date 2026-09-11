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
// StdioTransport 的 fd 形参是 System.FileDescriptor（SDK 源码 #if canImport
// (System) 分支——Apple 平台恒走 System 而非 SystemPackage；CI 实证两模块
// 类型不同名不互换，import 必须对齐 SDK 的选择）。
import System
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

    /// stderr 行日志汇（B4 登记①兑现——方案乙 AppLogger 接线）。行文本
    /// 原样+server 名前缀定位。日志量控制：executor 侧长驻 reader 已有
    /// 10min 空闲降频（B3）；行级不做采样——stderr 是 server 自述诊断面，
    /// 丢行=定位面缺口（诊断 fail closed 优先于日志量），os.log 环形缓冲
    /// 即节流边界。
    private static let stderrLogger = AppLogger(category: "MCPServerStderr")

    /// 会话生命周期日志（M4-B 场景2 取证 · 探针 A）：guest 退出事件——
    /// 三态判读：error=0 正常退出（exitCode=脚本退出码）/ error=-4
    /// Cancelled=reap 杀（对照 "stdio server process terminated (reason)"
    /// 时刻定落点）/ error=-5 ExitUnknown=孤儿回收（sweeper）。
    private static let lifecycleLogger = AppLogger(category: "MCPServerLifecycle")

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
            // envp 长度预检（lead B3 裁决①；B4 登记②分项计量兑现）：
            // executor envp_buf 8192 字节（ISHShellExecutor.m:716），ENVP_APPEND
            // 宏 headroom 256（:722 同款），基座固定条目约 300B——自定义合并
            // 块上界取 7500B。超限 fail loud，文案分开报父环境基线与用户
            // env 占比（大头常来自前者——指引模型缩 user env 而非无从下手）。
            let childEnv = buildChildEnv(env)
            let totalEnvBytes = childEnv.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count + 2
            }
            let userEnvBytes = env.reduce(0) {
                $0 + $1.key.utf8.count + $1.value.utf8.count + 2
            }
            guard totalEnvBytes <= 7500 else {
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): stdio env block too large " +
                    "(\(totalEnvBytes) bytes > 7500 limit; ambient parent environment " +
                    "contributes \(totalEnvBytes - userEnvBytes) bytes, user env " +
                    "\(userEnvBytes) bytes) — trim user env entries")
            }
            // 世代替换防泄漏：同 server 重 spawn（重连=新世代）前终结旧
            // 进程+关旧 fd（正式监督面=B5；此处只挡无界进程累积）。
            MCPStdioSessionLedger.shared.reap(serverName: config.serverName)
            var stdinWriteFd: Int32 = -1
            var stdoutReadFd: Int32 = -1
            var spawnError: Int32 = 0
            guard let session = ISHShellExecutor.spawnLongLivedRawStdioExecutable(
                command,
                arguments: args,
                environment: childEnv,
                fsContext: 0,
                stdinWriteFd: &stdinWriteFd,
                stdoutReadFd: &stdoutReadFd,
                spawnError: &spawnError,
                stderrLineCallback: { [serverName = config.serverName] line, _ in
                    // M4-B B7：stderr 行原样进 AppLogger（方案乙接线）。
                    stderrLogger.warning("mcp-server \(serverName) stderr: \(line)")
                },
                exitHandler: { [serverName = config.serverName] exitCode, error in
                    // M4-B 场景2 取证（探针 A）：guest 死因直读——此前
                    // exitHandler 传 nil，进程退出在 Swift 侧不可见（executor
                    // 层 finalize 静默），"transport 已死"只能靠请求失败反推。
                    // 三态判读见 lifecycleLogger 头注；pid 不在 completion
                    // 载荷（仅 exitCode/error），经 ISHShellExecutor[reader]
                    // 日志（idle 心跳带 pid）按时刻对齐。
                    // 【探针 B 实测落点登记】"transport 死亡"判定源的可见化
                    // 实测**已存在**，无需新增：executor 层 reader 退出点日志
                    // 齐全（readPipe 退出点——EOF :1511 / pipe closed :1470 /
                    // poll error :1448 / read error :1517 / idle 心跳 :1460
                    // 长驻 10min 降频 / 寿命帽 :1436，全带 pid；raw-stdio 档
                    // stdout reader 跳过但 stderr reader 照常派发 :893-895，
                    // stderr 读端 EOF=进程死亡的同刻信号）。Console 过滤
                    // "ISHShellExecutor[reader]" 即得死亡时刻+pid。SDK
                    // StdioTransport readLoop（SPM 远程包 0.12.1）不可插桩
                    // ——executor 层 stderr EOF 与其同刻，取证面等价。
                    lifecycleLogger.info(
                        "mcp-server \(serverName) guest exited " +
                        "exitCode=\(exitCode) error=\(error.rawValue)")
                }) else {
                // [M4-B B7 块3] spawn 失败原因具象化（URLError 不覆盖的
                // stdio 面——command not found/ENOEXEC/权限）。文案进
                // attemptFailure 日志 + MCPLastActivationStore（userFacing-
                // Summary 直通本仓错误文案）→ 设置页"上次激活"直读定位。
                let reason: String
                switch ISHShellExecutorError(rawValue: Int(spawnError)) {
                case .execFailed:
                    reason = "the start command was not found or is not executable " +
                        "— check the command path (e.g. /usr/bin/python3)"
                case .processCreationFailed:
                    reason = "process creation failed (kernel not booted, or pipe/task setup failed)"
                default:
                    reason = "unknown error (code \(spawnError))"
                }
                throw MCPConfigurationError(
                    "mcp-client(\(config.serverName)): stdio spawn failed — \(reason)")
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
