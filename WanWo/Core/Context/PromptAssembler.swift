//
//  PromptAssembler.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/system-prompt/src/index.ts
//  （SECTION_ORDERS 布局表、assemble 合并/排序、renderPrompt 严格 {{var}} 插值——
//  未知/畸形即抛错、toolOrder 与 `<unlisted-tools>` rest 标记、工具 schema 收集
//  toolOrder 校验）+ 10-design §5.2/§5.7（F035）+ 附录 B #7。
//

import Foundation

/// 中央段落布局位（dsh SECTION_ORDERS 1:1；M2 用到的子集 + 其余位保留原数值防漂移）。
enum SECTION_ORDERS {
    static let harnessIdentity = -1000
    static let harnessSource = -900
    static let webSurface = -800
    static let deploymentPersona = 0
    static let planPolicy = 500
    static let ptcOnly = 800
    static let fileReference = 900
    static let toolBash = 1000
    static let toolRead = 1100
    static let toolWrite = 1200
    static let toolEdit = 1300
    static let toolGlob = 1400
    static let toolGrep = 1500
    static let toolReadImage = 1600
    static let toolStrReplaceEditor = 1700
    static let toolWebSearch = 2000
    static let toolWebFetch = 2100
    static let toolsSDK = 5000
    static let structuredOutput = 9900
}

/// 动态上下文位（dsh CONTEXT_ORDERS）。
enum CONTEXT_ORDERS {
    static let sandboxPolicy = 110
    static let approvalPolicy = 115
    static let runtimeSnapshot = 120
}

/// toolOrder 中未列出工具的 rest 标记（dsh TOOL_ORDER_REST 原样保留）。
enum TOOL_ORDER_REST {
    static let marker = "<unlisted-tools>"
}

/// 一段已注册的系统提示词段落（静态文本；可含 {{var}} 引用）。
struct PromptSection {
    var name: String
    var order: Int
    var text: String
}

/// 一段动态上下文（runtime-context 快照组成项）。
struct PromptContextEntry {
    var name: String
    var order: Int
    var text: String
}

/// 系统提示词组装器（F035）。M2 形态：注册制段落/上下文/变量 + 严格插值 +
/// 工具 schema toolOrder 排序；scoped shadow（per-scope）随 M4/SideSession 落地。
final class PromptAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var sections: [String: PromptSection] = [:]
    private var contexts: [String: PromptContextEntry] = [:]
    private var variables: [String: String] = [:]
    /// toolOrder（含且必须含一次 rest 标记；nil = 按名称字典序）。
    private var toolOrder: [String]?

    private static let variableNamePattern = "^[a-z][a-z0-9_]*$"

    // MARK: - 注册

    func section(_ section: PromptSection) {
        lock.lock()
        defer { lock.unlock() }
        if sections[section.name] != nil {
            fatalError("prompt section \"\(section.name)\" is already registered")
        }
        sections[section.name] = section
    }

    func context(_ entry: PromptContextEntry) {
        lock.lock()
        defer { lock.unlock() }
        if contexts[entry.name] != nil {
            fatalError("prompt context \"\(entry.name)\" is already registered")
        }
        contexts[entry.name] = entry
    }

    /// 注册/更新变量值（未知名在插值时抛错——严格性在渲染端强制）。
    func setVariable(_ name: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        variables[name] = value
    }

    /// 配置 toolOrder（dsh validateToolOrder：重复名即抛；必须含 rest 标记）。
    func setToolOrder(_ order: [String]?) {
        guard let order else {
            lock.lock()
            toolOrder = nil
            lock.unlock()
            return
        }
        var seen = Set<String>()
        for name in order {
            if seen.contains(name) {
                fatalError("toolOrder lists \"\(name)\" more than once")
            }
            seen.insert(name)
        }
        if !seen.contains(TOOL_ORDER_REST.marker) {
            fatalError("toolOrder must contain the \"\(TOOL_ORDER_REST.marker)\" rest entry")
        }
        lock.lock()
        toolOrder = order
        lock.unlock()
    }

    // MARK: - 组装

    /// 组装请求头（system 渲染 + 工具 schema 排序）。
    /// - Parameter knownNames: toolOrder 校验名集（M4-C6：registry.knownNames
    ///   全集，含 deferred/hidden——收窄集会把 toolOrder 合法列出的 MCP deferred
    ///   工具名误判为未注册；nil = 回落 schema 收窄集，dsh 原语义）。
    /// - Throws: 未知/畸形 {{var}} 引用（严格插值，dsh renderPrompt 语义）。
    func assemble(toolSchemas: [ToolSchemaEntry],
                  knownNames: [String]? = nil) throws -> (system: String,
                                                           contextSnapshot: String,
                                                           tools: [ToolSchemaEntry]) {
        lock.lock()
        let sectionSnapshot = sections.values.sorted {
            $0.order != $1.order ? $0.order < $1.order : $0.name < $1.name
        }
        let contextSnapshotEntries = contexts.values.sorted {
            $0.order != $1.order ? $0.order < $1.order : $0.name < $1.name
        }
        let variableSnapshot = variables
        let order = toolOrder
        lock.unlock()

        // 1. 段落严格插值 → 非空段落按序拼接（空段落丢弃，dsh renderPrompt）。
        var rendered: [String] = []
        for section in sectionSnapshot {
            let text = try Self.interpolate(section.text, variableSnapshot,
                                            kind: "section", name: section.name)
            if !text.isEmpty { rendered.append(text) }
        }
        let system = rendered.joined(separator: "\n\n")

        // 2. 动态上下文快照（dsh joinContextSections 包裹语）。
        var contextParts: [String] = []
        for entry in contextSnapshotEntries {
            let text = try Self.interpolate(entry.text, variableSnapshot,
                                            kind: "context", name: entry.name)
            if !text.isEmpty { contextParts.append(text) }
        }
        let contextSnapshot: String
        if contextParts.isEmpty {
            contextSnapshot = ""
        } else {
            contextSnapshot = "Current runtime context. This snapshot supersedes earlier "
                + "runtime-context snapshots.\n\n" + contextParts.joined(separator: "\n\n")
        }

        // 3. 工具 schema 排序（dsh orderTools：rest 标记位插入未列出工具的字典序）。
        let tools = Self.orderTools(toolSchemas, order,
                                    knownNames: knownNames.map(Set.init))

        return (system, contextSnapshot, tools)
    }

    /// dsh orderTools 1:1：未知配置名即抛；已知但被隐藏的名字允许缺席。
    /// M4-C6：`knownNames` 校验名集与模型可见 schema 集解耦——deferred/hidden
    /// 工具（如 MCP 工具名）可被 toolOrder 合法列出而不进请求 tools 数组
    /// （输出循环按名查找落空即跳过，语义=缺席）；nil = 回落 schema 收窄集
    /// （dsh 原语义，既有调用面/测试不受扰）。
    static func orderTools(_ tools: [ToolSchemaEntry], _ toolOrder: [String]?,
                           knownNames: Set<String>? = nil) -> [ToolSchemaEntry] {
        guard let toolOrder else {
            return tools.sorted { $0.name < $1.name }
        }
        let known = knownNames ?? Set(tools.map { $0.name })
        let unknown = toolOrder.filter { $0 != TOOL_ORDER_REST.marker && !known.contains($0) }
        if !unknown.isEmpty {
            fatalError("toolOrder lists unregistered tools \(unknown.joined(separator: ", ")); known tools: \(known.sorted().joined(separator: ", "))")
        }
        let listed = Set(toolOrder)
        let rest = tools.filter { !listed.contains($0.name) }.sorted { $0.name < $1.name }
        var out: [ToolSchemaEntry] = []
        for name in toolOrder {
            if name == TOOL_ORDER_REST.marker {
                out.append(contentsOf: rest)
            } else if let tool = tools.first(where: { $0.name == name }) {
                out.append(tool)
            }
        }
        return out
    }

    // MARK: - 严格插值（dsh interpolate 1:1）

    /// `{{var}}` 严格插值：畸形（有开无闭且后随闭括号）、未知名、无值 → 抛错；
    /// 孤立 `{{`（其后无任何 `}}`）为字面文本；替换值不再二次扫描。
    static func interpolate(_ text: String,
                            _ variables: [String: String],
                            kind: String,
                            name: String) throws -> String {
        var result = ""
        var last = text.startIndex
        var searchFrom = text.startIndex
        while let open = text.range(of: "{{", range: searchFrom..<text.endIndex) {
            // 找配对的 }}（只在开括号之后）。
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else {
                // 后无任何 }}：字面文本（dsh：lone {{ 是 prose）。
                result += String(text[last..<open.upperBound])
                last = open.upperBound
                searchFrom = open.upperBound
                continue
            }
            let varName = String(text[open.upperBound..<close.lowerBound])
            // 名字合法性（dsh VARIABLE_NAME）。
            guard matchesVariableName(varName) else {
                throw PromptAssemblyError.malformedVariable(
                    "{{\(varName)}}", kind: kind, name: name)
            }
            guard variables.keys.contains(varName) else {
                let known = variables.keys.sorted().joined(separator: ", ")
                throw PromptAssemblyError.unknownVariable(
                    "{{\(varName)}}", kind: kind, name: name,
                    known: known.isEmpty ? "(none)" : known)
            }
            guard let value = variables[varName] else {
                throw PromptAssemblyError.unassignedVariable(
                    "{{\(varName)}}", kind: kind, name: name)
            }
            result += String(text[last..<open.lowerBound]) + value
            last = close.upperBound
            searchFrom = close.upperBound
        }
        result += String(text[last...])
        return result
    }

    private static func matchesVariableName(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: variableNamePattern) else {
            return false
        }
        let range = NSRange(name.startIndex..., in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// 组装错误（dsh interpolate 抛错的 Swift 形态）。
    enum PromptAssemblyError: Error, CustomStringConvertible {
        case malformedVariable(String, kind: String, name: String)
        case unknownVariable(String, kind: String, name: String, known: String)
        case unassignedVariable(String, kind: String, name: String)

        var description: String {
            switch self {
            case .malformedVariable(let ref, let kind, let name):
                return "malformed prompt variable reference \(ref) in \(kind) \"\(name)\""
            case .unknownVariable(let ref, let kind, let name, let known):
                return "unknown prompt variable \(ref) in \(kind) \"\(name)\"; registered variables: \(known)"
            case .unassignedVariable(let ref, let kind, let name):
                return "prompt variable \(ref) has no value for this assembly (\(kind) \"\(name)\")"
            }
        }
    }
}
