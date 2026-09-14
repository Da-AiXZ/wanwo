//
//  ToolSdkRenderer.swift
//  WanWo
//
//  【语义移植 · dsh · M5-B P4】出处：dsh packages/core/tools/src/ts-types.ts
//  （317 行全文——jsonSchemaToTs 类型投影 / renderToolsSdk tools:sdk 段全文）
//  + json-schema.ts（enforced subset 走查 checkSchemaNode）+ index.ts:51
//  （PTC_ONLY_INSTRUCTION 逐字）/ :644（ToolPresentationMode 三值语义，语义段
//  :648-657 取证：ptc 下 native 名 toolOrder 无效）/ :826-829（defaultMode ≠
//  native 才注册 collapse/sdk 两段）/ :847-884（collapseSection 'tools:ptc-only'
//  @PTC_ONLY=800 与 sdkSection 'tools:sdk' @TOOLS_SDK=5000，text(context) 回调）。
//
//  登记差异（dsh 对拍）：
//    ① 缺省 mode = .both（WanWo 拍板定稿）——dsh Config 缺省 native
//      （index.ts:823）。.both 下 native 调用照常执行、tools:ptc-only 渲染空
//      （dsh :844 "`both` renders empty" 同语义）。
//    ② JSONValue 值语义（值树、恒 lossless JSON）：json-schema 走查的 realm
//      边界 / 循环引用 / 注解 lossless 检查退化不适用；keyword 子集规则全量保留。
//    ③ schema object 成员序：Swift Dictionary 无插入序 → object 成员（与
//      violation 收集序）按 key 字典序——dsh 保留源序；确定性等价换序（P1
//      登记③同源）。
//    ④ output schema 面：WanWo ToolOutput 无 schema 面 → ToolSdkEntry.output
//      = nil → 成员渲染退化 `JsonValue`（ts-types.ts annotation-only 空对象同形）。
//    ⑤ 动态段落文本不做 {{var}} 二次插值（SDK 文本内嵌任意工具 description，
//      严格插值会令敌意描述炸掉组装——见 PromptAssembler.dynamicSection）。
//    ⑥ subset violation 文案非逐字（P4 呈报登记）；语义对拍保留：每条违规一条
//      消息、路径限定、收集顺序键序化。
//

import Foundation

// MARK: - SDK 条目

/// 单个工具的 SDK 投影条目（dsh ToolSdkSchema 的 WanWo 形态；output 可空——
/// 登记④）。
struct ToolSdkEntry {
    let name: String
    let description: String
    let parameters: JSONValue
    /// 工具绑定返回值的 canonical 输出 schema；nil = WanWo 无 output schema 面。
    let output: JSONValue?
}

// MARK: - 逐字文案

/// ts-types.ts:250-261 / index.ts:51 的逐字文案位。
enum ToolSdkText {
    /// ts-types.ts:250-252 逐字（SDK_INSTRUCTIONS）。
    static let sdkInstructions = "## Writing code for run_code\n\n"
        + "`run_code` takes two required arguments: `code` — the body of an async "
        + "TypeScript function (erasable syntax only — no `enum` or namespaces; type "
        + "annotations are advisory, the code runs type-stripped) — and `description`, "
        + "a short summary of what the program does. The declarations below are SDK "
        + "bindings for this program. A declaration does not make its name a directly "
        + "callable tool; only names supplied as separate tool schemas may be called directly."

    /// ts-types.ts:254-261 逐字（SDK_PROGRAM_INSTRUCTIONS）。
    static let sdkProgramInstructions = "Inside the program:\n\n"
        + "- Call tools as `await tools.name(args)` — quoted access for exotic names: "
        + "`tools[\"my-tool\"](args)`. Every call resolves to the tool's typed canonical "
        + "JSON value. Tool arguments must be lossless JSON.\n"
        + "- A FAILED tool call rejects with `ToolCallError`, whose `toolName` identifies "
        + "the failed tool and whose `message` is human-readable — `try/catch` it to "
        + "handle and continue.\n"
        + "- Independent read-only calls MAY overlap under `Promise.all` (safe calls run "
        + "concurrently; mutating calls run alone, in submission order). Sequence "
        + "dependent work with `await`.\n"
        + "- Emit results with `return` and/or `console.log(...)`. Only what you print "
        + "or return is program output. A successful tool result containing an image is "
        + "attached after the run so you can inspect it on the next step; every other "
        + "intermediate result stays out of the conversation, so extract just what you "
        + "need.\n\nProgram-only SDK bindings:"

    /// index.ts:51 逐字（PTC_ONLY_INSTRUCTION；RUN_CODE_NAME 模板位落字面
    /// run_code——与 dsh 渲染产物逐字相同）。
    static let ptcOnlyInstruction = "`run_code` is the only tool you can call directly "
        + "— a tool call naming any other tool fails. Reach every tool the SDK declares "
        + "below from inside the program."
}

// MARK: - 强制子集走查

/// dsh json-schema.ts enforced subset 走查（checkSchemaNode 显式栈帧同构：
/// type/oneOf/properties/required/additionalProperties/items/enum/const + 注解；
/// 越集/错位 keyword 逐条违规，不喜先抛）。Realm/循环/lossless 检查退化——登记②。
enum JsonSchemaSubsetCheck {
    static let constraintKeywords: Set<String> = [
        "type", "oneOf", "properties", "required", "additionalProperties",
        "items", "enum", "const",
    ]
    static let annotationKeywords: Set<String> = [
        "description", "title", "default", "examples",
    ]
    /// oneOf 旁不得出现的 keyword（json-schema.ts:200）。
    static let oneOfSiblingKeywords = [
        "properties", "required", "additionalProperties", "items", "enum", "const",
    ]
    static let schemaTypes = [
        "object", "array", "string", "number", "integer", "boolean", "null",
    ]

    private enum WalkTask {
        case enter(JSONValue, String)
        case oneOfTail([String: JSONValue], String)
        case objectTail([String: JSONValue], String, JSONValue?)
    }

    /// 走查 schema 树，返回全部违规（每条一消息、路径限定；空 = 合法）。
    /// - Parameters:
    ///   - schema: 任意 JSON 值形态（hostile 输入按违规收集，不抛）。
    ///   - rootPath: 根路径标签（dsh 'schema'）。
    static func violations(in schema: JSONValue, rootPath: String = "schema") -> [String] {
        var violations: [String] = []
        var tasks: [WalkTask] = [.enter(schema, rootPath)]
        while let task = tasks.popLast() {
            switch task {
            case .oneOfTail(let node, let path):
                for key in oneOfSiblingKeywords where node.keys.contains(key) {
                    violations.append("\(path).\(key) is not supported beside oneOf")
                }
            case .objectTail(let node, let path, let properties):
                checkObjectTail(node, path: path, properties: properties,
                                violations: &violations)
            case .enter(let node, let path):
                checkEnter(node, path: path, tasks: &tasks, violations: &violations)
            }
        }
        return violations
    }

    // MARK: 单节点检查

    private static func checkEnter(_ node: JSONValue, path: String,
                                   tasks: inout [WalkTask], violations: inout [String]) {
        guard case .object(let fields) = node else {
            violations.append("\(path) must be a schema object")
            return
        }
        // keyword 白名单（键序化收集——登记③）。
        for key in fields.keys.sorted() {
            if constraintKeywords.contains(key) { continue }
            if annotationKeywords.contains(key) { continue }
            violations.append("\(path).\(key) is not a supported keyword "
                + "(subset: type/oneOf/properties/required/additionalProperties/items/"
                + "enum/const + annotations)")
        }
        if fields.keys.contains("description"), !isString(fields["description"]) {
            violations.append("\(path).description must be a string")
        }
        if fields.keys.contains("title"), !isString(fields["title"]) {
            violations.append("\(path).title must be a string")
        }

        let hasType = fields.keys.contains("type")
        let hasOneOf = fields.keys.contains("oneOf")
        if hasType && hasOneOf {
            violations.append("\(path) cannot declare both type and oneOf")
            return
        }
        if !hasType && !hasOneOf {
            for key in oneOfSiblingKeywords where fields.keys.contains(key) {
                violations.append("\(path).\(key) requires type or oneOf")
            }
            return
        }

        if hasOneOf {
            tasks.append(.oneOfTail(fields, path))
            guard case .array(let branches)? = fields["oneOf"], branches.count >= 2 else {
                violations.append("\(path).oneOf must be an array of at least two schemas")
                return
            }
            for (index, branch) in branches.enumerated() {
                tasks.append(.enter(branch, "\(path).oneOf[\(index)]"))
            }
            return
        }

        guard case .string(let typeText)? = fields["type"],
              schemaTypes.contains(typeText) else {
            if case .array = fields["type"] {
                violations.append("\(path).type must be a single type string "
                    + "(type arrays are not supported)")
            } else {
                violations.append("\(path).type must be one of "
                    + schemaTypes.joined(separator: "/"))
            }
            return
        }

        // keyword 与 type 的错位检查（json-schema.ts:310-322 allowedFor）。
        let allowedFor: [(String, [String])] = [
            ("properties", ["object"]),
            ("required", ["object"]),
            ("additionalProperties", ["object"]),
            ("items", ["array"]),
            ("enum", ["string", "number", "integer", "boolean", "null"]),
            ("const", ["string", "number", "integer", "boolean", "null"]),
        ]
        for (key, types) in allowedFor
        where fields.keys.contains(key) && !types.contains(typeText) {
            violations.append("\(path).\(key) is not supported on type \"\(typeText)\"")
        }

        switch typeText {
        case "object":
            let properties = fields["properties"]
            tasks.append(.objectTail(fields, path, properties))
            if let properties {
                guard case .object(let props) = properties else {
                    violations.append("\(path).properties must be an object of schemas")
                    return
                }
                for (key, child) in props.sorted(by: { $0.key < $1.key }) {
                    tasks.append(.enter(child, "\(path).properties.\(key)"))
                }
            }
        case "array":
            if let items = fields["items"] {
                tasks.append(.enter(items, "\(path).items"))
            }
        default:
            // string/number/integer/boolean/null：字面量约束检查。
            checkScalarConstraints(fields, type: typeText, path: path,
                                   violations: &violations)
        }
    }

    /// json-schema.ts:203-224 checkObjectSchemaTail（required ⊆ properties、
    /// additionalProperties 必须布尔）。
    private static func checkObjectTail(_ node: [String: JSONValue], path: String,
                                        properties: JSONValue?,
                                        violations: inout [String]) {
        if node.keys.contains("required") {
            var shapeValid = false
            var required: [String] = []
            if case .array(let items)? = node["required"] {
                let strings = items.compactMap { entry -> String? in
                    if case .string(let s) = entry { return s }
                    return nil
                }
                if strings.count == items.count {
                    shapeValid = true
                    required = strings
                }
            }
            if !shapeValid {
                violations.append("\(path).required must be an array of strings")
            } else {
                var declared: [String: JSONValue] = [:]
                if case .object(let d)? = properties { declared = d }
                for key in required where !declared.keys.contains(key) {
                    violations.append("\(path).required names \"\(key)\" "
                        + "which is not in properties")
                }
            }
        }
        if node.keys.contains("additionalProperties"), !isBool(node["additionalProperties"]) {
            violations.append("\(path).additionalProperties must be a boolean")
        }
    }

    /// json-schema.ts:352-370：标量 enum/const 形状与匹配检查（enum 非空且
    /// 同型；const 同型；双声明时 const ∈ enum）。
    private static func checkScalarConstraints(_ fields: [String: JSONValue],
                                               type: String, path: String,
                                               violations: inout [String]) {
        var enumValid = false
        if fields.keys.contains("enum") {
            if case .array(let allowed)? = fields["enum"], !allowed.isEmpty,
               allowed.allSatisfy({ scalarMatches(type, $0) }) {
                enumValid = true
            } else {
                violations.append("\(path).enum must be a non-empty array of "
                    + "\(type) values")
            }
        }
        if fields.keys.contains("const") {
            let declared = fields["const"] ?? .null
            if scalarMatches(type, declared) {
                if enumValid,
                   case .array(let allowed)? = fields["enum"], !allowed.contains(declared) {
                    violations.append("\(path).const must be one of \(path).enum "
                        + "when both are declared")
                }
            } else {
                violations.append("\(path).const must be a \(type) value")
            }
        }
    }

    /// json-schema.ts:180-190 scalarMatches（JSONValue 数值形态随行：
    /// .double 积分值即整数）。
    private static func scalarMatches(_ type: String, _ value: JSONValue) -> Bool {
        switch (type, value) {
        case ("string", .string):
            return true
        case ("number", .int), ("number", .double):
            return true
        case ("integer", .int):
            return true
        case ("integer", .double(let d)):
            return d == d.rounded()
        case ("boolean", .bool):
            return true
        case ("null", .null):
            return true
        default:
            return false
        }
    }

    private static func isString(_ value: JSONValue?) -> Bool {
        if case .string = value { return true }
        return false
    }

    private static func isBool(_ value: JSONValue?) -> Bool {
        if case .bool = value { return true }
        return false
    }
}

// MARK: - 类型文档

/// 可拼装类型文档（ts-types.ts:56-92 同构：parts 保留 + 联合/交叉包含判定，
/// 数组元素括号化测试消费）。
indirect enum TypeDoc {
    case text(String)
    case parts([TypeDoc])

    /// ts-types.ts:62-69：parts 中任一字符串含 '|' 或 '&'（或子文档递归含）。
    var containsUnionOrIntersection: Bool {
        switch self {
        case .text(let s):
            return s.contains("|") || s.contains("&")
        case .parts(let parts):
            return parts.contains { $0.containsUnionOrIntersection }
        }
    }

    /// 显式栈展平（ts-types.ts:77-92 flattenTypeDocument 同构）。
    func flattened() -> String {
        var chunks: [String] = []
        var stack: [TypeDoc] = [self]
        while let task = stack.popLast() {
            switch task {
            case .text(let s):
                chunks.append(s)
            case .parts(let parts):
                for part in parts.reversed() { stack.append(part) }
            }
        }
        return chunks.joined()
    }
}

// MARK: - SDK 渲染器

/// PTC mode codegen：注册工具 schema → 模型编程面向的 TypeScript SDK 文本
/// （ts-types.ts 纯投影 1:1）。
enum ToolSdkRenderer {
    /// ts-types.ts:240-247 1:1：强制子集内任意 schema 形态；畸形/越集输入
    /// 退化 'unknown' 不抛（hostile 输入降级）。
    static func jsonSchemaToTs(_ schema: JSONValue, indent: Int = 0) -> String {
        let violations = JsonSchemaSubsetCheck.violations(in: schema)
        guard violations.isEmpty else { return "unknown" }
        return renderSupportedSchema(schema, indent: indent).flattened()
    }

    /// ts-types.ts:297-317 1:1：tools:sdk 段全文——固定用法说明 + 可选 bash
    /// 示例 + `declare const tools` 接口。确定性：按名称字典序，工具集不变
    /// 即逐字节同文（登记③：WanWo 侧 schema object 成员同为字典序）。
    static func renderToolsSdk(_ schemas: [ToolSdkEntry]) -> String {
        let sorted = schemas.sorted { $0.name < $1.name }
        var argsMembers: [String] = []
        var outputMembers: [String] = []
        for schema in sorted {
            argsMembers.append(contentsOf: docLines(schema.description, 1))
            argsMembers.append("\(pad(1))\(renderKey(schema.name)): "
                + "\(jsonSchemaToTs(schema.parameters, indent: 1));")
            // output nil → annotation-only 空对象 → 'JsonValue'（登记④）。
            let output = schema.output ?? .object([:])
            outputMembers.append("\(pad(1))\(renderKey(schema.name)): "
                + "\(jsonSchemaToTs(output, indent: 1));")
        }
        let argsMap = "interface ToolArgsMap {"
            + (argsMembers.isEmpty ? "}" : "\n\(argsMembers.joined(separator: "\n"))\n}")
        let outputMap = "interface ToolOutputMap {"
            + (outputMembers.isEmpty ? "}" : "\n\(outputMembers.joined(separator: "\n"))\n}")
        let declaration = [
            argsMap,
            outputMap,
            "type ToolName = keyof ToolOutputMap",
            [
                "declare class ToolCallError extends Error {",
                "  readonly name: \"ToolCallError\";",
                "  readonly toolName: ToolName;",
                "}",
            ].joined(separator: "\n"),
            [
                "declare const tools: {",
                "  [K in ToolName]: (args: ToolArgsMap[K]) => Promise<ToolOutputMap[K]>;",
                "}",
            ].joined(separator: "\n"),
        ].joined(separator: "\n\n")
        let jsonValue = "type JsonValue = null | boolean | number | string "
            + "| JsonValue[] | { [key: string]: JsonValue }"
        return "\(ToolSdkText.sdkInstructions)\(renderBashExample(sorted))"
            + "\n\n\(ToolSdkText.sdkProgramInstructions)"
            + "\n\n```ts\n\(jsonValue)\n\n\(declaration)\n```"
    }

    // MARK: 渲染栈帧

    /// 单个渲染栈帧（ts-types.ts:95-109 同构）。
    private struct SchemaRenderFrame {
        enum Phase { case start, children }
        enum Kind { case oneOf, array, object }

        let node: JSONValue
        let indent: Int
        var phase: Phase = .start
        var kind: Kind?
        var children: [(JSONValue, Int)] = []
        var childIndex = 0
        var childDocuments: [TypeDoc] = []
        var entries: [(String, JSONValue)] = []
    }

    /// 已断言合法 schema → 类型文档（ts-types.ts:112-230 显式栈帧 1:1）。
    private static func renderSupportedSchema(_ schema: JSONValue,
                                              indent: Int) -> TypeDoc {
        var frames: [SchemaRenderFrame] = [SchemaRenderFrame(node: schema,
                                                             indent: indent)]
        var rootDocument: TypeDoc?

        /// finish：弹帧并把文档交给父帧（ts-types.ts:115-120）。
        func finish(_ document: TypeDoc) {
            if frames.isEmpty {
                rootDocument = document
            } else {
                frames[frames.count - 1].childDocuments.append(document)
            }
        }

        while !frames.isEmpty {
            let i = frames.count - 1
            let frame = frames[i]

            if frame.phase == .children {
                if frame.childIndex < frame.children.count {
                    let child = frame.children[frame.childIndex]
                    frames[i].childIndex += 1
                    frames.append(SchemaRenderFrame(node: child.0, indent: child.1))
                    continue
                }
                // 子帧收齐：按 kind 拼装（ts-types.ts:135-172）。
                frames.removeLast()
                switch frame.kind {
                case .oneOf:
                    var parts: [TypeDoc] = []
                    for (index, child) in frame.childDocuments.enumerated() {
                        if index > 0 { parts.append(.text(" | ")) }
                        parts.append(child)
                    }
                    finish(.parts(parts))
                case .array:
                    let child = frame.childDocuments[0]
                    finish(child.containsUnionOrIntersection
                        ? .parts([.text("("), child, .text(")[]")])
                        : .parts([child, .text("[]")]))
                case .object:
                    finish(renderObjectDocument(frame))
                case .none:
                    // 走查已收窄 kind 必被赋值；防御退化为 unknown。
                    finish(.text("unknown"))
                }
                continue
            }

            // start 相（ts-types.ts:175-225）。防御性 object 解包：走查保证。
            guard case .object(let fields) = frame.node else {
                frames.removeLast()
                finish(.text("unknown"))
                continue
            }
            // 进入 children 相（后续若在本轮直接 finish，此位无害）。
            frames[i].phase = .children

            if case .array(let branches)? = fields["oneOf"] {
                frames[i].kind = .oneOf
                frames[i].children = branches.map { ($0, frame.indent) }
                continue
            }
            guard let typeText = stringField(fields, "type") else {
                // 无 type：任意 JSON 值（ts-types.ts:184-187）。
                frames.removeLast()
                finish(.text("JsonValue"))
                continue
            }
            switch typeText {
            case "string", "number", "integer", "boolean", "null":
                frames.removeLast()
                finish(.text(renderConstrainedScalar(fields, type: typeText)))
            case "array":
                if fields.keys.contains("items"), let items = fields["items"] {
                    frames[i].kind = .array
                    frames[i].children = [(items, frame.indent)]
                } else {
                    frames.removeLast()
                    finish(.text("JsonValue[]"))
                }
            case "object":
                let open = !isExplicitFalse(fields["additionalProperties"])
                let entries = (fields["properties"].flatMap { objectFields(of: $0) } ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { ($0.key, $0.value) }
                if entries.isEmpty {
                    // ts-types.ts:210-211：空对象开/闭形态。
                    frames.removeLast()
                    finish(.text(open ? "Record<string, JsonValue>"
                                      : "Record<string, never>"))
                } else {
                    frames[i].kind = .object
                    frames[i].entries = entries
                    frames[i].children = entries.map { ($0.1, frame.indent + 1) }
                }
            default:
                // 走查已把 type 收窄到闭集；防御退化（ts-types.ts:223-224）。
                frames.removeLast()
                finish(.text("unknown"))
            }
        }

        return rootDocument ?? .text("unknown")
    }

    /// 对象文档拼装（ts-types.ts:156-171；成员键序化——登记③）。
    private static func renderObjectDocument(_ frame: SchemaRenderFrame) -> TypeDoc {
        let required = Set(stringArray(in: frame.node, key: "required"))
        var parts: [TypeDoc] = [.text("{")]
        for (index, entry) in frame.entries.enumerated() {
            let child = frame.childDocuments[index]
            for line in docLines(description(of: entry.1), frame.indent + 1) {
                parts.append(.text("\n"))
                parts.append(.text(line))
            }
            let optionalMark = required.contains(entry.0) ? "" : "?"
            parts.append(.text("\n"))
            parts.append(.text("\(pad(frame.indent + 1))\(renderKey(entry.0))"
                + "\(optionalMark): "))
            parts.append(child)
            parts.append(.text(";"))
        }
        parts.append(.text("\n"))
        parts.append(.text("\(pad(frame.indent))}"))
        let declared = TypeDoc.parts(parts)
        return isExplicitFalse(objectFields(of: frame.node)?["additionalProperties"])
            ? declared
            : .parts([declared, .text(" & Record<string, JsonValue>")])
    }

    /// ts-types.ts:46-53：已断言标量 const/enum 渲染，缺省回落宽类型
    ///（integer → number）。
    private static func renderConstrainedScalar(_ fields: [String: JSONValue],
                                                type: String) -> String {
        let broad = type == "integer" ? "number" : type
        if fields.keys.contains("const"), let c = fields["const"] {
            return jsonScalarText(c)
        }
        if fields.keys.contains("enum"), case .array(let allowed)? = fields["enum"] {
            return allowed.map { jsonScalarText($0) }.joined(separator: " | ")
        }
        return broad
    }

    // MARK: bash 示例

    /// ts-types.ts:263-283 1:1：字面量示例满足当前 bash 参数 schema 才渲染。
    private static func renderBashExample(_ schemas: [ToolSdkEntry]) -> String {
        guard let bash = schemas.first(where: { $0.name == "bash" }) else { return "" }
        guard case .object(let parameters) = bash.parameters,
              stringField(parameters, "type") == "object" else { return "" }
        let required = stringArray(in: bash.parameters, key: "required")
        if required.contains(where: { $0 != "command" && $0 != "description" }) {
            return ""
        }
        let properties = objectFields(of: parameters["properties"] ?? .null) ?? [:]
        guard acceptsExampleString(properties["command"], "pwd") else { return "" }
        let needsDescription = required.contains("description")
        if needsDescription,
           !acceptsExampleString(properties["description"], "Show current directory") {
            return ""
        }
        let description = needsDescription ? ", description: 'Show current directory'" : ""
        return " When no separate `bash` schema is supplied, invoke a declared `bash` "
            + "binding inside `run_code`:\n\n`run_code({ code: \"return await tools.bash("
            + "{ command: 'pwd'\(description) })\", description: \"Show current directory\" })`"
    }

    /// ts-types.ts:264-268：字符串 schema 是否接受示例字面量。
    private static func acceptsExampleString(_ schema: JSONValue?, _ value: String) -> Bool {
        guard case .object(let fields)? = schema,
              stringField(fields, "type") == "string" else { return false }
        if let c = fields["const"], c != .string(value) { return false }
        if case .array(let allowed)? = fields["enum"], !allowed.contains(.string(value)) {
            return false
        }
        return true
    }

    // MARK: 文本基元

    /// ts-types.ts:19-24：合法裸 TS 标识符原样，否则 JSON 字符串字面量
    ///（每个名字都可达、零别名）。
    static func renderKey(_ name: String) -> String {
        if isIdentifier(name) { return name }
        return jsonString(name)
    }

    /// dsh IDENTIFIER = /^[A-Za-z_$][A-Za-z0-9_$]*$/（手写字符判定，语义同型）。
    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isHead(_ s: Unicode.Scalar) -> Bool {
            return (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || s == "$" || s == "_"
        }
        func isTail(_ s: Unicode.Scalar) -> Bool {
            return isHead(s) || (s >= "0" && s <= "9")
        }
        guard isHead(first) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy(isTail)
    }

    /// ts-types.ts:32-38：description 折叠为单行 JSDoc（\s+ → ' '，'*/' →
    /// '*\/' 防提前终止注释），无 description 时无行。
    static func docLines(_ description: String?, _ indent: Int) -> [String] {
        guard let description, !description.isEmpty else { return [] }
        let collapsed = description
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = collapsed.replacingOccurrences(of: "*/", with: "*\\/")
        return ["\(pad(indent))/** \(escaped) */"]
    }

    /// ts-types.ts:27-29：一层两空格缩进。
    static func pad(_ indent: Int) -> String {
        return String(repeating: "  ", count: indent)
    }

    /// JSON.stringify 标量形态（P3 JSONRender.doubleString 复用：积分值无 .0）。
    static func jsonScalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return jsonString(s)
        case .int(let i): return String(i)
        case .double(let d): return JSONRender.doubleString(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return "unknown"  // 标量位只可能收到标量（走查保证）；防御。
        }
    }

    /// JSON 字符串字面量（最小转义：引号/反斜杠/控制字符）。
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: JSONValue 取值缝

    private static func objectFields(of value: JSONValue) -> [String: JSONValue]? {
        if case .object(let fields) = value { return fields }
        return nil
    }

    private static func stringField(_ fields: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let s)? = fields[key] else { return nil }
        return s
    }

    private static func description(of schema: JSONValue) -> String? {
        guard case .object(let fields) = schema else { return nil }
        return stringField(fields, "description")
    }

    /// schema.required 的字符串数组（缺省/畸形回落空集——走查已保证形状）。
    private static func stringArray(in schema: JSONValue, key: String) -> [String] {
        guard case .object(let fields) = schema,
              case .array(let items)? = fields[key] else { return [] }
        return items.compactMap { entry -> String? in
            if case .string(let s) = entry { return s }
            return nil
        }
    }

    /// additionalProperties 是否显式 false（absent/true 跟 JSON Schema 开缺省）。
    private static func isExplicitFalse(_ value: JSONValue?) -> Bool {
        if case .bool(false) = value { return true }
        return false
    }
}

// MARK: - PTC 模式提示词段

/// tools:ptc-only（SECTION_ORDERS.ptcOnly = 800）与 tools:sdk
///（SECTION_ORDERS.toolsSDK = 5000）两段注册（dsh index.ts:826-829——
/// 仅 defaultMode ≠ native 时注册；WanWo 无 scope 链，modeFor 即
/// registry.presentationMode 全局单档）。
enum PtcPromptSections {
    static func registerSections(into assembler: PromptAssembler,
                                 registry: ToolRegistry) {
        guard registry.presentationMode != .native else { return }
        // collapse 宣告段（dsh collapseSection :847-855）：与执行端 collapse
        // 拒绝面同一谓词——提示词不会宣告注册表不执行的规则（:851-853）。
        // both 渲染空（:844）：native 调用在该档位下照常执行。
        assembler.dynamicSection(DynamicPromptSection(
            name: "tools:ptc-only", order: SECTION_ORDERS.ptcOnly) { [weak registry] in
            guard let registry, registry.presentationMode == .ptc else { return "" }
            return ToolSdkText.ptcOnlyInstruction
        })
        // SDK 生成段（dsh sdkSection :867-884）：assemble 时从注册表现状重新
        // 生成（MCP 工具异步激活后静态文本会陈旧）；native 渲染空（段落被
        // 丢弃）。运行时恒 TypeScript——SDK_RENDERERS['typescript'] 单投影。
        assembler.dynamicSection(DynamicPromptSection(
            name: "tools:sdk", order: SECTION_ORDERS.toolsSDK) { [weak registry] in
            guard let registry, registry.presentationMode != .native else { return "" }
            return ToolSdkRenderer.renderToolsSdk(registry.sdkSchemas())
        })
    }
}
