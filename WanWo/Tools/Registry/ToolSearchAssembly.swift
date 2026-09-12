//
//  ToolSearchAssembly.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs core/src/tools/spec_plan.rs:371-406
//  （finalize_tool_router 的 tool_search 注册面：registry.entries().any(
//  exposure.is_deferred()) ⇒ 先 remove 旧 tool_search 再 append executor）
//  + :530-542（build_model_visible_specs 仅直出 direct——schemas() 收窄的
//  对拍锚，落在 ToolRegistry.schemas()）。WanWo 组装步 = 本类：存在 deferred
//  工具 ⇒ 注册/刷新 tool_search（tryRegister+disposer 换手，M4-A 件4 语义
//  复用）；零 deferred ⇒ 注销/不注册（零开销，codex :372-377 any(...) 为假
//  分支同构）。执行时机：AgentLoop.runStep 每步组装前（codex per-turn
//  finalize 的 WanWo 逐步等价；幂等，MCP 工具世代换手后由此收敛注册态）。
//  平台差异登记：
//    · codex 每回合 remove+append 重建 tool_search 条目 → WanWo 注册一次即
//      持有（provider 实时读 registry + ToolSearchTool 引擎语料全等缓存承接
//      语料新鲜度——换代输出等价，注册面幂等收敛）；
//    · codex 条件含 tool.runtime.search_info().is_some() → WanWo AgentTool
//      必有 name/description/parameters，条件恒真，省略；
//    · codex 冲突路径 = remove+record_collision+error_on_tool_collisions 报错
//      → WanWo = tryRegister 可捕获 ToolRegistryConflictError，fail contained
//      记日志跳过（M4-A 件4 contain 语义同款）；
//    · 语料构建（AgentTool → ToolSearchInfo.from + sourceInfo）在本类收口；
//      sourceInfo：MCP 工具带 server 名（MCPClientConfig 无 server description
//      字段，可选描述当前恒 nil——上游缺口已呈报），内置工具 nil。
//    · C7：description 缓存随手——refresh 每步把 registry 语料快照喂给已注册
//      的 ToolSearchTool（syncCorpus，registry 锁外），来源集变化时渲染同手
//      收敛、无一步滞后；渲染端口见 ToolSearchSourceListing.swift。
//

import Foundation

/// tool_search 组装步（M4-C2）。持有注册态 disposer 并按 deferred 工具存在性
/// 换手；线程安全（NSLock 护 disposer；语料快照经 ToolRegistry 内部锁）。
final class ToolSearchAssembly: @unchecked Sendable {

    private let registry: ToolRegistry
    private let lock = NSLock()
    /// 当前 tool_search 的注销器（nil = 未注册）。
    private var disposer: (@Sendable () -> Void)?

    private static let logger = AppLogger(category: "ToolSearchAssembly")

    /// - Parameter registry: 组装目标注册表（会话栈级，与 MCP 工具桥同源）。
    init(registry: ToolRegistry) {
        self.registry = registry
    }

    /// tool_search 是否已注册（测试锚 + 诊断面）。
    var isRegistered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposer != nil
    }

    /// 组装步：存在 deferred 工具 ⇒ 注册 tool_search；零 deferred ⇒ 注销。
    /// 幂等、可重入调用（每步组装前执行）。
    func refresh() {
        let corpus = Self.infos(from: registry)
        lock.lock()
        defer { lock.unlock() }
        if corpus.isEmpty {
            // 零 deferred ⇒ 注销（零开销：codex :372-377 any(...is_deferred...)
            // 为假分支——不 append executor 的 WanWo 收敛形态）。
            if let disposer {
                disposer()
                self.disposer = nil
                Self.logger.info("tool_search unregistered (no deferred tools)")
            }
            return
        }
        // 已注册即不再换手：语料新鲜度由 provider 实时读 registry +
        // ToolSearchTool 引擎全等缓存承接（平台差异登记，见文件头）；C7 起
        // description 缓存随本步语料快照同手刷新（registry 锁外调用，防渲染
        // 滞后一步；快照即 refresh 开头 corpus）。
        if disposer != nil {
            if let tool = registry.get("tool_search") as? ToolSearchTool {
                tool.syncCorpus(corpus)
            }
            return
        }
        let tool = ToolSearchTool(corpusProvider: { [weak registry] in
            guard let registry else { return [] }
            return Self.infos(from: registry)
        })
        do {
            disposer = try registry.tryRegister(tool)
            Self.logger.info("tool_search registered (deferred tools=\(corpus.count))")
        } catch {
            // 外来工具已占据 "tool_search" 名：fail contained（codex :379-381
            // remove+collision 记录的 WanWo 可捕获等价——不覆盖外来注册面）。
            Self.logger.error("tool_search registration skipped: " +
                              "\(String(describing: error))")
        }
    }

    /// deferred 工具 → tool_search 语料（C2c：name/description/parameters +
    /// sourceInfo 随行；按 ToolRegistry.deferredTools() 的字典序确定性）。
    private static func infos(from registry: ToolRegistry) -> [ToolSearchInfo] {
        registry.deferredTools().map { tool in
            ToolSearchInfo.from(name: tool.name,
                                description: tool.description,
                                parameters: tool.parameters,
                                sourceInfo: tool.toolSearchSourceInfo)
        }
    }
}
