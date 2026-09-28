//
//  AgentPath.swift
//  WanWo
//
//  【语义移植 · codex · M7.3 件 H · F050】出处：protocol/src/agent_path.rs
//  逐行翻译（AgentPath newtype + validate_agent_name/validate_absolute_path/
//  validate_relative_reference 三个校验纯函数 + join/resolve 组合面）。
//
//  语义对拍断言（agent_path.rs tests 逐条）：
//    - root_has_expected_name：/root 的 name() == "root"、isRoot() == true。
//    - join_builds_child_paths：root.join("researcher") == "/root/researcher"。
//    - resolve_supports_relative_and_absolute_references：相对引用拼接当前
//      path；"/" 前缀绝对引用直换。
//    - invalid_names_and_paths_are_rejected：非法字符名 / 非 /root 前缀绝对
//      路径 / ".." 上行段全部拒绝（禁 .. 是派单落点③的核心）。
//
//  万我适配裁定（登记）：
//    - Rust TryFrom<&str>/FromStr/Deref/Display 等胶水面 → Swift init(from:)
//      + description/Hashable 等价承载。
//    - 错误面：codex 返回 Result<_, String>（消息即错误）→ SubagentError
//      （message 逐字保留，code = "AGENT_PATH_INVALID"——工具面映射可见）。
//    - /morpheus 特例：codex 内部词汇（validate_absolute_path :150-152 放行），
//      万我无消费者但保留 1:1 语义（validate 放行 + 常量在位），登记不改。
//

import Foundation

/// Hierarchical addressing for agents in a session tree（agent_path.rs:15
/// AgentPath newtype 1:1）。绝对路径以 `/root` 为根；段名仅限小写字母、数字、
/// 下划线；禁 `.`/`..`（无上行）；相对引用按当前 path 拼接。
struct AgentPath: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// agent_path.rs:18。
    static let ROOT = "/root"
    /// agent_path.rs:19（codex 内部特例路径——validate 放行，万我无消费者，登记）。
    static let MORPHEUS = "/morpheus"
    /// agent_path.rs:20。
    static let rootSegment = "root"

    /// agent_path.rs:22-24。
    static func root() -> AgentPath { AgentPath(unchecked: AgentPath.ROOT) }

    /// agent_path.rs:26-28。
    static func morpheus() -> AgentPath { AgentPath(unchecked: AgentPath.MORPHEUS) }

    /// agent_path.rs:30-33（from_string）。
    static func fromString(_ path: String) throws -> AgentPath {
        try validateAbsolutePath(path)
        return AgentPath(unchecked: path)
    }

    /// agent_path.rs:75-89（TryFrom<String>/TryFrom<&str> 等价入口）。
    init(from string: String) throws {
        try Self.validateAbsolutePath(string)
        value = string
    }

    /// 内部直造（root()/morpheus() 等已验证面）。
    private init(unchecked: String) {
        value = unchecked
    }

    /// 底层字符串（agent_path.rs:35-37 as_str / :91-95 Into<String>）。
    let value: String

    var description: String { value }

    /// agent_path.rs:39-41。
    func isRoot() -> Bool {
        value == AgentPath.ROOT
    }

    /// agent_path.rs:43-52（rsplit('/').next().filter(!empty).unwrap_or("root")）。
    func name() -> String {
        if isRoot() { return AgentPath.rootSegment }
        return value.split(separator: "/", omittingEmptySubsequences: false).last
            .flatMap { $0.isEmpty ? nil : String($0) } ?? AgentPath.rootSegment
    }

    /// agent_path.rs:54-57（validate_agent_name 后拼接）。
    func join(_ agentName: String) throws -> AgentPath {
        try Self.validateAgentName(agentName)
        return try AgentPath.fromString("\(value)/\(agentName)")
    }

    /// agent_path.rs:59-72：空拒绝 / == ROOT 直返 / "/" 前缀绝对解析 /
    /// 其余按相对引用校验后拼接。
    func resolve(_ reference: String) throws -> AgentPath {
        if reference.isEmpty {
            throw SubagentError(message: "agent path must not be empty",
                                code: Self.errorCode)
        }
        if reference == AgentPath.ROOT {
            return Self.root()
        }
        if reference.hasPrefix("/") {
            return try AgentPath(from: reference)
        }
        try Self.validateRelativeReference(reference)
        return try AgentPath.fromString("\(value)/\(reference)")
    }

    // MARK: - 校验纯函数（agent_path.rs:125-181 逐语义）

    /// agent_path.rs:125-147 validate_agent_name：非空 / 非 "root" 保留名 /
    /// 非 "."/".."（禁上行）/ 不含 "/" / 仅小写字母数字下划线。
    static func validateAgentName(_ agentName: String) throws {
        if agentName.isEmpty {
            throw SubagentError(message: "agent_name must not be empty",
                                code: errorCode)
        }
        if agentName == AgentPath.rootSegment {
            throw SubagentError(message: "agent_name `root` is reserved",
                                code: errorCode)
        }
        if agentName == "." || agentName == ".." {
            throw SubagentError(message: "agent_name `\(agentName)` is reserved",
                                code: errorCode)
        }
        if agentName.contains("/") {
            throw SubagentError(message: "agent_name must not contain `/`",
                                code: errorCode)
        }
        let allowed = agentName.allSatisfy { character in
            (character.isASCII && character.isLowercase)
                || (character.isASCII && character.isNumber)
                || character == "_"
        }
        if !allowed {
            throw SubagentError(
                message: "agent_name must use only lowercase letters, digits, and underscores",
                code: errorCode)
        }
    }

    /// agent_path.rs:149-171 validate_absolute_path：/morpheus 特例放行 /
    /// 必须以 "/" 开头且首段 == "root" / 不以 "/" 结尾 / 其余段逐段校验。
    static func validateAbsolutePath(_ path: String) throws {
        if path == AgentPath.MORPHEUS { return }
        guard path.hasPrefix("/") else {
            throw SubagentError(
                message: "absolute agent paths must start with `/root` or be `/morpheus`",
                code: errorCode)
        }
        let stripped = String(path.dropFirst())
        let segments = stripped.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let root = segments.first else {
            throw SubagentError(message: "absolute agent path must not be empty",
                                code: errorCode)
        }
        if root != AgentPath.rootSegment {
            throw SubagentError(
                message: "absolute agent paths must start with `/root` or be `/morpheus`",
                code: errorCode)
        }
        if stripped.hasSuffix("/") {
            throw SubagentError(message: "absolute agent path must not end with `/`",
                                code: errorCode)
        }
        for segment in segments.dropFirst() {
            try validateAgentName(segment)
        }
    }

    /// agent_path.rs:173-181 validate_relative_reference：不以 "/" 结尾 /
    /// 逐段 validate_agent_name（".." 在段校验被拒 = 禁上行）。
    static func validateRelativeReference(_ reference: String) throws {
        if reference.hasSuffix("/") {
            throw SubagentError(message: "relative agent path must not end with `/`",
                                code: errorCode)
        }
        for segment in reference.split(separator: "/", omittingEmptySubsequences: false) {
            try validateAgentName(String(segment))
        }
    }

    /// 万我自拟登记：错误分类码（codex 该面无 code——Result<_, String>）。
    static let errorCode = "AGENT_PATH_INVALID"
}
