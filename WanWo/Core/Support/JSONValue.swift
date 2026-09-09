//
//  JSONValue.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §十三.2（工具结果 canonical lossless-JSON
//  契约，附录 B #3）+ dsh packages/core/util-values（JsonValue 词汇的 Swift 形态）。
//  工具参数 / schema / meta 的统一 JSON 载体：可无损编码（lossless），可 Equatable。
//

import Foundation

/// 无损 JSON 值（dsh JsonValue 语义：所有事件载荷与工具 meta 必须可无损序列化）。
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value):
            // ERR-026：Swift 字典的 JSONEncoder 键序不稳定——每轮请求的 tools
            // schema 字节序随机翻转，DeepSeek 前缀缓存从 tools 就断（真机取证
            // firstDiff=1，命中率崩到个位数）。object 按键排序做确定性编码，
            // 嵌套值递归走本 encode（排序语义逐层生效）。
            var keyed = encoder.container(keyedBy: AnyCodingKey.self)
            for key in value.keys.sorted() {
                try keyed.encode(value[key] ?? .null, forKey: AnyCodingKey(key))
            }
        }
    }
}

/// 动态字符串键的 CodingKey（ERR-026 确定性 object 编码用）。
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) { self.stringValue = string; self.intValue = nil }
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension JSONValue {
    /// 从任意 JSONSerialization 兼容对象构造（工具参数解析用；失败返回 nil）。
    init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // 布尔与整型区分（JSONSerialization 把 Bool 表示为 NSNumber）。
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number === NSNumber(value: number.intValue) {
                self = .int(number.intValue)
            } else {
                self = .double(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]:
            var items: [JSONValue] = []
            for item in array {
                guard let converted = JSONValue(any: item) else { return nil }
                items.append(converted)
            }
            self = .array(items)
        case let dict as [String: Any]:
            var fields: [String: JSONValue] = [:]
            for (key, item) in dict {
                guard let converted = JSONValue(any: item) else { return nil }
                fields[key] = converted
            }
            self = .object(fields)
        default: return nil
        }
    }

    /// Any 形态（JSONSerialization 兼容；编码用）。
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map { $0.anyValue }
        case .object(let value):
            var out: [String: Any] = [:]
            for (key, item) in value { out[key] = item.anyValue }
            return out
        }
    }

    // MARK: - 取值便捷器

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        if case .double(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectFields: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayItems: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    // MARK: 取值便捷器（谓词命名族——工具实现按 JSON 形态解参用）

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// object 字段取值（非 object 或缺字段返回 nil）。
    func field(_ key: String) -> JSONValue? {
        objectFields?[key]
    }

    // MARK: - Schema 构建便捷器（工具 parameters 声明用）

    static func schemaObject(properties: [String: JSONValue],
                             required: [String],
                             additionalProperties: Bool = false) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(additionalProperties),
        ])
    }

    static func stringSchema(description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func numberSchema(description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    static func booleanSchema(description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    /// 闭集枚举 schema（dsh escalation schema 形态：`{type:'string', enum:[…],
    /// description}`——registry-global 闭集词汇，如 sandbox_permissions 的
    /// ESCALATION_TARGETS）。
    static func enumSchema(description: String, allowedValues: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(allowedValues.map { .string($0) }),
            "description": .string(description),
        ])
    }
}
