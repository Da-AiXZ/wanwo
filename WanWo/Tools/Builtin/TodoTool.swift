//
//  TodoTool.swift
//  WanWo
//
//  【语义移植 · dsh · M7 件 A · F049】出处（analysis/dsh-upstream-m5/packages/todo/tool-todo/src/
//  逐文件对拍）：
//    - index.ts:45-78 —— 工具 description 三段拼装（HEAD + SINGLE/PARALLEL + TAIL）逐字。
//    - index.ts:91-111 —— toTodoList：trim 非空 / 去重 / allowParallelInProgress=false 时
//      in_progress ≤ 1（万我部署配置定为 false——简报拍板）。
//    - index.ts:146-168 —— parameters schema 1:1（todos 数组 required；条目
//      content/status enum；additionalProperties: false）。
//    - index.ts:169-219 —— output（todos + counts{pending,inProgress,completed}）与
//      render 文案逐字；execute：校验 → append 'todo/write' → 返回。
//    - index.ts:221 —— presentCall：{ card: 'generic', title: 'Update todo list' }。
//    - types.ts:21-26 —— TodoItem 刻意最小（content + status 三态；无 id/priority——
//      整表替换下条目无需稳定身份）。
//    - types.ts:28-33 —— 'todo/write' 事件 = "Log-only UI state; never derived
//      history" → 万我 extensionEvent 通道 kind="todo/write"，projection=.logOnly。
//    - invariant.ts:16-39 —— 形状不变量（数组/条目对象/content 非空已 trim/去重/
//      status 合法）；刻意不校验 in_progress 数（策略非形状）——TodoInvariants 1:1。
//
//  适配裁定（登记）：
//    - dsh exec.agent.session.append → 万我写柄构造期捕获（工具每会话装配，
//      等价 owning agent session）；非 agent caller 拒绝（index.ts:206-208）由
//      "工具只在会话栈内注册"结构性保证。
//    - "todo/write 必须在开放 turn 内"（invariant.ts:57）写侧：万我工具只在
//      turn/step 管线内执行，结构性满足；replay 侧校验见 TodoInvariants.validate。
//    - 深度形状校验（invariant.ts）不在 ExtensionEventRegistry schema（字段级
//      表达力边界）——写侧 toTodoList + 读侧 TodoInvariants 双向承接。
//

import Foundation

// MARK: - 事件注册（extensionEvent 通道；装配期幂等注册）

/// todo 域的 extensionEvent 注册面（简报件 A 拍板：kind="todo/write"，
/// requiredFields=[todos(array)]，projection=.logOnly）。进程级注册表重名
/// fatal——多会话装配走 isRegistered 幂等门。
enum TodoEvents {
    /// wire type = "extension/todo/write"。
    static let writeKind = "todo/write"

    /// 装配期注册（幂等；AppEnvironment.makeAgentStack 调用）。
    static func register() {
        guard !ExtensionEventRegistry.shared.isRegistered(writeKind) else { return }
        ExtensionEventRegistry.shared.register(ExtensionEventSchema(
            kind: writeKind,
            requiredFields: [ExtensionFieldSchema("todos", .array)],
            projection: .logOnly))
    }
}

// MARK: - 数据结构（types.ts:21-26 1:1）

/// 条目生命周期三态（types.ts:25 注释逐字语义）。
enum TodoStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case pending
    case inProgress = "in_progress"
    case completed
}

/// 单条 todo（types.ts:21-26 1:1：刻意无 id/priority——整表替换下无需稳定身份）。
struct TodoItem: Equatable, Codable, Sendable {
    /// What this task is — a short imperative line shown in the UI.
    var content: String
    /// Lifecycle state.
    var status: TodoStatus

    enum CodingKeys: String, CodingKey {
        case content, status
    }
}

// MARK: - 形状不变量（invariant.ts 1:1）

/// 包内持久 todo 快照不变量（invariant.ts:16-39 逐条对拍）。
enum TodoInvariants {
    /// 校验一份整表快照载荷（invariant.ts:24-39 1:1）。
    /// 刻意不校验 in_progress 数——那是工具的 per-deployment 策略
    /// （Config.allowParallelInProgress），不是持久形状规则（invariant.ts:16-23
    /// 注释逐字语义：策略收紧后历史仍须可 replay）。
    /// - Returns: nil = 合法；否则返回首个违规文案（fail loud 文案与 dsh 同源）。
    static func validateTodos(_ payload: JSONValue) -> String? {
        guard let items = payload.arrayItems else {
            return "todo/write todos must be an array"
        }
        var seen = Set<String>()
        for item in items {
            guard item.objectValue != nil else {
                return "todo/write entries must be objects"
            }
            guard let content = item.field("content")?.stringValue,
                  !content.isEmpty, content.trimmingCharacters(in: .whitespacesAndNewlines) == content else {
                return "todo/write content must be non-empty and already trimmed"
            }
            if seen.contains(content) {
                return "todo/write repeats content \"\(content)\""
            }
            seen.insert(content)
            guard let status = item.field("status")?.stringValue,
                  TodoStatus(rawValue: status) != nil else {
                return "todo/write carries unknown status \(item.field("status")?.stringValue ?? "nil")"
            }
        }
        return nil
    }

    /// 全量 replay 校验（invariant.ts:42-69 逐语义：todo/write 形状 + 开放
    /// turn 内判定；turnTrace 沿事件流推进）。事件载荷 = {todos:[...]}（对象），
    /// 形状不变量作用于 todos 数组本体。
    /// - Returns: nil = 日志合法；否则返回首个违规文案。
    static func validate(events: [SessionEvent]) -> String? {
        var turnOpen = false
        for event in events {
            switch event.payload {
            case .extensionEvent(TodoEvents.writeKind, let payload):
                // 载荷缺 todos 字段 = 写侧 schema 门已失守（unregistered 旧构
                // 建产物）——同文案 fail loud。
                guard let todos = payload.field("todos") else {
                    return "todo/write todos must be an array"
                }
                if let reason = validateTodos(todos) { return reason }
                if !turnOpen {
                    return "todo/write appended outside any open turn"
                }
            case .turnStart:
                turnOpen = true
            case .turnEnd:
                turnOpen = false
            default:
                break
            }
        }
        return nil
    }
}

// MARK: - 投影（dsh sessionProjections 'todos' fold 1:1）

/// UI 消费端纯函数投影（index.ts:130-145 语义 1:1）：
///   · `todo/write` → 整表（last-write-wins）；
///   · `turn/start` → null（清空——"cleared by the next turn/start"）；
///   · `turn/end` → 不清（"keeps the finished checklist visible"）；
///   · 无关事件 → 原状态不变。
/// 万我值语义无引用相等——UI 层以 `Equatable` 比较实现零重渲染（登记）。
enum TodoProjection {
    /// 从事件流折叠当前 todo 清单；nil = 首写前/新回合开始后的空态。
    static func fold(events: [SessionEvent]) -> [TodoItem]? {
        var state: [TodoItem]?
        for event in events {
            switch event.payload {
            case .extensionEvent(TodoEvents.writeKind, let payload):
                if let todos = decodeTodos(payload) { state = todos }
            case .turnStart:
                state = nil
            default:
                break
            }
        }
        return state
    }

    /// 'todo/write' 载荷 → 条目数组（载荷形状 = {todos:[...]} 对象——与
    /// TodoTool.payload(for:) / TodoInvariants.validate 的取字段口径一致；
    /// 畸形载荷返回 nil = 保持原状态；写侧 schema 已 fail closed，此处软化
    /// 仅为防御 replay 时未注册 schema 的旧构建产物）。
    static func decodeTodos(_ payload: JSONValue) -> [TodoItem]? {
        guard let items = payload.field("todos")?.arrayItems else { return nil }
        var todos: [TodoItem] = []
        for item in items {
            guard let content = item.field("content")?.stringValue,
                  let rawStatus = item.field("status")?.stringValue,
                  let status = TodoStatus(rawValue: rawStatus) else { return nil }
            todos.append(TodoItem(content: content, status: status))
        }
        return todos
    }
}

// MARK: - 校验错误

/// toTodoList 的域内校验失败（文案与 dsh index.ts:98/:101/:108 逐字对齐）。
struct TodoValidationError: Error {
    let message: String
}

// MARK: - 工具

/// todo_write（F049）：模型面整表替换工具（dsh tool-todo index.ts apply 1:1）。
struct TodoTool: AgentTool {
    let name = "todo_write"

    /// description（index.ts:45-78 describe(false) 逐字——万我
    /// allowParallelInProgress=false 拍板档）。
    let description: String

    /// 参数 schema（index.ts:146-168 1:1）。
    let parameters: JSONValue

    /// 会话写柄（构造期捕获 = dsh exec.agent.session 等价；登记见头注）。
    let writer: SessionWriter

    /// 部署策略：是否允许多条 in_progress（万我定为 false——简报拍板）。
    let allowParallelInProgress: Bool

    init(writer: SessionWriter, allowParallelInProgress: Bool = false) {
        self.writer = writer
        self.allowParallelInProgress = allowParallelInProgress
        self.description = Self.describe(allowParallel: allowParallelInProgress)
        self.parameters = Self.buildParameters()
    }

    /// index.ts:74-78 describe 1:1。
    static func describe(allowParallel: Bool) -> String {
        let head = "Record and update a structured task list for the current work. Send the ENTIRE "
            + "list every call — it REPLACES the previous list (there are no partial updates, "
            + "no per-item edits). Use it to plan multi-step work and show progress: add one "
            + "todo per concrete step before you start. "
        let parallel = "Mark every todo being actively worked "
            + "on `in_progress` — several at once when work genuinely runs in parallel (e.g. "
            + "concurrent subagents or background commands), one for sequential work; while "
            + "work remains, at least one task should be `in_progress`. "
        let single = "Keep AT MOST ONE todo `in_progress` at a "
            + "time; while work remains, exactly one active task should be `in_progress`. "
        let tail = "Mark a todo "
            + "`completed` the moment it is done (do not batch completions), and allow no "
            + "`in_progress` item only once all work is complete. Skip the list for trivial "
            + "single-step tasks. Statuses: `pending` (not started), `in_progress` (being "
            + "worked on now), `completed` (finished)."
        return head + (allowParallel ? parallel : single) + tail
    }

    /// index.ts:149-168 parameters 1:1。
    static func buildParameters() -> JSONValue {
        .schemaObject(
            properties: [
                "todos": .object([
                    "type": .string("array"),
                    "description": .string("The COMPLETE task list, replacing any previous list."),
                    "items": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "properties": .object([
                            "content": .object([
                                "type": .string("string"),
                                "required": .bool(true),
                                "description": .string("What the task is — a short imperative line."),
                            ]),
                            "status": .object([
                                "type": .string("string"),
                                "required": .bool(true),
                                "enum": .array(TodoStatus.allCases.map { .string($0.rawValue) }),
                                "description": .string("pending (not started) | in_progress (now) | completed (done)."),
                            ]),
                        ]),
                    ]),
                ]),
            ],
            required: ["todos"])
    }

    // MARK: - 校验 + canonical 化（index.ts:91-111 toTodoList 1:1）

    /// 模型入参 → canonical TodoItem 数组：trim 非空 / 去重 / 策略校验。
    static func toTodoList(_ raw: [JSONValue],
                           allowParallelInProgress: Bool) throws -> [TodoItem] {
        var todos: [TodoItem] = []
        var seen = Set<String>()
        var active = 0
        for item in raw {
            guard let contentRaw = item.field("content")?.stringValue else {
                throw TodoValidationError(message: "invalid todo: `content` must be a non-empty string")
            }
            let content = contentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty {
                throw TodoValidationError(message: "invalid todo: `content` must be a non-empty string")
            }
            if seen.contains(content) {
                throw TodoValidationError(message: "invalid todos: duplicate content \"\(content)\"")
            }
            seen.insert(content)
            guard let statusRaw = item.field("status")?.stringValue,
                  let status = TodoStatus(rawValue: statusRaw) else {
                throw TodoValidationError(
                    message: "invalid todos: unknown status \(item.field("status")?.stringValue ?? "nil")")
            }
            if status == .inProgress { active += 1 }
            todos.append(TodoItem(content: content, status: status))
        }
        if !allowParallelInProgress && active > 1 {
            throw TodoValidationError(
                message: "invalid todos: at most one task may be in_progress (got \(active))")
        }
        return todos
    }

    // MARK: - 载荷与输出

    /// 'todo/write' 载荷（{todos: [{content, status}]}；dsh append 数据形状）。
    static func payload(for todos: [TodoItem]) -> JSONValue {
        .object(["todos": .array(todos.map { item in
            .object(["content": .string(item.content),
                     "status": .string(item.status.rawValue)])
        })])
    }

    /// output 结构（index.ts:169-197；WanWo 以 lossless JSON meta 承载结构化面）。
    static func outputValue(_ todos: [TodoItem]) -> JSONValue {
        func count(_ status: TodoStatus) -> Int {
            todos.filter { $0.status == status }.count
        }
        return .object([
            "todos": .array(todos.map { item in
                .object(["content": .string(item.content),
                         "status": .string(item.status.rawValue)])
            }),
            "counts": .object([
                "pending": .int(count(.pending)),
                "inProgress": .int(count(.inProgress)),
                "completed": .int(count(.completed)),
            ]),
        ])
    }

    /// render 文案（index.ts:198-201 逐字）。
    static func renderOutput(_ todos: [TodoItem]) -> String {
        func count(_ status: TodoStatus) -> Int {
            todos.filter { $0.status == status }.count
        }
        return "Updated todo list: \(count(.pending)) pending, "
            + "\(count(.inProgress)) in progress, \(count(.completed)) completed."
    }

    // MARK: - 执行（index.ts:203-219 execute 1:1）

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // dsh：registry 已 enforce schema（todos required）；此处运行时复核
        // （缺参 fail closed，同 AskUserTool 语义）。
        guard let rawItems = args.field("todos")?.arrayItems else {
            return .failure("invalid todos: `todos` must be an array",
                            code: "INVALID_ARGS", name: "TodoError")
        }
        let todos: [TodoItem]
        do {
            todos = try Self.toTodoList(rawItems, allowParallelInProgress: allowParallelInProgress)
        } catch let error as TodoValidationError {
            return .failure(error.message, code: "INVALID_TODOS", name: "TodoError")
        }
        // append 'todo/write'（dsh exec.agent.session.append 1:1；写侧 schema
        // 门在 SessionWriter.appendOnce——违例即抛，不静默落盘）。
        _ = try await writer.append(.extensionEvent(
            kind: TodoEvents.writeKind, payload: Self.payload(for: todos)))
        return .success(Self.renderOutput(todos), meta: Self.outputValue(todos))
    }

    // MARK: - 呈现（index.ts:221 presentCall 1:1）

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(title: "Update todo list")
    }
}
