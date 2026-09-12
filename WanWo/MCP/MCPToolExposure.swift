//
//  MCPToolExposure.swift
//  WanWo
//
//  【语义移植 · codex】出处：codex-rs core/src/mcp_tool_exposure.rs:19-20
//  （MAX_AGENT_PLUGIN_MCP_SPEC_BYTES = 8_000 / MAX_AGENT_PLUGIN_MCP_TOTAL_BYTES
//  = 64_000）+ :121-141（逐工具预算判定：单 spec 超 8KB → Hidden；累计 next
//  > 64KB → Hidden 且 running 不前进）+ handlers/mcp.rs:91-93（model_spec_bytes
//  = serde_json::to_vec(spec).len()，compact JSON 字节数）。
//  拍板项 2 条文直读（差异登记）：codex 仅对 agent-plugin 来源的 MCP 工具施加
//  预算（:99-101 is_agent_plugin 门控；非 plugin 恒 fits=true :134-136）；
//  WanWo 无 agent-plugin 词汇 → 全部 MCP 工具一律施加，命名去 AGENT_PLUGIN。
//  施加点（呈报说明）：MCPToolBridge.syncTools Phase1 构建下一世代定义时经
//  MCPToolExposureAccumulator 逐工具判定（注册序 = fetch 序，Phase2 按同序
//  注册——与 codex 注册循环遍历序等价形态）；累计预算按「单 server 单世代」
//  施加（WanWo per-server 两阶段同步无全局 finalize 时机，跨 server 全局累计
//  在本结构下无良定义收敛点——平台结构差异登记）。
//  超限 = Hidden 语义自洽性判定（呈报项）：codex Hidden = 模型不可见但可
//  dispatch；WanWo ToolPipeline.swift:41 对 hidden 一律 UNKNOWN_TOOL 拒绝
//  （fail closed 更严）——WanWo hidden 工具既不进 schemas() 也不进
//  deferredTools() 语料（模型既不可见也不可搜），不存在合法调用路径，判定
//  保留 WanWo 更严语义（合规方向，无功能缺口）。
//  平台差异登记：
//    · model_spec_bytes：codex = create_tool_spec 的 function spec 序列化长度
//      → WanWo = {name, description, parameters} function spec object 的
//      compact JSON 字节数（JSONValue 确定性编码，ERR-026，同 spec 同字节）。
//

import Foundation

/// C4 预算护栏常量与纯函数面（codex mcp_tool_exposure.rs 的 WanWo 形态）。
enum MCPToolExposureBudget {

    /// codex :19 MAX_AGENT_PLUGIN_MCP_SPEC_BYTES（WanWo 施加于全部 MCP 工具，
    /// 命名去 AGENT_PLUGIN——拍板项 2 条文直读）。
    static let maxMCPSpecBytes = 8_000

    /// codex :20 MAX_AGENT_PLUGIN_MCP_TOTAL_BYTES。
    static let maxMCPToolTotalBytes = 64_000

    /// 注册序逐工具批量判定（测试锚用；运行面经 MCPToolExposureAccumulator）。
    /// - Parameters:
    ///   - specBytes: 各工具 model spec 字节数（注册序）。
    ///   - base: 预算内工具的 exposure（MCP 工具 = .deferred，F023）。
    static func exposures(forSpecBytes specBytes: [Int],
                          base: ToolExposure = .deferred) -> [ToolExposure] {
        var accumulator = MCPToolExposureAccumulator()
        return specBytes.map { accumulator.exposure(specBytes: $0, base: base) }
    }

    /// model_spec_bytes 的 WanWo 等价（codex handlers/mcp.rs:91-93：serde_json
    /// compact 序列化长度；JSONValue 确定性编码保证同 spec 同字节）。
    static func modelSpecBytes(name: String,
                               description: String,
                               parameters: JSONValue) -> Int {
        let spec = JSONValue.object([
            "name": .string(name),
            "description": .string(description),
            "parameters": parameters,
        ])
        guard let data = try? JSONEncoder().encode(spec) else { return 0 }
        return data.count
    }
}

/// 逐工具累计判定器（codex :96 agent_plugin_bytes 运行面的 WanWo 形态；
/// 值语义，随注册序单世代推进）。
struct MCPToolExposureAccumulator {

    private(set) var runningBytes = 0

    /// codex :121-141 逐式：单 spec 超 8KB → Hidden（running 不动）；否则
    /// next = running + bytes，next ≤ 64KB 才放行并推进 running（超限 Hidden
    /// 时 running 不前进——后续工具按剩余预算再判，codex :126-132 精确语义）。
    /// - Parameters:
    ///   - specBytes: 本工具 model spec 字节数。
    ///   - base: 预算内工具的 exposure（默认 .deferred，F023）。
    mutating func exposure(specBytes: Int, base: ToolExposure = .deferred) -> ToolExposure {
        guard specBytes <= MCPToolExposureBudget.maxMCPSpecBytes else { return .hidden }
        let next = runningBytes + specBytes
        guard next <= MCPToolExposureBudget.maxMCPToolTotalBytes else { return .hidden }
        runningBytes = next
        return base
    }
}
