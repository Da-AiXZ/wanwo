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
import MCP

/// MCP 传输工厂（dsh transport.ts createTransport 的 WanWo 形态；
/// M4-B B1 起 stdio 分支为过渡 fail loud——连接面 B4 接通）。
enum MCPTransportFactory {
    /// 按 streamable-http 配置构造全新 transport。
    ///
    /// - Parameter config: 已通过件1 加载校验的客户端配置。
    /// - Returns: 未连接的 `HTTPClientTransport`（streaming=true——独立 GET
    ///   事件流 + POST 响应 SSE，简报件2 指定形态）。
    /// - Throws: `MCPConfigurationError` 当 url 不是合法绝对 URL——dsh
    ///   `new URL(config.url)`（transport.ts:46）对非绝对 URL 抛 TypeError
    ///   使 connect 失败走世代判负；Swift `URL(string:)` 对缺 scheme/host
    ///   的字符串宽松通过，故显式校验 scheme+host 保持 fail closed 同形。
    static func makeTransport(for config: MCPClientConfig) throws -> HTTPClientTransport {
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
        case .stdio:
            // M4-B B4 落地前的过渡分支（fail loud——不静默吞）：B1 已让
            // stdio 配置可解析/可持久化，连接面在 B4 接通（SDK Transport
            // 包 guest 子进程管道，返回类型届时放宽 any Transport）。
            throw MCPConfigurationError(
                "mcp-client(\(config.serverName)): stdio transport is not wired yet (lands with M4-B B4)")
        }
    }
}
