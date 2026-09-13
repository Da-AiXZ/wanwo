//
//  CodeRuntime.swift
//  WanWo
//
//  【M5-B 批 P1 · CodeRuntime 词汇缝（F013 类型面——PTC 执行底座抽象契约）】
//  纯词汇件零 IO。出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/code-runtime/code-runtime/src/types.ts（131 行全文）：
//    - :18      CodeBindingFunction = (args) => Promise<CodeJsonValue>——args 与
//      resolution 必须无损 JSON（"A runtime rejects a lossy or non-cloneable
//      value with a descriptive error"；:14 注释）；binding 拒绝 = 程序内对位
//      调用的 rejection（:16 注释——Swift 形态 = async throws，见适配登记①）
//    - :21      CodeJsonValue = null|bool|number|string|数组|对象递归——Swift
//      复用既有 JSONValue（Core/Support；int/double 双 case 承载 number，
//      无损等价，见适配登记②）
//    - :30-40   CodeBindingErrorClass{name/memberNameProperty}——name 同
//      global 的可移植标识符规则（:31 注释）；memberNameProperty 排他集 =
//      RESERVED_ERROR_MEMBERS + dunder 全拒，其余任意名（含非标识符）全后端
//      接受（:35-38 注释逐条）
//    - :49-65   CodeBindingNamespace{global/functions/errorClass?}——global
//      必须跨语言可移植：[A-Za-z_][A-Za-z0-9_]* 且非任一语言保留字
//      （:54 "a JS-only spelling like `$tools` is rejected by design, not
//      just by the Python backend"）；functions 键任意字符串——runtime 必须把
//      `__proto__`/`constructor` 当普通 own property（null-prototype 构造，
//      :45-47 注释；Swift 字典天然 own-key 语义，见适配登记③）
//    - :73-89   CodeRunRequest{program/bindings/signal?}——program 以 async
//      function body 语义运行（top-level await/return 合法，completion value
//      = value，:75-79 注释）；signal hard stop even mid-loop + in-flight
//      binding calls 是 CALLER 的结算责任（:86 注释；Swift 映射见适配登记④）
//    - :103-108 CodeRunFailure 六类（kind/message）——六类正交独立（:92-94
//      "a budget expiry is not an exception, an abort is not a timeout, a
//      substrate death is neither"）；逐类语义注释逐条移植（:96-101）
//    - :115-131 CodeRunResult{value?/logs/error?}——**error 是字段不是
//      rejection**（:111-113 "reporting a failed program is the caller's job,
//      not an exception path"）；无效/超限 completion = 失败 run 而非替换
//      渲染串（:119-121 注释）；logs 各通道保序、跨通道交错 backend 相关
//      （:124-125 注释）
//  packages/code-runtime/code-runtime/src/index.ts（137 行全文）：
//    - :37-42   RESERVED_BINDING_GLOBALS 五条逐字——每条目为什么保留的注释
//      逐条移植（console=worker 日志捕获槽；__dsh_main__/__builtins__/
//      __name__=Python bootstrap 包装与种子全局；__debug__=CPython 编译期
//      常量 True 注入不可达，:33-37 注释）；共享集而非各后端只拒自己的槽
//      （:25-28 注释——可移植承诺的实体）
//    - :49-57   RESERVED_ERROR_MEMBERS 六条（JS Error 排他 + Python 异常
//      协议成员）；dunder 全拒的原因（多个是受约束的 CPython 描述符，
//      setattr 在构造 rejection 时 raise，确切集合是解释器版本细节，:50-52）
//    - :59-63   DUNDER_MEMBER = /^__.+__$/（`__` 与 `____` 空中段不匹配，
//      reserved.spec.ts:38-41 对拍）
//    - :65-86   PORTABLE_RESERVED_WORDS 全集（ECMAScript 段 :77-81 五行 48 词
//      + Python 3.x 段 :84-85 两行 23 词，含软关键字 type/_；合计 71）——
//      "Extending the seam with a new language means widening this union
//      (a breaking review of existing binding names, by design)"（:72-73）
//    - :94-135  CodeRuntime 抽象类——language/isolation 信息性非门控（well-
//      known 值 'typescript'/'python'、'worker-thread'/'process'/'container'）
//      + 实现义务五条逐条移植（:96-99 类 doc：structured-cloneable bindings
//      桥接 / 物化每命名空间拒绝类 / 把程序当敌对同侪对待 / 隔离 runs 相互
//      无状态 / disposal 时终止并 await 在飞 runs）
//  校验文案锚（worker-thread 实现侧，本件逐字移植——派单授权）：
//  packages/code-runtime/code-runtime-worker-thread/src/index.ts:
//    - :73      IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/
//    - :320-361 validateBindings 七查（契约误用 = run() reject 的唯一面；
//      程序面失败走 result.error 字段，:285-289 doc 注释区分）：
//      :324 "dsh-code-runtime-worker-thread: binding global X is not a
//            usable identifier"（标识符失败 ∪ 保留字，同分支）
//      :333 "dsh-code-runtime-worker-thread: reserved binding global X"
//      :336 "dsh-code-runtime-worker-thread: duplicate binding global X"
//      :346 "dsh-code-runtime-worker-thread: binding error class X is not a
//            usable identifier"
//      :349 "dsh-code-runtime-worker-thread: reserved binding global X"
//            （error class 名撞 backend 槽同文案）
//      :352 "dsh-code-runtime-worker-thread: duplicate injected global X"
//            （error class 名撞 namespace global 或先行 error class 名）
//      :356 "dsh-code-runtime-worker-thread: binding error member property
//            Y is not usable"（空 ∪ RESERVED_ERROR_MEMBERS ∪ dunder 同分支）
//      （X = JSON.stringify 名——Swift 形态 jsonQuoted；"dsh-code-runtime-
//      worker-thread:" 前缀逐字保留登记——它命名缝契约的原出处，见适配登记⑤）
//  对拍测试锚：packages/code-runtime/code-runtime/tests/reserved.spec.ts:15-57。
//
//  WanWo 形态适配（登记）：
//    ① CodeBindingFunction = (JSONValue) async throws -> JSONValue——dsh 的
//      Promise rejection（:16 binding 拒绝 = 程序内对位调用 rejection）以
//      Swift throws 承载；args 直接收 JSONValue（无损由类型面保证，dsh
//      unknown→运行时校验的等价物）。
//    ② CodeJsonValue → 既有 JSONValue（enum null/bool/int/double/string/
//      array/object）：number 以 int/double 双 case 无损承载；object 键为
//      Swift 字典 own key——`__proto__`/`constructor` 键无原型冲突面（dsh
//      null-prototype 语义的 Swift 天然等价）。
//    ③ functions 键任意字符串（[String: CodeBindingFunction]）——Swift 字典
//      天然把 `__proto__`/`constructor` 当普通 own key（dsh :45-47 语义）。
//    ④ signal → Task cancellation（J1 裁定延续）：CodeRunRequest 不设 signal
//      字段——run 在 Task 内执行，Task.isCancelled 检查点即 signal.aborted；
//      hard stop even mid-loop = 运行时检查点粒度；in-flight binding calls
//      结算责任在 caller（types.ts:86 注释语义随请求承载）。
//    ⑤ 校验文案 "dsh-code-runtime-worker-thread:" 前缀逐字保留（对拍纪律）；
//      未来 WanWo 后端实现件（P2/P3）若换前缀属消费面裁定，本件锚原样。
//    ⑥ cordis Service/Context 面不移植——Swift protocol（CodeRuntimeProtocol）
//      + AppEnvironment 装配注入（ShellTool.jobs/SandboxProvider 同款缝）。
//

import Foundation

// MARK: - 值词汇（types.ts）

/// Host 侧暴露给程序的 async callable（types.ts:18）。args 与 resolution 必须
/// 无损 JSON——Swift 形态 args/resolution 直接收发 JSONValue（无损由类型面
/// 保证）；throws = dsh Promise rejection 形态（程序内对位调用的 rejection，
/// types.ts:16 注释语义）。无 seam 级字节上限（:15 注释）。
typealias CodeBindingFunction = @Sendable (_ args: JSONValue) async throws -> JSONValue

/// 一次性类型化拒绝契约（types.ts:30-40）：runtime 在 `name` 下注入真 error
/// 构造器，被拒成员调用成为其实例并经 `memberNameProperty` 暴露确切成员名。
/// 两者皆为 runtime 数据（:27-28 注释——非 PTC 之类特定消费者的知识）。
struct CodeBindingErrorClass: Equatable, Sendable {
    /// 构造器全局名与最终 `Error.name`；同 CodeBindingNamespace.global 的
    /// 可移植标识符规则（types.ts:31 注释）。
    let name: String
    /// 成员名的非空 own property；排他集 = RESERVED_ERROR_MEMBERS + dunder
    /// 全拒，其余任意名（标识符与否皆可）全后端接受（types.ts:35-38）。
    let memberNameProperty: String

    init(name: String, memberNameProperty: String) {
        self.name = name
        self.memberNameProperty = memberNameProperty
    }
}

/// 一组以单全局对象暴露给程序的 host 函数（types.ts:49-65，如 `tools`）。
struct CodeBindingNamespace: Sendable {
    /// 程序可见的全局标识符：LANGUAGE-PORTABLE 子集
    /// `[A-Za-z_][A-Za-z0-9_]*` 且非任一语言保留字（`$tools` 一类 JS-only
    /// 拼写被设计性拒绝——types.ts:54）；命中 backend 槽
    /// （RESERVED_BINDING_GLOBALS，如 `console`/`__dsh_main__`）同样全后端
    /// 拒绝（types.ts:56-58）。
    let global: String
    /// callable 成员，键 = 程序调用的确切名。键任意字符串——runtime 必须把
    /// `__proto__`/`constructor` 当普通 own property（null-prototype 构造，
    /// types.ts:45-47；Swift 字典 own-key 天然等价，适配登记③）。
    let functions: [String: CodeBindingFunction]
    /// 可选的程序可见类型化拒绝契约。
    let errorClass: CodeBindingErrorClass?

    init(global: String,
         functions: [String: CodeBindingFunction] = [:],
         errorClass: CodeBindingErrorClass? = nil) {
        self.global = global
        self.functions = functions
        self.errorClass = errorClass
    }
}

/// 一次运行：程序源 + runtime 作用的一切（types.ts:73-89）。显式优于隐式：
/// 缺省（时间预算、输出上限）是实现的已校验配置——请求不携带留给隐藏 `??`
/// 填充的可选旋钮（types.ts:69-71 注释）。
struct CodeRunRequest: Sendable {
    /// 程序源（runtime 的 language 写就）。以 async function body 语义运行：
    /// top-level `await`/`return` 可用，completion value 成为
    /// CodeRunResult.value（types.ts:75-79 注释）。
    let program: String
    /// 暴露给程序的 host 函数，一 namespace 一全局对象。
    let bindings: [CodeBindingNamespace]
    // signal 适配登记④：dsh AbortSignal → Task cancellation（J1 裁定延续）。
    // run 在 Task 内执行，Task.isCancelled 检查点即 signal.aborted；hard stop
    // even mid-loop = 检查点粒度；in-flight binding calls 是 CALLER 的结算
    // 责任——runtime 只停止询问（types.ts:86 注释语义）。

    init(program: String, bindings: [CodeBindingNamespace] = []) {
        self.program = program
        self.bindings = bindings
    }
}

// MARK: - 失败与结果（types.ts:103-131）

/// run 失败的原因类别（types.ts:105 六类闭集；rawValue = wire 词汇）。
/// 六类正交独立（types.ts:92-94 注释逐句）：预算到期不是异常、中止不是超时、
/// 底座死亡两者皆不是。
enum CodeRunFailureKind: String, Equatable, Sendable, CaseIterable {
    /// 程序抛出或解析/变换失败（types.ts:96）。
    case exception = "exception"
    /// 实现持有的预算到期；message 说明是哪个（types.ts:97）。
    case timeout = "timeout"
    /// 请求的取消信号触发（types.ts:98——signal→Task cancellation，登记④）。
    case abort = "abort"
    /// 执行底座未结算即死亡（如 OOM）（types.ts:99）。
    case workerExit = "worker-exit"
    /// completion value 不是无损 JSON（types.ts:100）。
    case invalidOutput = "invalid-output"
    /// 序列化后的外层 logs/value/diagnostic 超出配置上限（types.ts:101）。
    case outputLimit = "output-limit"
}

/// 一次 run 失败的结构（types.ts:103-108）。
struct CodeRunFailure: Equatable, Sendable {
    /// 失败类别（见各 kind 的类型注释）。
    let kind: CodeRunFailureKind
    /// 人读细节，适合回喂模型自我纠正（types.ts:106 注释）。
    let message: String

    init(kind: CodeRunFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// 一次 run 的结果（types.ts:115-131）。**error 是字段不是 rejection**——
/// 报告失败程序是 caller 的事，不是异常路径（types.ts:111-113 注释逐句）。
struct CodeRunResult: Equatable, Sendable {
    /// 程序 completion value（top-level `return`），仅当运行到底且值穿过
    /// runtime 的无损 JSON 边界。无效/超限 completion 使 run 失败而非替换
    /// 渲染串；失败或无值 run 缺省此字段（types.ts:119-121 注释）。
    let value: JSONValue?
    /// 捕获文本。各源通道保序；独立通道间交错 backend 相关（types.ts:124-125）。
    /// 仅作为外层结果的一部分受界。
    let logs: [String]
    /// 当且仅当 run 失败时在场（types.ts:130）。
    let error: CodeRunFailure?

    init(value: JSONValue? = nil, logs: [String] = [], error: CodeRunFailure? = nil) {
        self.value = value
        self.logs = logs
        self.error = error
    }
}

// MARK: - 保留字常量（index.ts:37-86 逐字）

/// 缝词汇常量与纯函数（dsh code-runtime index.ts 的导出面；Swift enum 无
/// 实例命名空间）。
enum CodeRuntimeSeam {

    /// 所有后端都拒绝的 binding 全局名（index.ts:39-42 逐字集）。某后端拥有
    /// 该槽故共享集拒绝——`console`（worker 日志捕获槽）、`__dsh_main__`/
    /// `__builtins__`/`__name__`（Python bootstrap 包装与种子全局）、
    /// `__debug__`（CPython 把裸引用编译为常量 True 且编译期拒绝赋值——注入
    /// 的全局不可达，index.ts:33-37 注释；共享集让「一后端有效的 namespace
    /// 表处处有效」的承诺成立，index.ts:25-28 注释）。注意与 error members
    /// 不同：binding globals 只拒列出的名，不拒 dunder 形态整体
    /// （index.ts:31-32 注释）。
    static let reservedBindingGlobals: Set<String> = [
        "console",
        "__dsh_main__", "__builtins__", "__name__", "__debug__",
    ]

    /// 所有后端都拒绝的 errorClass.memberNameProperty（index.ts:54-57 逐字集）：
    /// JS `Error` 排他（name/message/stack）+ Python 异常协议成员
    /// （args/with_traceback/add_note）。dunder 形态全拒——多个是受约束的
    /// CPython 描述符，setattr 在构造 rejection 时 raise，确切集合是解释器
    /// 版本细节（index.ts:50-52 注释）；其余任意非空 own property 名全后端接受。
    static let reservedErrorMembers: Set<String> = [
        "name", "message", "stack",
        "args", "with_traceback", "add_note",
    ]

    /// 可移植保留字全集（index.ts:75-86 逐字，注释逐段移植）——ECMAScript ∪
    /// Python 的 reserved words，所有后端拒绝为 global / error-class 名。
    /// 扩缝即加宽并集（对既有 binding 名的破坏性复审，设计如此——
    /// index.ts:72-73 注释）。ECMAScript 段 48 词（reserved-in-strict-mode
    /// 含 implements/interface/package/private/protected/public/arguments/
    /// eval 与 let/static/yield）；Python 3.x 段 23 词（软关键字 type/_
    /// 实践中合法，此处为安全起保留——index.ts:82-83 注释）。合计 71 词。
    static let portableReservedWords: Set<String> = [
        // ECMAScript reserved words and reserved-in-strict-mode names.
        // (index.ts:77-81 五行逐字)
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in",
        "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof",
        "var", "void", "while", "with", "yield", "let", "static", "implements", "interface", "package",
        "private", "protected", "public", "arguments", "eval",
        // Python 3.x keywords and soft keywords not already above ('type' and '_'
        // are soft keywords: legal names in practice, reserved here for safety).
        // (index.ts:84-85 两行逐字)
        "False", "None", "True", "and", "as", "assert", "async", "def", "del", "elif", "except", "from",
        "global", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "match", "type", "_",
    ]

    /// 可移植标识符（worker index.ts:73 IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/
    /// 1:1）：首字符字母/下划线，余字符字母/数字/下划线，全 ASCII。
    static func isPortableIdentifier(_ name: String) -> Bool {
        var checkedFirst = false
        for scalar in name.unicodeScalars {
            let isLetter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            let isDigit = scalar >= "0" && scalar <= "9"
            if !checkedFirst {
                checkedFirst = true
                if !(isLetter || scalar == "_") { return false }
            } else if !(isLetter || isDigit || scalar == "_") {
                return false
            }
        }
        return checkedFirst
    }

    /// dunder 形态（index.ts:63 DUNDER_MEMBER = /^__.+__$/ 1:1）：`__x__`
    /// 非空中段。`__` 与 `____` 空中段不匹配（reserved.spec.ts:38-41 对拍——
    /// `__` 无中段；`____` 两个 `__` 对之间也无中段）；单字符中段是最短真
    /// dunder 形态（spec.ts:42-43）。
    static func isDunderMember(_ name: String) -> Bool {
        return name.hasPrefix("__") && name.hasSuffix("__") && name.count > 4
    }

    /// 错误文案里的名字渲染 = JSON.stringify(String) 的 Swift 形态
    /// （validateBindings 文案逐字的必要件——引号与转义同 JS）。
    static func jsonQuoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let quoted = String(data: data, encoding: .utf8) else {
            // 编码不可达面：回落最小引号形态（防御性，文案完整性优先）。
            return "\"\(value)\""
        }
        return quoted
    }

    // MARK: 绑定量校验（worker index.ts:320-361 validateBindings 逐查逐文案）

    /// 契约误用错误（dsh validateBindings 的 plain Error + message 形态；
    /// run() 只因契约误用 reject——程序面失败走 result.error 字段，worker
    /// index.ts:285-289 doc 注释的两态区分）。
    struct ContractError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 校验请求的绑定量（worker validateBindings :320-361 逐查移植）——纯
    /// 函数零 IO，P2/P3 消费面复用。校验序：①每 namespace global 三查
    /// （标识符∪保留字 / backend 槽 / 重复）②errorClass 三查（名标识符∪
    /// 保留字 / backend 槽 / 与 namespace global 或先行 error class 撞名）
    /// ③memberNameProperty 排他集（空 ∪ RESERVED_ERROR_MEMBERS ∪ dunder）。
    /// - Throws: `ContractError`（message = dsh 文案逐字，名字经 jsonQuoted）。
    static func validateBindings(_ bindings: [CodeBindingNamespace]) throws {
        var seenGlobals = Set<String>()
        // 第一轮：namespace global（worker :322-339 逐序）。
        for namespace in bindings {
            // :323-324——标识符失败与保留字同分支同文案。
            if !isPortableIdentifier(namespace.global)
                || portableReservedWords.contains(namespace.global) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "binding global \(jsonQuoted(namespace.global)) "
                    + "is not a usable identifier")
            }
            // :332-334——共享 backend 槽集（注释语义见 reservedBindingGlobals）。
            if reservedBindingGlobals.contains(namespace.global) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "reserved binding global \(jsonQuoted(namespace.global))")
            }
            // :335-337。
            if seenGlobals.contains(namespace.global) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "duplicate binding global \(jsonQuoted(namespace.global))")
            }
            seenGlobals.insert(namespace.global)
        }

        // 第二轮：errorClass（worker :341-359 逐序）。
        var errorClassNames = Set<String>()
        for namespace in bindings {
            guard let descriptor = namespace.errorClass else { continue }
            // :345-347。
            if !isPortableIdentifier(descriptor.name)
                || portableReservedWords.contains(descriptor.name) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "binding error class \(jsonQuoted(descriptor.name)) "
                    + "is not a usable identifier")
            }
            // :348-350——error class 名撞 backend 槽 = 同 reserved binding
            // global 文案（它同样是注入全局）。
            if reservedBindingGlobals.contains(descriptor.name) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "reserved binding global \(jsonQuoted(descriptor.name))")
            }
            // :351-353——撞 namespace global 或先行 error class 名。
            if seenGlobals.contains(descriptor.name)
                || errorClassNames.contains(descriptor.name) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "duplicate injected global \(jsonQuoted(descriptor.name))")
            }
            // :354-357——空 ∪ 排他集 ∪ dunder 同分支同文案。
            let member = descriptor.memberNameProperty
            if member.isEmpty
                || reservedErrorMembers.contains(member)
                || isDunderMember(member) {
                throw ContractError(message: "dsh-code-runtime-worker-thread: "
                    + "binding error member property \(jsonQuoted(member)) "
                    + "is not usable")
            }
            errorClassNames.insert(descriptor.name)
        }
    }
}

// MARK: - 抽象缝（index.ts:94-135 的 Swift protocol 形态）

/// 代码执行能力缝：对一个 host async bindings 运行一段模型写的程序。
/// Runtimes 不知道 tools 与 sessions——那些是消费者的关切（index.ts:2-3 模块
/// doc 逐句）。cordis Service/Context 面不移植（适配登记⑥）。
protocol CodeRuntimeProtocol: Sendable {
    /// `run` 期望 program 写就的源语言，小写标识符。**信息性非门控**——
    /// 消费者据此生成语言特定呈现（typed SDK stubs、使用说明），无法呈现的
    /// 语言 fail loud（index.ts:102-109 注释）。Well-known：'typescript'/
    /// 'python'（TS 后端已发布；Python 后端实验性且私有，index.ts:107-109）。
    var language: String { get }

    /// 执行底座，小写标识符。**信息性非门控**——供部署与诊断区分 backend 的
    /// 描述符，不是安全声明（index.ts:113-119 注释）。Well-known：
    /// 'worker-thread'/'process'/'container'。
    var isolation: String { get }

    /// 对请求的 bindings 执行一个程序并捕获其产出（index.ts:125-134）。
    /// **error 是结果字段，rejection 只意味着 Service Definition 契约误用**
    /// （index.ts:126-127 类 doc；契约校验面见 CodeRuntimeSeam.validateBindings
    /// ——Swift 形态把 reject 面独立为 throwing 校验函数，run 本体不 throws）。
    /// 实现义务（index.ts:96-99 类 doc 逐条）：
    ///   · structured-cloneable bindings 桥接（无损 JSON 边界，types.ts:11-14）；
    ///   · 物化每个声明的 namespace 拒绝类；
    ///   · 把程序当敌对同侪对待（hostile peers）；
    ///   · 隔离 runs——相互无状态；
    ///   · disposal 时终止并 await 在飞 runs（worker teardown :278-283 形态：
    ///     在飞 run 全部落 kind='abort'、message='runtime disposed' 后等退出）。
    /// - Parameter request: 程序、bindings 与取消语义（signal→Task
    ///   cancellation，登记④）；请求携带 runtime 作用的一切，无隐藏缺省。
    /// - Returns: run 结果——completion value（可迁移时）、保序日志、失败
    ///   （如有）。
    func run(_ request: CodeRunRequest) async -> CodeRunResult
}
