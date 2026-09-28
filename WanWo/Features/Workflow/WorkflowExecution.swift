//
//  WorkflowExecution.swift
//  WanWo
//
//  【语义移植 · dsh · M7.4 件 K · F047】一次 run 的脚本执行核心（workflow-
//  worker-thread/src/runtime.ts 全文对拍 + realm.ts 物化 1:1 + 已定适配①-⑤）：
//    - runtime.ts:40-42   —— SUPPORTED_AGENT_OPTIONS{label,phase,schema,provider,
//      model} / DEFERRED{effort,isolation,agentType}（拒绝文案逐字）。
//    - runtime.ts:53-57   —— defaultLabel（prompt 首行 ≤48，超出 47+'…'）。
//    - runtime.ts:65-115  —— 构造（先编译：body 语法错误在任何 realm 状态前
//      抛出——万我引擎侧 JSCheckScriptSyntax 预解析承载，登记）；五钩子注入
//      （agent/parallel/pipeline 冻结函数语义 = 脚本覆写自己的钩子只自伤）。
//    - runtime.ts:123-152 —— isCancelled 方法化 / throwIfCancelled（取消 =
//      下一钩子边界，phase/log 也拦）/ cancel（首个 reason 胜；排队槽位拒绝）。
//    - runtime.ts:163-188 —— drive()（永不 reject；脚本前已取消则 body 不执行；
//      settle 后取消检查；raw undefined → null；物化失败 = RESULT_UNSERIALIZABLE）。
//    - runtime.ts:228-248 —— FIFO 槽 acquire/release（排队等待者被 cancel 拒绝；
//      调用方自守入槽后窗口）。
//    - runtime.ts:251-346 —— agent() 钩子（校验 → 总数帽 → seq/label/phase →
//      acquire → 二次取消检查 → start → 二次取消（弃子）→ agentStart → result
//      → completed{schema?structured:文本} / cancelled 抛 / failed null →
//      agentEnd 配对 → dispose → releaseSlot）。
//    - runtime.ts:349-399 —— readAgentOptions（plain JSON 物化 → 对象 → 白名单
//      → deferred 三项逐字 → 字符串校验 → schema 子集）。
//    - runtime.ts:402-459 —— parallel()/pipeline()（数组/逐项函数校验 →
//      per-item catch：fatal 重抛、其余 null；pipeline 无跨 stage 屏障，
//      stage 收 (prev, item, index)）。
//    - runtime.ts:461-487 —— itemCap（文案逐字）/ phase()（非空 title）/
//      log()（string 即可，空串放行）。
//    - realm.ts:28-151    —— renderThrown（stack→message→String，total）+
//      materializeFromRealm 1:1（非有限数/bigint/function/symbol/嵌套 undefined/
//      环/稀疏数组/数组非索引属性/symbol 键/异型原型逐条拒绝；__proto__ 键
//      defineProperty 落 own 数据属性）。
//
//  已定适配兑现（派单裁定①-⑤）：
//    ① 引擎 = JavaScriptCore + Watchdog：每 run 新建独立 JSContext（realm
//      隔离等价 vm.createContext）；JSContextGroupSetExecutionTimeLimit
//      （JSContextRefPrivate.h，ios(7.0)+，头不在公开 Swift 伞内——照
//      Core/Ptc/JSCodeRuntime.swift 已兑现模式 dlsym(RTLD_DEFAULT) 取符；
//      JSContextGroupRef 经公开 C API JSContextGetGroup(context.
//      jsGlobalContextRef)）。Watchdog = dsh runInContext timeout 1:1（per
//      JS 进入段计时；JSC Watchdog.cpp enter/re-evaluate 语义）——超时中断
//      回调映射 SCRIPT_TIMEOUT error result。
//    ② 无 worker RPC：协议层省略，脚本钩子直接宿主回调；ChildPort 进程内直连。
//    ③ 协作取消：取消旗标在每钩子调用前检查（throwIfCancelled），命中抛
//      CANCELLED；disposeGraceMs 宽限 + 超时弃 context（JCore 无 terminate
//      的兜底=弃用，见 WorkflowRunHandle）。
//    ④ 脚本线程：专用 serial DispatchQueue（每 run 一条；同步 JS 不占主线程；
//      watchdog 由 JSC 内部线程触发）。
//    ⑤ 静态预检不另做（Watchdog 已补强杀层；引擎仅做 dsh 同款语法预解析）。
//
//  JCore 单 realm 桥接形态（登记）：
//    - fatal 标记不可伪造（QA-7 P2③ 诚实登记）：钩子拒绝的错误由宿主 helper
//      （jsHelperSource）经闭包私有 Symbol 标记——该 Symbol 不在全局/
//      registry，正常面脚本不可达（dsh instanceof WorkflowError 的单 realm
//      等价；isFatal = 宿主 helper 函数，逻辑宿主自有）。边界诚实声明：
//      同 context 词法面（Function 构造器/eval 类逃逸）理论可达该 Symbol；
//      影响有界（脚本自伤自身 realm 的判定面，无宿主资产暴露），修复成本
//      （独立 realm 隔离）不值本批，登记。
//    - 同步钩子（phase/log）经 makeSyncHook 包装器抛错（JSContext ObjC 块
//      无法跨边界 throw；包装器读 {thrown} 哨兵后 throw——错误对象由宿主
//      helper 构造，fatal 标记随行）。
//    - 物化 = helper 内 realm.ts 1:1 移植（宿主自有 JS 代码遍历+校验+拷贝，
//      JSON.stringify 输出——校验后的拷贝 stringify 全程安全）；Swift 侧
//      JSONDecoder 解回 JSONValue。
//    - microtask 泵：JSContext ObjC API 每次 native→JS 调用返回时排空微任务
//      （JSCodeRuntime deferred 桥同款实证）；钩子 deferred 的 resolve/reject
//      一律在 run 队列调用（JS 单线程纪律）。
//    - Watchdog stop box Unmanaged.passRetained 不释放（QA-7 P2⑦ 修正）：
//      JSCodeRuntime:1411 实际有 release 平衡（先例注释"不释放"失实）；
//      本实现不释放是防 use-after-free 的选择——interruptCallback 在 VM
//      线程持 box 引用，与 abandon 路径的释放存在竞速，保住引用换取每 run
//      一次性的微泄漏，登记。
//

import Foundation
import Darwin
import JavaScriptCore

// MARK: - Watchdog 硬停（JSCodeRuntime.swift:624-640 同款取符模式）

/// dlsym 取得的 JSContextGroupSetExecutionTimeLimit（nil = Watchdog 不可用
/// ——退化面登记⑦同款：热循环 run 挂起；真机/CI 正常路径符号必在）。
private typealias WorkflowSetExecutionTimeLimitFn = @convention(c) (
    JSContextGroupRef?, Double,
    (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?,
    UnsafeMutableRawPointer?
) -> Void

private let workflowSetExecutionTimeLimit: WorkflowSetExecutionTimeLimitFn? = {
    // RTLD_DEFAULT = (void*)-2——全已加载镜像搜索（含本进程链接的 JavaScriptCore）。
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: -2))
    guard let symbol = dlsym(defaultHandle, "JSContextGroupSetExecutionTimeLimit") else {
        return nil
    }
    return unsafeBitCast(symbol, to: WorkflowSetExecutionTimeLimitFn.self)
}()

/// Watchdog 中断回调的 data 载荷（VM 线程入口；fire 一次 → run 队列结算）。
final class WorkflowStopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let queue: DispatchQueue
    private weak var execution: WorkflowExecution?

    init(queue: DispatchQueue, execution: WorkflowExecution) {
        self.queue = queue
        self.execution = execution
    }

    /// Watchdog 线程入口：无条件终止当前 JS 段 + SCRIPT_TIMEOUT 结算。
    func fire() {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        guard first else { return }
        queue.async { [weak execution] in
            execution?.timeoutTerminal()
        }
    }

    /// 是否已 fire（自然结算路径让位面——SCRIPT_TIMEOUT 文案权威归
    /// timeoutTerminal 携带，Terminated/解析失败面不得抢先结算）。
    var isFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

// MARK: - FIFO 槽（runtime.ts:228-248 1:1）

/// Concurrency-slot 信号量（FIFO；cancel 拒绝排队等待者——每个等待者恰好
/// 一次 resume；调用方自守入槽后/取得后窗口的取消检查）。
final class WorkflowSlotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSlots = 0
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
        lock.lock()
        if activeSlots < limit {
            activeSlots += 1
            lock.unlock()
            return
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            // 双检（cancel 与 release 的竞态窗口内可能已放行）。
            if activeSlots < limit && waiters.isEmpty {
                activeSlots += 1
                lock.unlock()
                continuation.resume(returning: ())
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        activeSlots -= 1
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        if next != nil { activeSlots += 1 }
        lock.unlock()
        next?.resume(returning: ())
    }

    /// cancel：排队等待者整体拒绝（runtime.ts:151 splice(0) 1:1）。
    func rejectQueued(_ error: WorkflowError) {
        lock.lock()
        let queued = waiters
        waiters = []
        lock.unlock()
        for waiter in queued {
            waiter.resume(throwing: error)
        }
    }
}

// MARK: - agent() 选项（runtime.ts:349-399 的解析产物）

struct WorkflowAgentOptions: Sendable {
    var label: String?
    var phase: String?
    var provider: String?
    var model: String?
    var schema: JSONValue?
}

// MARK: - schema 子集校验（dsh assertObjectJsonSchema 的描述面等价实现）

/// agent() schema 支持子集校验。dsh 校验器在 @deepseek-ai/dsh-tools 包（本
/// 快照未收录）——按 tool-workflow 工具 description 逐字声明的子集实现：
/// 仅 type/properties/required/additionalProperties/items/enum/const/oneOf，
/// object-rooted，无 pattern/format/numeric bounds（登记）。
enum WorkflowJsonSchema {
    private static let allowedKeywords: Set<String> = [
        "type", "properties", "required", "additionalProperties", "items",
        "enum", "const", "oneOf",
    ]
    private static let allowedTypes: Set<String> = [
        "object", "array", "string", "number", "integer", "boolean", "null",
    ]

    /// - Returns: 违规描述（nil = 通过）。
    static func validate(_ value: JSONValue, path: String, root: Bool = true) -> String? {        guard let obj = value.objectValue else {
            return "\(path) must be an object"
        }
        for key in obj.keys.sorted() where !allowedKeywords.contains(key) {
            return "\(path).\(key) is not a supported keyword"
        }
        if root, obj["type"]?.stringValue != "object" {
            return "\(path) must be object-rooted (\"type\": \"object\")"
        }
        if let type = obj["type"], type.stringValue == nil {
            return "\(path).type must be a string"
        }
        if let typeName = obj["type"]?.stringValue,
           !allowedTypes.contains(typeName) {
            return "\(path).type \"\(typeName)\" is not supported"
        }
        if let required = obj["required"] {
            guard let entries = required.arrayItems,
                  entries.allSatisfy({ $0.stringValue != nil }) else {
                return "\(path).required must be an array of strings"
            }
        }
        if let properties = obj["properties"] {
            guard let fields = properties.objectValue else {
                return "\(path).properties must be an object"
            }
            for key in fields.keys.sorted() {
                if let violation = validate(fields[key]!, path: "\(path).properties.\(key)", root: false) {
                    return violation
                }
            }
        }
        if let items = obj["items"],
           let violation = validate(items, path: "\(path).items", root: false) {
            return violation
        }
        if let additional = obj["additionalProperties"] {
            if additional.objectValue != nil {
                if let violation = validate(additional, path: "\(path).additionalProperties", root: false) {
                    return violation
                }
            } else if additional.boolValue == nil {
                return "\(path).additionalProperties must be a boolean or a schema"
            }
        }
        if let oneOf = obj["oneOf"] {
            guard let branches = oneOf.arrayItems else {
                return "\(path).oneOf must be an array"
            }
            for (index, branch) in branches.enumerated() {
                if let violation = validate(branch, path: "\(path).oneOf[\(index)]", root: false) {
                    return violation
                }
            }
        }
        // enum / const：任意 JSON 可表达值——JSONValue 已保证。
        return nil
    }
}

// MARK: - 宿主 helper（jsHelperSource——realm.ts 1:1 移植 + 桥接设施）

extension WorkflowJsonSchema {
    /// 数据实例 vs 子集 schema 的实例校验（QA-7 缝③配套：validate 校验的是
    /// schema 声明本身；本函数校验数据值——dsh @deepseek-ai/dsh-tools
    /// assertObjectJsonSchema 实例校验语义的 WanWo 承载面，关键词同八件：
    /// type/properties/required/additionalProperties/items/enum/const/oneOf）。
    /// - Returns: 违规描述（nil = 匹配）。
    static func match(_ value: JSONValue, against schema: JSONValue,
                      path: String = "value") -> String? {
        // oneOf：任一支匹配即过（全败才违规）。
        if let oneOf = schema.objectValue?["oneOf"], let branches = oneOf.arrayItems {
            for (index, branch) in branches.enumerated() {
                if match(value, against: branch, path: "\(path).oneOf[\(index)]") == nil {
                    return nil
                }
            }
            return "\(path) does not match any oneOf branch"
        }
        // enum / const：任意 JSON 可表达值。
        if let enumeration = schema.objectValue?["enum"] {
            guard let allowed = enumeration.arrayItems, allowed.contains(value) else {
                return "\(path) is not one of the enum values"
            }
            return nil
        }
        if let constant = schema.objectValue?["const"], constant != value {
            return "\(path) does not match the const value"
        }
        guard let typeName = schema.objectValue?["type"]?.stringValue else {
            return nil
        }
        switch typeName {
        case "object":
            guard let fields = value.objectValue else {
                return "\(path) must be an object"
            }
            let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
            if let required = schema.objectValue?["required"]?.arrayItems {
                for entry in required {
                    guard let key = entry.stringValue else { continue }
                    if fields[key] == nil {
                        return "\(path).\(key) is required"
                    }
                }
            }
            let additional = schema.objectValue?["additionalProperties"]
            for key in fields.keys {
                if let propertySchema = properties[key] {
                    if let violation = match(fields[key]!, against: propertySchema,
                                             path: "\(path).\(key)") {
                        return violation
                    }
                } else if additional?.boolValue == false {
                    return "\(path).\(key) is not an allowed property"
                } else if let additionalSchema = additional?.objectValue {
                    if let violation = match(fields[key]!, against: .object(additionalSchema),
                                             path: "\(path).\(key)") {
                        return violation
                    }
                }
            }
            return nil
        case "array":
            guard let items = value.arrayValue else {
                return "\(path) must be an array"
            }
            if let itemsSchema = schema.objectValue?["items"] {
                for (index, item) in items.enumerated() {
                    if let violation = match(item, against: itemsSchema,
                                             path: "\(path)[\(index)]") {
                        return violation
                    }
                }
            }
            return nil
        case "string":
            return value.stringValue == nil ? "\(path) must be a string" : nil
        case "number":
            return value.doubleValue == nil ? "\(path) must be a number" : nil
        case "integer":
            switch value {
            case .int:
                return nil
            case .double(let d):
                return d == d.rounded() ? nil : "\(path) must be an integer"
            default:
                return "\(path) must be an integer"
            }
        case "boolean":
            return value.boolValue == nil ? "\(path) must be a boolean" : nil
        case "null":
            return value == .null ? nil : "\(path) must be null"
        default:
            // schema 声明已被 validate 拒绝——防御面不可达。
            return "\(path) has an unsupported type \"\(typeName)\""
        }
    }
}

/// 宿主自有 JS 设施（每次 context 一次性求值）。FATAL Symbol 闭包私有——
/// 正常面脚本不可达；同 context 词法面（Function/eval 逃逸）理论可达，
/// 影响有界（脚本自伤自身 realm 判定面）——诚实登记见文件头注（QA-7 P2③）。
/// materialize 为 realm.ts:66-151 的 1:1 移植。
let workflowHelperSource = """
const __wanwoWorkflowApi = (function () {
  'use strict';
  const FATAL = Symbol('wanwo.workflow.fatal');
  const api = {};
  api.nullProto = function () { return Object.create(null); };
  api.deferred = function () {
    let resolve, reject;
    const promise = new Promise(function (res, rej) { resolve = res; reject = rej; });
    return { promise: promise, resolve: resolve, reject: reject };
  };
  api.rejectedPromise = function (error) { return Promise.reject(error); };
  api.newWorkflowError = function (message, code) {
    const error = new Error(message);
    error.workflowCode = code;
    error[FATAL] = true;
    return error;
  };
  api.isFatal = function (value) {
    try {
      return value !== null && typeof value === 'object' && value[FATAL] === true;
    } catch (e) { return false; }
  };
  api.renderThrown = function (error) {
    try {
      const stack = error === null || error === undefined ? undefined : error.stack;
      const message = error === null || error === undefined ? undefined : error.message;
      if (typeof stack === 'string' && stack.length > 0) {
        // JSC 的 error.stack 可能不含 message（node/V8 含）——缺席时前置
        // message（dsh realm.ts renderThrown stack→message 语义的 JSC
        // 保真适配：message 永不失真，栈面保留）。
        if (typeof message === 'string' && message.length > 0 && stack.indexOf(message) === -1) {
          return message + '\\n' + stack;
        }
        return stack;
      }
      if (typeof message === 'string' && message.length > 0) return message;
      return String(error);
    } catch (e) { return '[unrenderable thrown value]'; }
  };
  api.settle = function (promise, onResolve, onReject) {
    Promise.prototype.then.call(promise, onResolve, onReject);
  };
  // 同步钩子包装器（ObjC 块无法跨边界 throw——inner 返回 {thrown} 哨兵）。
  api.makeSyncHook = function (inner) {
    return function () {
      const result = inner.apply(null, Array.prototype.slice.call(arguments));
      if (result !== null && result !== undefined && result.thrown !== null
          && result.thrown !== undefined) {
        throw result.thrown;
      }
    };
  };
  // agent 包装器：缺省 opts 归一（undefined → null 跨界——Swift 侧对
  // undefined/null 双态短路为缺省选项袋，QA-7 P0）。
  api.makeAgentHook = function (inner) {
    return function (prompt, opts) {
      return inner(prompt, opts === undefined ? null : opts);
    };
  };
  // pipeline 包装器：变参 stages 收拢为数组（dsh pipeline(items, ...stages)）。
  api.makePipelineHook = function (inner) {
    return function (items) {
      const stages = Array.prototype.slice.call(arguments, 1);
      return inner(items, stages);
    };
  };
  api.itemCapError = function (hook, length) {
    return api.newWorkflowError(hook + ' received ' + length
      + ' items — over the per-call cap (' + __workflowLimits.maxItemsPerCall
      + '); split the work or raise maxItemsPerCall in the engine config', 'ITEM_CAP');
  };
  api.parallelImpl = function (thunks, isFatal) {
    if (!Array.isArray(thunks)) {
      return Promise.reject(api.newWorkflowError(
        'parallel() requires an array of zero-argument functions', 'INVALID_ARGUMENT'));
    }
    if (thunks.length > __workflowLimits.maxItemsPerCall) {
      return Promise.reject(api.itemCapError('parallel()', thunks.length));
    }
    for (let index = 0; index < thunks.length; index++) {
      if (typeof thunks[index] !== 'function') {
        return Promise.reject(api.newWorkflowError(
          'parallel() item ' + index + ' is not a function', 'INVALID_ARGUMENT'));
      }
    }
    return Promise.all(thunks.map(function (thunk) {
      return Promise.resolve().then(thunk).then(
        function (value) { return value; },
        function (error) { if (isFatal(error)) throw error; return null; });
    }));
  };
  api.pipelineImpl = function (items, stages, isFatal) {
    if (!Array.isArray(items)) {
      return Promise.reject(api.newWorkflowError(
        'pipeline() requires an items array', 'INVALID_ARGUMENT'));
    }
    if (items.length > __workflowLimits.maxItemsPerCall) {
      return Promise.reject(api.itemCapError('pipeline()', items.length));
    }
    if (stages.length === 0) {
      return Promise.reject(api.newWorkflowError(
        'pipeline() requires at least one stage function', 'INVALID_ARGUMENT'));
    }
    for (let index = 0; index < stages.length; index++) {
      if (typeof stages[index] !== 'function') {
        return Promise.reject(api.newWorkflowError(
          'pipeline() stage ' + index + ' is not a function', 'INVALID_ARGUMENT'));
      }
    }
    return Promise.all(items.map(function (item, index) {
      return (async function () {
        let value = item;
        for (const stage of stages) {
          value = await stage(value, item, index);
        }
        return value;
      })().catch(function (error) {
        if (isFatal(error)) throw error;
        return null;
      });
    }));
  };
  // realm.ts:66-151 materializeFromRealm 1:1（宿主自有代码；getter 执行
  // 与 dsh 同一信任前提）。返回 {ok,json} 或 {ok:false,path,reason}。
  api.materialize = function (value, root) {
    function mk(path, reason) {
      return { __materialize: true, path: path, reason: reason, message: path + ': ' + reason };
    }
    function hasPlainPrototype(object) {
      const proto = Object.getPrototypeOf(object);
      if (proto === null) return true;
      return Object.getPrototypeOf(proto) === null;
    }
    function walk(value, path, seen) {
      const kind = typeof value;
      if (kind === 'boolean' || kind === 'string') return value;
      if (kind === 'number') {
        if (!Number.isFinite(value)) throw mk(path, 'non-finite numbers are not JSON data');
        return value;
      }
      if (kind === 'bigint') throw mk(path, 'bigints are not JSON data');
      if (kind === 'function') throw mk(path, 'functions are not plain JSON data');
      if (kind === 'symbol') throw mk(path, 'symbols are not plain JSON data');
      if (kind === 'undefined') throw mk(path, 'undefined is not JSON data');
      if (value === null) return null;
      if (seen.has(value)) throw mk(path, 'circular references are not JSON data');
      seen.add(value);
      try {
        if (Array.isArray(value)) {
          const out = [];
          for (let index = 0; index < value.length; index++) {
            if (!(index in value)) throw mk(path + '[' + index + ']', 'sparse arrays are not JSON data');
            out.push(walk(value[index], path + '[' + index + ']', seen));
          }
          for (const key of Object.keys(value)) {
            const index = Number(key);
            if (!Number.isInteger(index) || index < 0 || index >= value.length) {
              throw mk(path + '.' + key, 'arrays with non-index properties are not JSON data');
            }
          }
          if (Object.getOwnPropertySymbols(value).length > 0) {
            throw mk(path, 'symbol-keyed properties are not plain JSON data');
          }
          return out;
        }
        if (!hasPlainPrototype(value)) {
          throw mk(path, 'only plain objects and arrays are JSON data (exotic prototype)');
        }
        if (Object.getOwnPropertySymbols(value).length > 0) {
          throw mk(path, 'symbol-keyed properties are not plain JSON data');
        }
        const out = {};
        for (const key of Object.keys(value)) {
          // defineProperty：'__proto__' 键必须成为拷贝的 own 数据属性。
          Object.defineProperty(out, key, {
            value: walk(value[key], path + '.' + key, seen),
            enumerable: true, writable: true, configurable: true,
          });
        }
        return out;
      } finally {
        seen.delete(value);
      }
    }
    try {
      if (value === undefined) return { ok: true, json: 'null' };
      const copy = walk(value, root, new Set());
      return { ok: true, json: JSON.stringify(copy) };
    } catch (e) {
      if (e && e.__materialize) return { ok: false, path: e.path, reason: e.reason };
      return { ok: false, path: root, reason: 'reading the value threw: ' + api.renderThrown(e) };
    }
  };
  return api;
})();
"""

// MARK: - 执行观察者（runtime.ts:31-37 ExecutionObserver 的闭包形态）

struct WorkflowExecutionObserver: Sendable {
    let phase: @Sendable (String) -> Void
    let log: @Sendable (String) -> Void
    let agentStart: @Sendable (WorkflowAgentInfo) -> Void
    let agentEnd: @Sendable (WorkflowAgentEndInfo) -> Void
}

// MARK: - WorkflowExecution

/// One live script execution（每 run 一枚；drive() 恰好调用一次且**永不
/// reject**——每个失败都成为非 completed 的 WorkflowResult）。
final class WorkflowExecution: @unchecked Sendable {

    // MARK: 配置与依赖（构造期定死）

    private let limits: WorkflowLimits
    private let childPort: WorkflowChildPort
    /// 执行观察者（引擎在 handle 装配后、任何钩子可能触发前经
    /// replaceObserver 回填——startOnQueue 仅在 awaitTerminal 首启时运行，
    /// 故该写入先于一切 observer 读；调用序保证，无需额外锁）。
    private var observer: WorkflowExecutionObserver
    /// 脚本体（引擎预解析通过后构造——startOnQueue 读取，不可变）。
    private let scriptBody: String
    /// args 只读载荷（queue 上转 JSValue；缺省不注入）。
    private let argsPayload: JSONValue?

    // MARK: 线程与 realm（已定适配④；JS 操作全部在 queue）

    private let queue: DispatchQueue
    private var context: JSContext?
    private var api: JSValue?
    private var contextGroupRef: JSContextGroupRef?
    private var stopBoxRef: Unmanaged<WorkflowStopBox>?
    /// 启动 gate（awaitTerminal 首个登记者触发 startOnQueue——JSCodeRuntime
    /// awaitResult 同款形态）。
    private var startedOnce = false

    // MARK: 计数与状态（cancel/terminal 各持一把锁——run 队列、Swift Task、
    // watchdog 线程三面并发）

    private let countLock = NSLock()
    /// 1-based count of `agent()` calls started（agentsStarted 结果字段）。
    private var started = 0
    private var currentPhase: String?
    private let slots: WorkflowSlotGate

    private let cancelLock = NSLock()
    private var cancelReason: String?
    private var cancelError: WorkflowError?

    private let terminalLock = NSLock()
    private var terminal: WorkflowResult?
    private var terminalWaiters: [CheckedContinuation<WorkflowResult, Never>] = []

    /// 宿主运行柄（引擎回填；弱引用防环——handle 强持 execution）。
    weak var runHandle: WorkflowRunHandle?

    /// 观察者回填（引擎 start() 装配段调用；先于 installHooks/startOnQueue，
    /// 无竞态窗口）。
    func replaceObserver(_ newObserver: WorkflowExecutionObserver) {
        observer = newObserver
    }

    init(limits: WorkflowLimits, childPort: WorkflowChildPort,
         observer: WorkflowExecutionObserver, script: String, args: JSONValue?) {
        self.limits = limits
        self.childPort = childPort
        self.observer = observer
        self.scriptBody = script
        self.queue = DispatchQueue(label: "wanwo.workflow.\(UUID().uuidString)")
        self.slots = WorkflowSlotGate(limit: limits.maxConcurrentAgents)
        self.argsPayload = args
    }

    // MARK: 取消（runtime.ts:123-152 1:1）

    /// Whether the run has been cancelled（方法化——不可内联属性读）。
    private func isCancelled() -> Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelReason != nil
    }

    private func cancelledError() -> WorkflowError {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        // cancel() 先于任何 isCancelled()==true 的观察武装 cancelError；
        // fallback 守类型非可达路径（runtime.ts:201-206 同注）。
        return cancelError ?? WorkflowError(message: "workflow run cancelled", code: .cancelled)
    }

    /// Shared hook entry guard：cancel 后每个钩子（phase/log 含）在下一次
    /// 调用即抛 CANCELLED——取消是下一 HOOK 边界。
    private func throwIfCancelled() throws {
        if isCancelled() { throw cancelledError() }
    }

    /// Cancel the run：排队 agent() 槽位拒绝 + 每个未来钩子调用抛 CANCELLED
    /// ——脚本死在下一个 await。幂等；首个 reason 胜。
    func cancel(reason: String) {
        cancelLock.lock()
        if cancelReason != nil {
            cancelLock.unlock()
            return
        }
        cancelReason = reason
        cancelError = WorkflowError(message: "workflow run cancelled: \(reason)",
                                    code: .cancelled)
        cancelLock.unlock()
        let error = WorkflowError(message: "workflow run cancelled: \(reason)",
                                  code: .cancelled)
        queue.async { [weak self] in
            self?.slots.rejectQueued(error)
        }
    }

    // MARK: drive（runtime.ts:163-188；result-never-rejects 契约）

    /// Run the script to settlement。恰好调用一次；resolves——永不 rejects。
    func awaitTerminal() async -> WorkflowResult {
        return await withCheckedContinuation { (continuation: CheckedContinuation<WorkflowResult, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: WorkflowResult(
                        value: .null, stopReason: .error,
                        error: "workflow execution released", agentsStarted: 0))
                    return
                }
                if let settled = self.terminal {
                    continuation.resume(returning: settled)
                    return
                }
                self.terminalWaiters.append(continuation)
                if !self.startedOnce {
                    self.startedOnce = true
                    self.startOnQueue()
                }
            }
        }
    }

    /// 结算一次（首个胜；terminal-lock 下幂等）。QA-7 P2②：结算即同步
    /// markSettled——消除"result 已到、handle.settled 未登记"窗口内 cancel
    /// 武装宽限定时器的违约面（host.ts:184-190 settled 后 cancel no-op）。
    func settleTerminal(_ result: WorkflowResult) {
        terminalLock.lock()
        if terminal != nil {
            terminalLock.unlock()
            return
        }
        terminal = result
        let waiters = terminalWaiters
        terminalWaiters = []
        terminalLock.unlock()
        runHandle?.markSettled()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    /// Watchdog 中断结算（SCRIPT_TIMEOUT——已定适配①超时映射）。
    fileprivate func timeoutTerminal() {
        settleTerminal(WorkflowResult(
            value: .null,
            stopReason: .error,
            error: "workflow script execution timed out after "
                + "\(Int(limits.syncTimeoutMs))ms (synchronous slice)",
            agentsStarted: startedCount()))
    }

    /// 弃 context（JCore 无 terminate 的强杀兜底——宽限定时器到期/dispose
    /// 收尾调用；JS 操作面立即失效，挂死的队列线程不可回收，登记）。
    func abandonContext() {
        queue.async { [weak self] in
            guard let self else { return }
            self.context = nil
            self.api = nil
            self.contextGroupRef = nil
            self.stopBoxRef = nil
        }
    }

    private func startedCount() -> Int {
        countLock.lock()
        defer { countLock.unlock() }
        return started
    }

    /// 宿主面 agentsStarted 计数（进程内直连——脚本侧计数全路径可见，含
    /// 仍在槽位排队的调用；dsh 终止路径 host-observed 退化场景不存在，登记）。
    func startedCountForHost() -> Int {
        startedCount()
    }

    private func currentPhaseTitle() -> String? {
        countLock.lock()
        defer { countLock.unlock() }
        return currentPhase
    }

    // MARK: 启动（queue 上；全部 JS 操作单线程纪律）

    private func startOnQueue() {
        // 取消先于 body（runtime.ts:167-169——脚本不得执行，更不得报 completed）。
        if isCancelled() {
            settleTerminal(cancelledResult())
            return
        }
        // 每 run 新 JSContext（已定适配①；JSContext() 可空初始化器——实际
        // 失败面仅内存耗尽，JSCodeRuntime 同款强解包）。
        let context = JSContext()!
        self.context = context
        // Watchdog 注册（先于任何脚本执行——生效保证）。
        let contextRef = context.jsGlobalContextRef
        contextGroupRef = JSContextGetGroup(contextRef)
        let stopBox = WorkflowStopBox(queue: queue, execution: self)
        stopBoxRef = Unmanaged.passRetained(stopBox)
        if let setLimit = workflowSetExecutionTimeLimit, let group = contextGroupRef {
            setLimit(group, limits.syncTimeoutMs / 1000.0,
                     WorkflowExecution.interruptCallback, stopBoxRef!.toOpaque())
        }
        // 宿主 helper（FATAL symbol/deferred/物化等——程序运行前定死）。
        guard let api = context.evaluateScript(workflowHelperSource), !api.isUndefined else {
            let detail = context.exception.map { $0.toString() } ?? "unknown"
            context.exception = nil
            settleTerminal(WorkflowResult(
                value: .null, stopReason: .error,
                error: "workflow: helper bootstrap failed: \(detail)", agentsStarted: 0))
            return
        }
        self.api = api
        // 上限全局（helper 的 itemCap 面读取）。
        context.setObject(["maxItemsPerCall": limits.maxItemsPerCall],
                          forKeyedSubscript: "__workflowLimits" as NSString)
        // 五钩子注入（包装器形态——见 jsHelperSource 各 make*Hook 注释）。
        installHooks(into: context, api: api)
        // args（只读全局；缺省不注入——dsh workerData spread 同语义，访问
        // 未注入的 args = ReferenceError → error result）。
        if let argsPayload, let argsValue = JSValue(object: argsPayload.anyValue, in: context) {
            context.setObject(argsValue, forKeyedSubscript: "args" as NSString)
        }
        // 脚本执行（wrapper 与 dsh :91 逐字：(async () => {\n body \n})()）。
        let wrapped = "(async () => {\n" + scriptBody + "\n})()"
        guard let promise = context.evaluateScript(wrapped), !promise.isUndefined else {
            let exception = context.exception
            context.exception = nil
            // Watchdog 已中断本同步片 → 让位：SCRIPT_TIMEOUT 结算由排队中的
            // timeoutTerminal 携带（本路径的 Terminated 面不覆盖权威文案）。
            if stopBox.isFired { return }
            settleTerminal(WorkflowResult(
                value: .null, stopReason: .error,
                error: "workflow script does not parse: "
                    + (exception.map { $0.toString() } ?? "unknown"),
                agentsStarted: startedCount()))
            return
        }
        // settle 桥（promise → 宿主终结两臂）。
        let onResolve: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.handleResolve(value)
        }
        let onReject: @convention(block) (JSValue) -> Void = { [weak self] error in
            self?.handleReject(error)
        }
        api.objectForKeyedSubscript("settle")!.call(withArguments: [
            promise,
            unsafeBitCast(onResolve, to: AnyObject.self),
            unsafeBitCast(onReject, to: AnyObject.self),
        ])
    }

    /// Watchdog 中断回调（VM 线程；返回 true = 终止当前 JS 段）。
    private static let interruptCallback: @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool = { _, data in
        guard let data else { return true }
        let box = Unmanaged<WorkflowStopBox>.fromOpaque(data).takeUnretainedValue()
        box.fire()
        return true
    }

    // MARK: 五钩子注入

    private func installHooks(into context: JSContext, api: JSValue) {
        let isFatalFn = api.objectForKeyedSubscript("isFatal")!

        // agent(prompt, opts?) —— JS 包装器归一缺省 opts（undefined → null）。
        let agentInner: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] prompt, opts in
            guard let self else {
                return api.objectForKeyedSubscript("rejectedPromise")!.call(withArguments: [])!
            }
            return self.agentHook(prompt: prompt, opts: opts)
        }
        let agentHookFn = api.objectForKeyedSubscript("makeAgentHook")!.call(withArguments: [
            unsafeBitCast(agentInner, to: AnyObject.self),
        ])
        context.setObject(agentHookFn!, forKeyedSubscript: "agent" as NSString)

        // parallel(thunks)。
        let parallelInner: @convention(block) (JSValue) -> JSValue = { [weak self] thunks in
            guard let self else { return api.objectForKeyedSubscript("rejectedPromise")!.call(withArguments: [])! }
            return self.parallelHook(thunks: thunks, isFatalFn: isFatalFn)
        }
        context.setObject(unsafeBitCast(parallelInner, to: AnyObject.self),
                          forKeyedSubscript: "parallel" as NSString)

        // pipeline(items, ...stages)——JS 包装器收拢变参 stages。
        let pipelineInner: @convention(block) (JSValue, JSValue) -> JSValue = { [weak self] items, stages in
            guard let self else { return api.objectForKeyedSubscript("rejectedPromise")!.call(withArguments: [])! }
            return self.pipelineHook(items: items, stages: stages, isFatalFn: isFatalFn)
        }
        let pipelineHookFn = api.objectForKeyedSubscript("makePipelineHook")!.call(withArguments: [
            unsafeBitCast(pipelineInner, to: AnyObject.self),
        ])
        context.setObject(pipelineHookFn!, forKeyedSubscript: "pipeline" as NSString)

        // phase(title) / log(message) —— 同步钩子（{thrown} 哨兵包装器）。
        let phaseInner: @convention(block) (JSValue) -> JSValue = { [weak self] title in
            guard let self else { return JSValue(nullIn: context) ?? JSValue() }
            return self.phaseHook(title: title)
        }
        let phaseHookFn = api.objectForKeyedSubscript("makeSyncHook")!.call(withArguments: [
            unsafeBitCast(phaseInner, to: AnyObject.self),
        ])
        context.setObject(phaseHookFn!, forKeyedSubscript: "phase" as NSString)

        let logInner: @convention(block) (JSValue) -> JSValue = { [weak self] message in
            guard let self else { return JSValue(nullIn: context) ?? JSValue() }
            return self.logHook(message: message)
        }
        let logHookFn = api.objectForKeyedSubscript("makeSyncHook")!.call(withArguments: [
            unsafeBitCast(logInner, to: AnyObject.self),
        ])
        context.setObject(logHookFn!, forKeyedSubscript: "log" as NSString)
    }

    // MARK: agent() 钩子（runtime.ts:251-346 1:1）

    private func agentHook(prompt: JSValue, opts: JSValue) -> JSValue {
        guard let context, let api else { return JSValue() }
        let deferred = api.objectForKeyedSubscript("deferred")!.call(withArguments: [])!
        let promise = deferred.objectForKeyedSubscript("promise")!
        let resolve = deferred.objectForKeyedSubscript("resolve")!
        let reject = deferred.objectForKeyedSubscript("reject")!
        Task { [weak self] in
            await self?.runAgent(prompt: prompt, opts: opts,
                                 resolve: resolve, reject: reject)
        }
        return promise
    }

    private func runAgent(prompt: JSValue, opts: JSValue,
                          resolve: JSValue, reject: JSValue) async {
        do {
            try throwIfCancelled()
            // 非空 prompt 字符串（runtime.ts:253-255 文案逐字）。
            let promptText: String
            if prompt.isString, let text = prompt.toString(), !text.isEmpty {
                promptText = text
            } else {
                throw WorkflowError(message: "agent() requires a non-empty prompt string",
                                    code: .invalidArgument)
            }
            let options = try await readAgentOptions(opts)
            // 总数帽（runaway backstop；runtime.ts:257-262 文案逐字）。
            countLock.lock()
            if started >= limits.maxTotalAgents {
                countLock.unlock()
                throw WorkflowError(
                    message: "this run reached its total agent cap (\(limits.maxTotalAgents))"
                        + " — a runaway-loop backstop; raise the applicable maxTotalAgents"
                        + " limit if the scale is intentional",
                    code: .agentCap)
            }
            started += 1
            let seq = started
            countLock.unlock()
            let label = options.label ?? Self.defaultLabel(promptText)
            let phase = options.phase ?? currentPhaseTitle()

            // FIFO 槽（成功后 defer release 覆盖全部后续路径）。
            try await slots.acquire()
            defer { slots.release() }
            // 入槽后二次取消检查（runtime.ts:270-275——await 至少让出一个
            // tick，cancel 落在窗口内不得以 start 失败的面目抵达宿主）。
            try throwIfCancelled()
            let child: WorkflowChildHandle
            do {
                child = try await childPort.startAgent(WorkflowChildStart(
                    prompt: promptText,
                    schema: options.schema,
                    provider: options.provider,
                    model: options.model))
            } catch {
                // 宿主在 run 取消后拒绝 start——竞态必须读作取消本身
                //（runtime.ts:284-289 同语义）。
                if isCancelled() { throw cancelledError() }
                throw WorkflowError(
                    message: "agent() could not start a child: \(Self.renderThrown(error))",
                    code: .agentStart)
            }
            runHandle?.registerChild(seq: seq, child: child)
            // runtime.ts:340-342 finally 恒 dispose（QA-7 P2①）：全部 settle
            // 与 throw 路径统一善后——dispose 幂等（与取消分支/宿主
            // reapChildren 的双 disposal 安全），账本回收根治长循环（Ralph
            // 256 轮）的 children 线性增长。dispose 异步派发（defer 不 await
            // ——promise 兑现不被子善后阻塞）。
            defer {
                Task { [child, weak self] in
                    await child.dispose()
                    self?.runHandle?.removeChild(seq: seq)
                }
            }
            // start 往返让出事件循环——cancel 可能落在宿主已启子与本续体
            // 之间：把新子关停，不留活子陪葬脚本（runtime.ts:291-298）。
            if isCancelled() {
                await child.dispose()
                runHandle?.removeChild(seq: seq)
                throw cancelledError()
            }
            let info = WorkflowAgentInfo(seq: seq, label: label,
                                         phase: phase, childId: child.id)
            observer.agentStart(info)
            do {
                let result: WorkflowChildResult
                do {
                    result = try await child.result.value
                } catch {
                    // result reject = 宿主上报的基础设施故障——先配对生命周期
                    // 再传播且传播 FATAL（普通 throw 会在组合子溶 null，破损
                    // provider 不得读作失败子；runtime.ts:303-317 同语义）。
                    if isCancelled() {
                        observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .cancelled))
                        throw cancelledError()
                    }
                    observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .failed))
                    throw WorkflowError(
                        message: "child agent run failed: \(Self.renderThrown(error))",
                        code: .agentResult)
                }
                if result.stopReason == "completed" {
                    if options.schema != nil {
                        // provider 承诺了 outputSchema——completed 而无结构化
                        // 值 = 子失败（runtime.ts:319-327）。
                        guard let structured = result.structured else {
                            observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .failed))
                            settleOnQueue(resolve, args: [NSNull()])
                            return
                        }
                        observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .completed))
                        settleOnQueue(resolve, args: [structured.anyValue])
                        return
                    }
                    observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .completed))
                    settleOnQueue(resolve, args: [result.output])
                    return
                }
                // cancelled RUN 杀脚本；子自身失败解析 null（脚本按 CC 契约
                // .filter(Boolean)；runtime.ts:332-339）。
                if isCancelled() {
                    observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .cancelled))
                    throw cancelledError()
                }
                observer.agentEnd(WorkflowAgentEndInfo(info: info, outcome: .failed))
                settleOnQueue(resolve, args: [NSNull()])
            }
        } catch {
            // 全部失败路径统一拒绝面（含 slot 排队拒绝的 CANCELLED）。
            rejectOnQueue(error, reject: reject)
        }
    }

    /// 选项袋物化 + 校验（runtime.ts:348-399 1:1）。
    private func readAgentOptions(_ rawOpts: JSValue) async throws -> WorkflowAgentOptions {
        // 缺省 opts 短路（QA-7 P0：makeAgentHook 把 undefined 归一为 null
        // 跨界——bare agent('a') 抵达此处是 null 而非 undefined，短路必须
        // 双态都接住，否则被物化面压成 'must be an object' fatal 杀脚本）。
        // 显式 agent('a', null) 同归缺省——与 dsh（undefined 缺省/null 报
        // INVALID_ARGUMENT）的微偏差，登记：包装器归一使两态不可分，
        // 接 null 为缺省是无害放宽。
        if rawOpts.isUndefined || rawOpts.isNull { return WorkflowAgentOptions() }
        // 必须是 plain JSON 数据（realm.ts 物化；getter 执行同一信任前提）。
        let materialized = try await callHelper("materialize", args: [rawOpts, "agent() options"])
        guard let materialized, materialized.objectForKeyedSubscript("ok")?.toBool() == true else {
            let reason = materialized?.objectForKeyedSubscript("reason")?.toString() ?? "unknown"
            throw WorkflowError(
                message: "agent() options must be plain JSON data — \(reason)",
                code: .invalidArgument)
        }
        let jsonText = materialized.objectForKeyedSubscript("json")?.toString() ?? "null"
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8)),
              let record = decoded.objectValue else {
            throw WorkflowError(message: "agent() options must be an object",
                                code: .invalidArgument)
        }
        let supported: Set<String> = ["label", "phase", "schema", "provider", "model"]
        let deferredOptions: Set<String> = ["effort", "isolation", "agentType"]
        for key in record.keys {
            if supported.contains(key) { continue }
            if deferredOptions.contains(key) {
                throw WorkflowError(
                    message: "agent() option \"\(key)\" is deferred and not supported by this"
                        + " engine (supported: label, phase, schema, provider, model)",
                    code: .unsupportedOption)
            }
            throw WorkflowError(
                message: "agent() option \"\(key)\" is not recognized"
                    + " (supported: label, phase, schema, provider, model)",
                code: .unsupportedOption)
        }
        for key in ["label", "phase", "provider", "model"] {
            if let value = record[key], value.stringValue == nil {
                throw WorkflowError(message: "agent() option \"\(key)\" must be a string",
                                    code: .invalidArgument)
            }
        }
        var schema: JSONValue?
        if let schemaValue = record["schema"] {
            if let violation = WorkflowJsonSchema.validate(schemaValue, path: "schema") {
                throw WorkflowError(
                    message: "agent() schema is outside the supported subset — \(violation)",
                    code: .unsupportedSchema)
            }
            schema = schemaValue
        }
        return WorkflowAgentOptions(
            label: record["label"]?.stringValue,
            phase: record["phase"]?.stringValue,
            provider: record["provider"]?.stringValue,
            model: record["model"]?.stringValue,
            schema: schema)
    }

    // MARK: parallel / pipeline（runtime.ts:402-459——helper 实现宿主校验）

    private func parallelHook(thunks: JSValue, isFatalFn: JSValue) -> JSValue {
        // 取消 = 下一钩子边界（parallel 入口检查；个别 agent() 的取消经其
        // 自身钩子面传播——dsh throwIfCancelled 入口 + 槽位拒绝同语义）。
        if isCancelled() {
            return rejectedOnQueue(cancelledError())
        }
        guard let api else { return JSValue() }
        return api.objectForKeyedSubscript("parallelImpl")!
            .call(withArguments: [thunks, isFatalFn]) ?? JSValue()
    }

    private func pipelineHook(items: JSValue, stages: JSValue, isFatalFn: JSValue) -> JSValue {
        if isCancelled() {
            return rejectedOnQueue(cancelledError())
        }
        guard let api else { return JSValue() }
        return api.objectForKeyedSubscript("pipelineImpl")!
            .call(withArguments: [items, stages, isFatalFn]) ?? JSValue()
    }

    // MARK: phase / log（runtime.ts:470-487；同步钩子——{thrown} 哨兵面）

    private func phaseHook(title: JSValue) -> JSValue {
        guard let context else { return JSValue() }
        do {
            try throwIfCancelled()
            guard title.isString, let text = title.toString(), !text.isEmpty else {
                throw WorkflowError(message: "phase() requires a non-empty title string",
                                    code: .invalidArgument)
            }
            countLock.lock()
            currentPhase = text
            countLock.unlock()
            observer.phase(text)
            return JSValue(nullIn: context) ?? JSValue()
        } catch {
            return thrownBox(error)
        }
    }

    private func logHook(message: JSValue) -> JSValue {
        guard let context else { return JSValue() }
        do {
            try throwIfCancelled()
            guard message.isString else {
                throw WorkflowError(message: "log() requires a message string",
                                    code: .invalidArgument)
            }
            observer.log(message.toString() ?? "")
            return JSValue(nullIn: context) ?? JSValue()
        } catch {
            return thrownBox(error)
        }
    }

    /// 同步钩子的错误哨兵（宿主 helper 构造错误值——fatal 标记随行）。
    private func thrownBox(_ error: Error) -> JSValue {
        guard let context, let api else { return JSValue() }
        let errorValue = workflowErrorValue(error, context: context, api: api)
        return JSValue(object: ["thrown": errorValue], in: context) ?? JSValue()
    }

    // MARK: 终结两臂（drive 的 resolve/reject 面）

    /// Watchdog 是否已中断（queue 上读——startOnQueue/handle 两臂让位面）。
    private var watchdogFired: Bool {
        guard let ref = stopBoxRef else { return false }
        return ref.takeUnretainedValue().isFired
    }

    private func handleResolve(_ raw: JSValue) {
        // Watchdog 已 fire → 让位 timeoutTerminal（结算首胜幂等兜底）。
        if watchdogFired { return }
        if isCancelled() {
            // settle 后取消检查（runtime.ts:171-174——holder 要求取消时
            // `completed` 即谎言）。
            settleTerminal(cancelledResult())
            return
        }
        if raw.isUndefined {
            settleTerminal(WorkflowResult(value: .null, stopReason: .completed,
                                          error: nil, agentsStarted: startedCount()))
            return
        }
        guard let context, let api else {
            settleTerminal(WorkflowResult(
                value: .null, stopReason: .error,
                error: "workflow: context abandoned before settlement",
                agentsStarted: startedCount()))
            return
        }
        let outcome = api.objectForKeyedSubscript("materialize")!
            .call(withArguments: [raw, "workflow result"])
        let ok = outcome?.objectForKeyedSubscript("ok")?.toBool() == true
        if ok, let jsonText = outcome?.objectForKeyedSubscript("json")?.toString(),
           let value = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8)) {
            settleTerminal(WorkflowResult(value: value, stopReason: .completed,
                                          error: nil, agentsStarted: startedCount()))
            return
        }
        let path = outcome?.objectForKeyedSubscript("path")?.toString() ?? "workflow result"
        let reason = outcome?.objectForKeyedSubscript("reason")?.toString() ?? "unknown"
        // runtime.ts:215-219 文案逐字。
        settleTerminal(WorkflowResult(
            value: .null, stopReason: .error,
            error: "the workflow's return value is not plain JSON data — \(path): \(reason)."
                + " Return only JSON-serializable objects/arrays/scalars.",
            agentsStarted: startedCount()))
    }

    private func handleReject(_ error: JSValue) {
        // Watchdog 已 fire → 让位 timeoutTerminal。
        if watchdogFired { return }
        let rendered: String
        if let api, let renderedValue = api.objectForKeyedSubscript("renderThrown")?
            .call(withArguments: [error]), let text = renderedValue.toString(), !text.isEmpty {
            rendered = text
        } else {
            rendered = error.toString()
        }
        if isCancelled() {
            settleTerminal(cancelledResult())
            return
        }
        settleTerminal(WorkflowResult(value: .null, stopReason: .error,
                                      error: rendered, agentsStarted: startedCount()))
    }

    // MARK: JS 桥接小件

    /// 队列上调用宿主 helper（async 上下文 → 队列往返）。
    private func callHelper(_ name: String, args: [Any]) async -> JSValue? {
        guard let api else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<JSValue?, Never>) in
            queue.async { [weak self] in
                guard let self, let context = self.context else {
                    continuation.resume(returning: nil)
                    return
                }
                let function = api.objectForKeyedSubscript(name)
                let result = function?.call(withArguments: args)
                if let exception = context.exception { context.exception = nil; _ = exception }
                continuation.resume(returning: result)
            }
        }
    }

    /// 队列上 resolve/reject 钩子 deferred（JS 单线程纪律）。
    private func settleOnQueue(_ jsFunction: JSValue, args: [Any]) {
        queue.async { [weak self] in
            guard let self, self.context != nil else { return }
            jsFunction.call(withArguments: args)
        }
    }

    /// Swift WorkflowError → 宿主 helper 错误值（fatal 标记随行）→ 队列拒绝。
    private func rejectOnQueue(_ error: Error, reject: JSValue) {
        queue.async { [weak self] in
            guard let self, let context = self.context, let api = self.api else { return }
            let errorValue = self.workflowErrorValue(error, context: context, api: api)
            reject.call(withArguments: [errorValue])
        }
    }

    /// 队列上同步构造 rejected promise（parallel/pipeline 入口取消面）。
    private func rejectedOnQueue(_ error: WorkflowError) -> JSValue {
        guard let context, let api else { return JSValue() }
        let errorValue = workflowErrorValue(error, context: context, api: api)
        return api.objectForKeyedSubscript("rejectedPromise")!
            .call(withArguments: [errorValue]) ?? JSValue()
    }

    /// WorkflowError → 宿主 helper 错误实例（FATAL 标记随行——fatal 不可伪造）。
    private func workflowErrorValue(_ error: Error, context: JSContext, api: JSValue) -> JSValue {
        let message: String
        let code: String
        if let workflowError = error as? WorkflowError {
            message = workflowError.message
            code = workflowError.code.rawValue
        } else {
            message = Self.renderThrown(error)
            code = "INVALID_ARGUMENT"
        }
        return api.objectForKeyedSubscript("newWorkflowError")!
            .call(withArguments: [message, code]) ?? JSValue(nullIn: context) ?? JSValue()
    }

    private func cancelledResult() -> WorkflowResult {
        WorkflowResult(value: .null, stopReason: .cancelled,
                       error: cancelledError().message,
                       agentsStarted: startedCount())
    }

    // MARK: 显示标签（runtime.ts:53-57 1:1）

    /// A short display label derived from the prompt when the script passes none.
    static func defaultLabel(_ prompt: String) -> String {
        let newline = prompt.firstIndex(of: "\n")
        let line = newline == nil ? prompt : String(prompt[..<newline!])
        return line.count <= 48 ? line : "\(line.prefix(47))…"
    }

    /// Swift 侧 renderThrown（WorkflowError message 优先——dsh stack 优先的
    /// 消息面等价，跨语言栈不可得，登记）。
    static func renderThrown(_ error: Error) -> String {
        if let workflowError = error as? WorkflowError {
            return workflowError.message
        }
        return String(describing: error)
    }
}
