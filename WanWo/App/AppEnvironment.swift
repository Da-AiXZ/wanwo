//
//  AppEnvironment.swift
//  WanWo
//
//  【按设计新写】出处：10-design §四（App/AppEnvironment：依赖注入容器）、
//  §7.1（M1 信息架构子集装配）。M0 的 ISHRuntime/Platform/Vendor 不在此装配
//  （ShellTestView 自举，保持 M0 独立可回归）。
//

import Foundation
import SwiftUI

/// 根导航选择目标（§7.1 M1 子集 + M0 回归入口）。
enum RootSelection: Hashable {
    case session(id: String)
    case providers
    case shellTest
    case none
}

/// App 装配容器：会话仓库 + GRDB 索引 + 端点配置。
@MainActor
final class AppEnvironment: ObservableObject {
    let endpointStore: EndpointStore
    let sessionStore: SessionStore
    /// GRDB 投影库（对 UI 不透明；仅供会话层更新索引）。
    let database: SessionDatabase

    /// 会话列表版本号（创建/删除/标题落盘时 +1，驱动侧栏刷新）。
    @Published var sessionsRevision = 0
    @Published var selection: RootSelection = .none

    private static let logger = AppLogger(category: "env")

    init() {
        let base = WanWoPaths.persistentBase
        let sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        let configDir = base.appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDir,
                                                 withIntermediateDirectories: true)

        // GRDB 投影库（打开失败则以临时路径兜底一次，保证 App 可启动；错误进日志）。
        var database: SessionDatabase?
        do {
            database = try SessionDatabase(
                path: base.appendingPathComponent("wanwo-index.sqlite3").path)
        } catch {
            Self.logger.fault("session database open failed: \(String(describing: error))")
        }
        let db = database ?? (try? SessionDatabase(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("wanwo-index-fallback.sqlite3").path))!
        self.database = db
        self.sessionStore = SessionStore(root: sessionsRoot, database: db)
        self.endpointStore = EndpointStore(fileURL: configDir.appendingPathComponent("providers.json"))

        // 启动对账：以 JSONL 事实源重建索引（投影与 JSONL 一致性，§十一 M1.2）。
        Task { [weak self] in
            await self?.sessionStore.reconcileIndex()
            await MainActor.run { self?.sessionsRevision += 1 }
        }
    }

    // MARK: - 会话

    func loadSessions() async -> [SessionSummary] {
        await sessionStore.listSessions()
    }

    func createSession() async -> SessionSummary? {
        let summary = try? await sessionStore.createSession(cwd: WanWoPaths.linuxBaseDir + "/workspace")
        sessionsRevision += 1
        return summary
    }

    func deleteSession(id: String) async {
        // 先关闭可能开放的写柄（排他写所有权归还），再删除。
        await sessionStore.closeWriter(id: id)
        try? await sessionStore.deleteSession(id: id)
        if case .session(let selectedID) = selection, selectedID == id {
            selection = .none
        }
        sessionsRevision += 1
    }

    // MARK: - 模型接入

    /// 由当前启用端点构造 adapter（端点与 key 同代取用——dsh 凭据配对语义）。
    func makeAdapter() throws -> (OpenAICompatAdapter, EndpointConfig) {
        guard let endpoint = endpointStore.activeEndpoint() else {
            throw LLMError(message: "没有已启用的模型端点，请到「设置 · Providers」配置。",
                           code: "NO_ENDPOINT")
        }
        guard let apiKey = endpointStore.apiKey(for: endpoint), !apiKey.isEmpty else {
            throw LLMError(message: "端点「\(endpoint.name)」未配置 API Key。",
                           code: "MISSING_CREDENTIAL")
        }
        return (OpenAICompatAdapter(endpoint: endpoint, apiKey: apiKey), endpoint)
    }
}
