//
//  MCPLastActivationStore.swift
//  WanWo
//
//  【M4-A 验收增补 · 可观测性（lead 批准方案甲）】MCP 激活链路的用户面状态
//  直显。背景：激活链失败全部只落 AppLogger/os.log（mcp config skipped /
//  instance load failed / activation failed / connection attempt failed /
//  giveUp），App 内零导出面——用户独自持机时无法定位"为什么 mcp__* 工具
//  不在"。本 store 记录每 server 最近一次激活结果（覆盖写=每次会话栈构建
//  都刷新，呈现最新一次），设置页 MCP 行尾直读。
//  隐私面：错误摘要只取本仓错误文案（MCPConfigurationError 等本仓类型）与
//  URLError 系统本地化描述；headers/Authorization 值不进任何 error 串，
//  且 sanitized 再做一层 Bearer token 防御性抹除（fail closed 双保险）。
//

import Foundation

@MainActor
final class MCPLastActivationStore: ObservableObject, @unchecked Sendable {
    // @unchecked Sendable：activateAll 的 TaskGroup 闭包需跨 actor 捕获本
    // store——全部可变状态（entries）由 @MainActor 隔离守卫，写入恒经
    // Task { @MainActor ... }，unchecked 仅消除 Sendable 诊断、不放宽隔离。

    /// 单 server 最近一次激活结果（覆盖写——最新一次为准）。
    struct Entry: Codable, Equatable {
        var serverName: String
        var succeeded: Bool
        var time: Date
        /// 失败原因的用户可读摘要（成功为 nil）。
        var message: String?
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private let defaultsKey = "wanwo.mcp.lastActivation"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = loaded
        }
    }

    /// 记录激活成功（每次会话栈构建激活成功都覆盖写）。
    func recordSuccess(serverName: String) {
        upsert(Entry(serverName: serverName, succeeded: true,
                     time: Date(), message: nil))
    }

    /// 记录激活失败（config skipped 与 activation failed 同径；message 传
    /// 已摘要化的用户可读文案）。
    func recordFailure(serverName: String, message: String) {
        upsert(Entry(serverName: serverName, succeeded: false,
                     time: Date(), message: Self.sanitized(message)))
    }

    func entry(for serverName: String) -> Entry? {
        entries[serverName]
    }

    private func upsert(_ entry: Entry) {
        entries[entry.serverName] = entry
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - 摘要（用户可读形态；lead 要求③：不暴露内部枚举名）

    /// error → 用户可读失败摘要：URLError 用系统本地化描述（"Could not
    /// connect to the server." 等直接可读）；本仓错误类型（MCPConfiguration-
    /// Error 等已实现 CustomStringConvertible 且文案面向用户）原样；其余
    /// 兜底 describe（截断）。headers 值不进任何错误串——sanitized 再兜一层。
    nonisolated static func userFacingSummary(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return sanitized(urlError.localizedDescription)
        }
        return sanitized(String(describing: error))
    }

    /// 防御性净化：Bearer token 形态抹除 + 长度截断（隐私面 ① 硬要求——
    /// 正常路径错误串本就不含凭据，此处为 fail closed 兜底）。
    nonisolated static func sanitized(_ text: String) -> String {
        var result = text
        // "Bearer <token>" 形态整体抹除（大小写不敏感）。
        if let range = result.range(
            of: "Bearer [^\\s\"',)]+",
            options: [.regularExpression, .caseInsensitive]) {
            result = result.replacingCharacters(in: range, with: "Bearer [已抹除]")
        }
        if result.count > 200 {
            result = String(result.prefix(200)) + "…"
        }
        return result
    }
}
