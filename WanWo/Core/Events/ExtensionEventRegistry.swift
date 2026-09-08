//
//  ExtensionEventRegistry.swift
//  WanWo
//
//  【M3 E1 · 事件词汇扩展通道注册表】出处：10-design v2.4 修订①（用户拍板
//  "改造吧"，2026-09-09）——dsh merge-extensible 的 Swift 移植：
//    · SessionEvent 专用 case 集合永久冻结，新事件种类一律走 extensionEvent 通道；
//    · 每种新事件在所属功能模块注册 {kind, schema 必填字段, 投影规则, 配对规则}；
//    · 解码按注册 schema 逐字段校验，缺字段/类型错/值非法 → fail closed 拒该条；
//      未知 kind 解码透传 + 消费侧跳过 + 扫描计数（旧版本读新日志不崩）；
//    · 纪律：新增 extension 事件种类仍属显式设计决策，报批登记后方可实现。
//  E1 交付机制与五消费方默认处理，不注册任何业务事件（T2 的 approval/policy
//  到 T2 批次注册时走报批流程）。
//

import Foundation

// MARK: - 投影规则

/// 派生/UI 投影规则（v2.4 修订①「投影规则 log-only|model-visible」）。
enum ExtensionEventProjection: String, Equatable, Sendable {
    /// 默认：不进派生历史、不渲染聊天流（诊断页透传可见）。
    case logOnly
    /// 进派生历史（标准信封 user 消息，DeriveFold）+ 聊天流 note 气泡
    ///（ConversationProjector）。首个 model-visible 业务事件注册时可按需
    /// 细化专属表示，机制位一次到位。
    case modelVisible
}

// MARK: - 配对规则

/// 配对规则（v2.4 修订①「配对规则」；extension 默认非配对）。
enum ExtensionEventPairing: Equatable, Sendable {
    /// 非配对（默认）：单条自足，不参与成对校验与中断修复。
    case none
    /// 应答配对（dsh approval/asked↔approval/decided 的 requestId 语义）：
    /// 本 kind 为「开」事件，以 payload 指定字段（字符串键）登记；closeKind
    /// 的 extension 事件消费该键。close 侧键必须命中开集，否则不变量违例
    ///（SessionInvariant fail closed）。
    case answeredBy(closeKind: String, keyField: String)
}

// MARK: - 字段 schema

/// 单字段 schema（解码/写侧共用的逐字段校验规则）。
struct ExtensionFieldSchema: Equatable, Sendable {
    /// 期望类型（JSONValue 形态闭集；number 同时接受 int/double）。
    enum FieldType: Equatable, Sendable {
        case string, int, number, bool, object, array
    }

    let name: String
    let type: FieldType
    /// 值域（可选）：非 nil 时字段值必须命中其中之一（枚举值非法校验）。
    let allowedValues: [JSONValue]?

    init(_ name: String, _ type: FieldType, allowedValues: [JSONValue]? = nil) {
        self.name = name
        self.type = type
        self.allowedValues = allowedValues
    }
}

// MARK: - 事件 schema

/// 一种 extension 事件的完整注册项。
struct ExtensionEventSchema: Sendable {
    /// wire kind（wireType = "extension/\(kind)"；数据侧 kind 与 wire 一致性
    /// 由 SessionEvent 解码强制）。
    let kind: String
    /// 必填字段清单（逐字段：在场 + 类型 + 可选值域）。
    let requiredFields: [ExtensionFieldSchema]
    /// 投影规则（DeriveFold / ConversationProjector 分流依据）。
    let projection: ExtensionEventProjection
    /// 配对规则（SessionInvariant 分流依据；默认 .none）。
    let pairing: ExtensionEventPairing

    init(kind: String,
         requiredFields: [ExtensionFieldSchema] = [],
         projection: ExtensionEventProjection = .logOnly,
         pairing: ExtensionEventPairing = .none) {
        self.kind = kind
        self.requiredFields = requiredFields
        self.projection = projection
        self.pairing = pairing
    }
}

// MARK: - 注册表

/// 模块内扩展事件注册表（进程级单例；读多写少，NSLock 保护）。
/// E1 出厂零注册；注册入口供 T2+ 功能模块在装配期调用（重名 fatal——
/// 装配期错误立即失败优于静默覆盖，dsh NamedEntries 唯一性语义）。
final class ExtensionEventRegistry: @unchecked Sendable {
    /// 注册项违例（写侧门抛出；解码侧转为 DecodingError.dataCorrupted）。
    struct SchemaViolation: Error, Equatable {
        let kind: String
        let reason: String
    }

    static let shared = ExtensionEventRegistry()

    private let lock = NSLock()
    private var schemas: [String: ExtensionEventSchema] = [:]

    private init() {}

    /// 注册一种 extension 事件 schema；重名即 fatal（装配期 fail loud）。
    /// kind 允许含 "/"（如 "approval/policy"——wire 解析取 "extension/" 后的
    /// 全缀，wire/data kind 一致性由 SessionEvent 解码的 equality 校验强制）。
    func register(_ schema: ExtensionEventSchema) {
        lock.lock()
        defer { lock.unlock() }
        precondition(!schema.kind.isEmpty, "extension event kind must not be empty")
        if schemas[schema.kind] != nil {
            fatalError("extension event kind \"\(schema.kind)\" is already registered")
        }
        schemas[schema.kind] = schema
    }

    func schema(for kind: String) -> ExtensionEventSchema? {
        lock.lock()
        defer { lock.unlock() }
        return schemas[kind]
    }

    func allSchemas() -> [ExtensionEventSchema] {
        lock.lock()
        defer { lock.unlock() }
        return Array(schemas.values)
    }

    func isRegistered(_ kind: String) -> Bool {
        schema(for: kind) != nil
    }

    /// 投影规则（未注册 kind 一律 .logOnly——消费侧默认跳过口径）。
    func projectionRule(for kind: String) -> ExtensionEventProjection {
        schema(for: kind)?.projection ?? .logOnly
    }

    /// 配对规则（未注册 kind 一律 .none）。
    func pairingRule(for kind: String) -> ExtensionEventPairing {
        schema(for: kind)?.pairing ?? .none
    }

    /// schema 校验（解码与写侧共用；nil = 合法，否则返回首个违规原因文案）。
    /// 未注册 kind 一律合法（透传口径）——校验只对已注册 kind 生效。
    func validationReason(kind: String, payload: JSONValue) -> String? {
        guard let schema = schema(for: kind) else { return nil }
        return Self.validationReason(payload: payload, schema: schema)
    }

    /// 逐字段校验（纯函数；fail closed 文案自解释——F060 最小纪律）。
    static func validationReason(payload: JSONValue, schema: ExtensionEventSchema) -> String? {
        guard case .object(let fields) = payload else {
            return "payload must be a JSON object"
        }
        for field in schema.requiredFields {
            guard let value = fields[field.name] else {
                return "missing required field \"\(field.name)\""
            }
            guard Self.matches(field.type, value) else {
                return "field \"\(field.name)\" expected \(field.type), got \(value)"
            }
            if let allowed = field.allowedValues, !allowed.contains(value) {
                return "field \"\(field.name)\" value not in allowed set"
            }
        }
        return nil
    }

    private static func matches(_ type: FieldType, _ value: JSONValue) -> Bool {
        switch (type, value) {
        case (.string, .string): return true
        case (.int, .int): return true
        case (.number, .int), (.number, .double): return true
        case (.bool, .bool): return true
        case (.object, .object): return true
        case (.array, .array): return true
        default: return false
        }
    }

    /// 单测隔离（@testable 专用；生产代码禁用）。
    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        schemas.removeAll()
    }
}
