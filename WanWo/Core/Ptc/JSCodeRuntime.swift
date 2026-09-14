//
//  JSCodeRuntime.swift
//  WanWo
//
//  【M5-B 批 P2 · JSCore 后端（CodeRuntimeProtocol 的 WanWo TS 实现底座）】
//  语义源（逐锚点对拍，file:line 亲验全文）：
//  dsh-upstream-m5/packages/code-runtime/code-runtime-worker-thread/src/：
//    index.ts（561 行全文）：
//      - :277      每 run 新隔离环境（"a fresh worker runs each"）→ 每 run 新
//        JSContext（登记：隔离单元 worker isolate → context realm）
//      - :25-51    四预算 Config（computeMs/maxWallMs/maxOutputBytes/
//        maxOldGenerationSizeMb）；:240-243 缺省 60_000/600_000/67_108_864/512
//      - :259-269  config 校验文案逐字（positive / maxOutputBytes ≥
//        MIN_OUTPUT_BYTES=4（:66）；:267-269 maxWallMs 上限查——Node setTimeout
//        钳制理由在 JSCore 无对应物，本查丢弃，登记）
//      - :84       STRIP_WRAP（prefix 'async function __dsh_program__() {\n' /
//        suffix '\n}'——async function body 语法上下文，top-level return/await
//        合法；wrap→strip→首尾切片保程序自身行列号）
//      - :109-111  messageOf（Error→message，否则 String）
//      - :169-229  OutputLedger 1:1（logs+value+failure 合并字节账；limit 保留
//        fitting 前缀；"outer output exceeded N bytes" :200）
//      - :278-283  teardown quiescence（dispose→全 in-flight settle abort
//        'runtime disposed' + await 退出）
//      - :293-312  run 前置序（disposed 检查→validateBindings→signal.aborted
//        →strip——strip 失败=程序失败 exception，不执行 :304-309）
//      - :294      'dsh-code-runtime-worker-thread: run() after disposal'
//      - :456/:486/:499  'program/binding arguments/binding resolution must be
//        lossless JSON'；:481 'unknown binding X'；:504 binding 抛错→messageOf
//      - :540/:544 timeout 文案：'compute budget exhausted (Nms busy)'（ELU
//        计量——JSCore 无对应，词汇保留登记）/'wall-clock ceiling reached (Nms)'
//    bootstrap.ts（424 行全文）：
//      - :405-412  程序 = AsyncFunction(...globals, ...errorClassNames,
//        'console', "'use strict';\n"+code)——bindings/errorClass/console 以
//        函数参数注入（非 global 对象），程序体 strict mode
//      - :100-120  console shim 五级（log/info/warn/error/debug，:101），渲染
//        args.map(字符串原样:inspect).join(' ')——JSCore 形态 inspect→JSON
//        形态近似（登记）；console 名仍在 RESERVED_BINDING_GLOBALS（用户不得
//        binding 成 console——注入捕获版与槽保留两事不冲突，裁定呈报）
//      - :245-255  errorClass 物化（class extends Error；name=类名 own 字段，
//        memberNameProperty 字段=成员名；binding 拒绝成为其实例 :258-260）
//      - :315-359  namespace = Object.create(null)（null-prototype——
//        __proto__/constructor 普通键）+ 每 declared 名 own 函数 = 返回
//        Promise 的桥；args 无损 JSON 预检拒绝（:336）后过桥
//      - :216-229  prepareException（Error→stack??message→String；不可渲染→
//        'program threw an unrenderable value'）
//      - :166-190  prepareCompletion（undefined→无值；snapshot 失败→
//        invalid-output；字节超限→output-limit）
//    output-json.ts（179 行全文）：jsonStringBytesUpTo(:81-91)/
//      jsonValueBytesUpTo(:99-156)/truncateJsonStringBytes(:166-179) 逐函数移植
//    worker-json.ts（421 行全文）：snapshotCodeJsonValue(:150-233) 迭代无损
//      JSON 校验（leave 前活性集防环 :202）→ JS 侧 helper snapshot（单 realm
//      简化：外来 realm 原型检查丢弃，登记）
//
//  拍板项①（已定稿）：TS 经 Sucrase 内嵌 JSCore 转译——@mizchi/sucrase@4.1.0
//  （MIT）dist/index.cjs 单文件（grep 亲验零 Node 依赖），npm registry tarball
//  下载解包加 CJS prelude/suffix 包装 → WanWo/Resources/Ptc/sucrase.js；加载
//  形态 = 源码串引擎级单例缓存 + 每 context evaluateScript 一次（隔离语义要求
//  逐 context 求值）；transform = Sucrase.transform(wrapped,
//  {transforms:['typescript']}).code。wrap→transform 序（dsh :302 同构——先包
//  后转译，top-level return 才合法）；sucrase 非严格位置保持——壳内无 TS 语法
//  前后逐字不变 + 尾随换行差异防御（登记）。
//
//  JSCore API 取证锚点（呈报项）：
//    · 硬中断：JSContextGroupSetExecutionTimeLimit（JSContextRefPrivate.h，
//      JSC_API_AVAILABLE(macos(10.6), ios(7.0))——WebKit Watchdog：脚本执行段
//      超限回调，返回 true 即终止热循环；cpp 实现内 JSLockHolder=线程安全，
//      运行中重设 limit=0 即立即到期强制）——头不在公开 Swift 模块伞内，经
//      dlsym(RTLD_DEFAULT) 取符（本二进制已链接 JavaScriptCore）+ C 函数指针
//      调用；JSContextGroupRef 经公开 C API JSContextGetGroup(
//      context.JSGlobalContextRef)（JSContext.h 只读属性 JSGlobalContextRef，
//      iOS 7+ 公开——【CI 编译风险登记】Swift 导入名若与 ObjC 属性名不一致，
//      此行单点修复）
//    · 预算裁定（拍板项②）：maxWallMs = 宿主 DispatchSourceTimer（权威
//      timeout 失败）+ Watchdog（热循环硬停）双保险；computeMs busy-time 无
//      对应——词汇保留不执行（登记）；maxOldGenerationSizeMb 无 per-context
//      heap——worker-exit 词汇保留不产出（登记）
//    · Promise：纯 JS deferred 工厂（捕获内置 new Promise——iOS 13+ JSC 原生
//      Promise/async-await），resolve/reject 以 JSValue 持有跨 Swift 异步结算
//    · null-prototype：捕获内置 Object.create(null)（程序可毒化原型链——全部
//      内置经 helper 求值时捕获进闭包 I，程序不可达，敌对同侪义务）
//
//  WanWo 形态适配（登记）：
//    ① 契约误用（disposed/绑定量非法）= dsh run() 的 reject 面（worker
//      :285-289 doc 两态区分）——P1 裁定 run 不 throws，本实现返回结构化失败
//      结果（kind='exception'，message=dsh 契约文案逐字）；显式校验面 =
//      validate(_) throwing（P1 纯函数包装）。
//    ② abort（Task cancellation）：signal→Task.isCancelled（P1 登记④）——
//      withTaskCancellationHandler onCancel → 停止请求 + 检查点 finish 分派
//      （挂起情形）+ Watchdog 强制（热循环硬停）；in-flight binding 调用是
//      CALLER 结算责任——运行时只停止询问（types.ts:86，resolution 到达时
//      stopRequested 检查丢弃）；abort message = 'canceled'（Task cancellation
//      无 reason 载荷——dsh String(signal.reason) 对应物，登记）。
//    ③ 隔离 runs 无状态（:96-99 义务）：每 run 新 JSContext + 新串行队列
//      （JSCore ObjC API 单线程纪律——全部 JS 操作在 run 队列）；helper 本体
//      不出 closure 作用域、Swift 持 helper JSValue 引用（程序重绑全局名不可达）。
//    ④ 单 realm 简化：worker-json 外来 realm 原型检查丢弃（登记）；sucrase.js
//      的 Sucrase/module/exports 全局对程序可见（同 realm 限制，自伤面，登记）。
//    ⑤ 日志面：console 捕获版注入（五级，logs 保真）+ 无 process.stdout
//      （stray 管道捕获面 N/A——登记）；OutputLedger 单账本（worker 侧
//      LogBuffer 流式账 + 宿主侧 OutputLedger 终账合并——单进程无 port，
//      admit/limit 语义逐字保留，登记）。
//    ⑥ jsonValueBytesUpTo 的 double 计量 = Swift Double.description（dsh 为
//      JS Number.toString）——指数补零差异（1e-7→"1e-07"）登记，仅影响极端
//      指数值的字节账一位差。
//    ⑦ teardown 的硬杀面：worker.terminate() 无对应——dispose 经停止请求 +
//      Watchdog 强制 + 队列 finish 收敛到同一幂等 finish；Watchdog 缺失
//      （dlsym 失败）且热循环 → run 挂起（退化面登记；CI macOS 正常路径）。
//    ⑧ binding 参数序：bootstrap 的参数表为 globals…/errorClasses…/console
//      分组序——本实现按 namespace 序（global+errorClass 相邻），参数/值两表
//      自身对齐等价（分组无语义，登记）。
//

import Foundation
import Darwin
import JavaScriptCore

// MARK: - 配置（worker index.ts:25-51 + :240-243 缺省 1:1）

/// 四预算配置（computeMs/maxWallMs/maxOutputBytes/maxOldGenerationSizeMb）。
/// 显式优于隐式：缺省在此定死（dsh schemastery default 同位），请求不带旋钮。
struct JSCodeRuntimeConfig: Equatable, Sendable {
    /// busy-time 预算毫秒（worker :26-34 注释语义）——JSCore 无 ELU 计量，
    /// 词汇保留不执行（拍板项②登记）。
    var computeMs: Double
    /// 墙钟上限毫秒（worker :36-43——永不暂停的 backstop；权威 timeout 面）。
    var maxWallMs: Double
    /// 序列化 logs/value/failure message 合并硬上限字节（固定结果封套语法不入账）。
    var maxOutputBytes: Int
    /// worker 堆上限 MiB（:49——溢出→worker-exit）——JSCore 无 per-context
    /// heap cap，词汇保留（登记）。
    var maxOldGenerationSizeMb: Int

    static let minOutputBytes = 4   // worker index.ts:66

    init(computeMs: Double = 60_000,
         maxWallMs: Double = 600_000,
         maxOutputBytes: Int = 67_108_864,
         maxOldGenerationSizeMb: Int = 512) {
        self.computeMs = computeMs
        self.maxWallMs = maxWallMs
        self.maxOutputBytes = maxOutputBytes
        self.maxOldGenerationSizeMb = maxOldGenerationSizeMb
    }

    /// 配置校验（worker :258-263 文案逐字；:267-269 maxWallMs 上限查丢弃——
    /// Node setTimeout 钳制理由无对应物，登记）。
    /// - Throws: `JSCodeRuntimeConfigError`（message = dsh 文案逐字）。
    func validate() throws {
        // :258-260——逐键 positive（Number.isFinite 对应 Double.isFinite）。
        for (key, value) in [("computeMs", computeMs), ("maxWallMs", maxWallMs)] {
            if !(value.isFinite && value > 0) {
                throw JSCodeRuntimeConfigError(message:
                    "dsh-code-runtime-worker-thread: config.\(key) must be a positive number, got \(jsNumberString(value))")
            }
        }
        if maxOldGenerationSizeMb <= 0 {
            throw JSCodeRuntimeConfigError(message:
                "dsh-code-runtime-worker-thread: config.maxOldGenerationSizeMb must be a positive number, got \(String(maxOldGenerationSizeMb))")
        }
        // :261-263——safe integer（Swift Int 恒 safe，finite 查 vacuously
        // 成立——量纲适配）+ 下限 MIN_OUTPUT_BYTES。
        if maxOutputBytes < Self.minOutputBytes {
            throw JSCodeRuntimeConfigError(message:
                "dsh-code-runtime-worker-thread: config.maxOutputBytes must be a safe integer of at least \(Self.minOutputBytes), got \(String(maxOutputBytes))")
        }
    }

    /// JS String(number) 的 Swift 近似（整数不落 .0；指数补零差异登记⑥）。
    private func jsNumberString(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e21 {
            return String(Int64(value))
        }
        return String(value)
    }
}

/// 配置校验错误（worker :259/:262 plain Error + message 形态）。
struct JSCodeRuntimeConfigError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - JSON 字节计量（output-json.ts 逐函数移植）

/// output-json.ts 三函数的 Swift 形态（UTF-8 字节 + JSON 转义感知；JS UTF-16
/// 码点迭代 → Swift Unicode.Scalar 迭代量纲等价——星形平面标量 4 字节与 JS
/// 代理对一致；JS 孤立代理 6 字节面在 Swift String 不可表达，登记）。
enum OutputJSON {

    /// output-json.ts:81-91 jsonStringBytesUpTo 1:1：带引号 JSON 字符串序列化
    /// 字节数；超帽即 nil（不物化完整转义形）。
    static func jsonStringBytesUpTo(_ text: String, _ maxBytes: Int) -> Int? {
        if maxBytes < 2 { return nil }
        var bytes = 2
        for scalar in text.unicodeScalars {
            bytes += serializedScalarBytes(scalar)
            if bytes > maxBytes { return nil }
        }
        return bytes
    }

    /// output-json.ts:66-73 serializedCharacterBytes（scalar 形态）。
    static func serializedScalarBytes(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value > 0xFFFF { return 4 }                     // 星形平面 = JS 代理对 2×2
        if scalar == "\"" || scalar == "\\" { return 2 }
        if value < 0x20 {
            switch scalar {
            case "\u{08}", "\t", "\n", "\u{0C}", "\r": return 2   // \b\t\n\f\r
            default: return 6                                      // \uXXXX
            }
        }
        return utf8ByteCount(value)
    }

    private static func utf8ByteCount(_ value: UInt32) -> Int {
        if value < 0x80 { return 1 }
        if value < 0x800 { return 2 }
        if value < 0x10000 { return 3 }
        return 4
    }

    /// output-json.ts:99-156 jsonValueBytesUpTo 1:1（无损 JSON 值的序列化
    /// 字节；递归形态——dsh 迭代为免 JS 栈深限制，Swift 侧值经 JSONDecoder
    /// 深度受界，登记⑥）；double 计量 = Swift Double.description（差异登记⑥）。
    static func jsonValueBytesUpTo(_ value: JSONValue, _ maxBytes: Int) -> Int? {
        var bytes = 0
        func add(_ cost: Int) -> Bool {
            bytes += cost
            return bytes <= maxBytes
        }
        func visit(_ current: JSONValue) -> Bool {
            switch current {
            case .null:
                return add(4)
            case .string(let text):
                guard let stringBytes = jsonStringBytesUpTo(text, maxBytes - bytes) else { return false }
                bytes += stringBytes
                return true
            case .int(let number):
                return add(String(number).utf8.count)
            case .double(let number):
                return add(String(number).utf8.count)
            case .bool(let flag):
                return add(flag ? 4 : 5)
            case .array(let items):
                guard add(2) else { return false }
                for (index, item) in items.enumerated() {
                    if index > 0 { guard add(1) else { return false } }   // 逗号（dsh :135）
                    guard visit(item) else { return false }
                }
                return true
            case .object(let fields):
                guard add(2) else { return false }
                var first = true
                for (key, item) in fields {
                    if !first { guard add(1) else { return false } }      // 逗号
                    first = false
                    guard let keyBytes = jsonStringBytesUpTo(key, maxBytes - bytes) else { return false }
                    guard add(keyBytes + 1) else { return false }         // "key":
                    guard visit(item) else { return false }
                }
                return true
            }
        }
        return visit(value) ? bytes : nil
    }

    /// output-json.ts:166-179 truncateJsonStringBytes 1:1：最长码点对齐前缀，
    /// 其含引号 JSON 编码恰适配 maxBytes。
    static func truncateJsonStringBytes(_ text: String, _ maxBytes: Int) -> String {
        if maxBytes < 2 { return "" }
        var bytes = 2
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let cost = serializedScalarBytes(scalar)
            if bytes + cost > maxBytes { break }
            bytes += cost
            scalars.append(scalar)
        }
        return String(scalars)
    }
}

// MARK: - 输出账本（worker index.ts:169-229 1:1）

/// 一次 run 的合并外层输出账本；binding 值永不入账（:168 注释语义）。
struct OutputLedger {
    let maxBytes: Int
    private(set) var bytes = 2   // 空 logs 数组的 JSON 序列化：[]（:170）
    private(set) var entries = 0

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    /// :176-184 admit——恰纳一条日志或报告硬帽 crossed。
    mutating func admit(_ text: String, into sink: inout [String]) -> Bool {
        let separatorBytes = entries > 0 ? 1 : 0
        guard let stringBytes = OutputJSON.jsonStringBytesUpTo(
            text, maxBytes - bytes - separatorBytes) else { return false }
        bytes += stringBytes + separatorBytes
        entries += 1
        sink.append(text)
        return true
    }

    /// 剩余精确 JSON 字节预算（completion value / failure message 用）。
    func remainingOutputBytes() -> Int {
        return maxBytes - bytes
    }

    /// :187-190 success——absent-or-JSON completion 对合并帽终算。
    func success(_ logs: [String], _ value: JSONValue?) -> CodeRunResult {
        if let value, OutputJSON.jsonValueBytesUpTo(
            value, remainingOutputBytes()) == nil {
            return limit(logs)
        }
        return CodeRunResult(value: value, logs: logs, error: nil)
    }

    /// :193-196 failure——合并字节超帽时 output-limit 优先。
    func failure(_ logs: [String], _ error: CodeRunFailure) -> CodeRunResult {
        if OutputJSON.jsonStringBytesUpTo(error.message, remainingOutputBytes()) == nil {
            return limit(logs)
        }
        return CodeRunResult(value: nil, logs: logs, error: error)
    }

    /// :199-228 limit——显式 output-limit 失败，保留末条 log 的 fitting 前缀。
    func limit(_ logs: [String]) -> CodeRunResult {
        let fullMessage = "outer output exceeded \(maxBytes) bytes"
        // 固定诊断为 ASCII：每字符 1 字节 + 引号（:202 注释语义）。
        let messageBytes = fullMessage.utf8.count + 2
        var retained: [String] = []
        var retainedBytes = 2
        let logBudget = maxBytes - messageBytes
        for text in logs {
            let separatorBytes = retained.isEmpty ? 0 : 1
            let availableBytes = logBudget - retainedBytes - separatorBytes
            if let stringBytes = OutputJSON.jsonStringBytesUpTo(text, availableBytes) {
                retained.append(text)
                retainedBytes += stringBytes + separatorBytes
                continue
            }
            let prefix = OutputJSON.truncateJsonStringBytes(text, availableBytes)
            if !prefix.isEmpty {
                // truncateJsonStringBytes 保证前缀适配同预算（:218-219 v8
                // ignore 注释语义）——不可达面防御。
                guard let prefixBytes = OutputJSON.jsonStringBytesUpTo(prefix, availableBytes) else {
                    continue
                }
                retained.append(prefix)
                retainedBytes += prefixBytes + separatorBytes
            }
            break
        }
        let availableMessageBytes = maxBytes - retainedBytes
        let message = OutputJSON.truncateJsonStringBytes(fullMessage, availableMessageBytes)
        return CodeRunResult(value: nil, logs: retained,
                             error: CodeRunFailure(kind: .outputLimit, message: message))
    }
}

// MARK: - JS helper 源（worker bootstrap 语义的 JSCore 形态）

/// 每 context 求值一次的 helper 脚本：IIFE 返回 api 对象（Swift 持 JSValue），
/// 全部 JS 内置在求值时捕获进闭包 I——程序（后运行）毒化全局/原型不可达
/// （敌对同侪义务，登记③）。程序可见面 = 注入的 namespace/console 参数，
/// helper 本体不出 closure 作用域。sucrase 尾随的 module/exports/Sucrase
/// 全局对程序可见（同 realm 限制，登记④）。
private let jsHelperSource = """
(() => {
  'use strict';
  const I = {
    Error,
    objectProto: Object.prototype,
    arrayProto: Array.prototype,
    isArray: Array.isArray,
    isFinite: Number.isFinite,
    objectIs: Object.is,
    create: Object.create,
    defineProperty: Object.defineProperty,
    ownKeys: Reflect.ownKeys,
    getPrototypeOf: Object.getPrototypeOf,
    propertyIsEnumerable: Object.prototype.propertyIsEnumerable,
    string: String,
    stringify: JSON.stringify,
    parse: JSON.parse,
    promiseThen: Promise.prototype.then,
    promiseReject: Promise.reject,
    Promise,
    setAdd: Set.prototype.add,
    setHas: Set.prototype.has,
    setDelete: Set.prototype.delete,
    Set,
    join: Array.prototype.join,
    asyncFunction: (async () => {}).constructor,
  };

  // worker-json.ts:102-110（单 realm 简化——外来 realm 原型检查丢弃，登记④）。
  function hasPlainArrayPrototype(value) {
    return I.getPrototypeOf(value) === I.arrayProto;
  }
  function hasPlainObjectPrototype(value) {
    const proto = I.getPrototypeOf(value);
    return proto === null || proto === I.objectProto;
  }
  // worker-json.ts:121-128 enumerableStringKeys——非字符串键/不可枚举 own 键
  // 拒绝（JSON 会丢弃的 own 数据 = 无损破坏）。
  function enumerableStringKeys(value) {
    const keys = I.ownKeys(value);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      if (typeof key !== 'string' || !I.propertyIsEnumerable.call(value, key)) {
        return undefined;
      }
    }
    return keys;
  }

  // worker-json.ts:150-233 snapshotCodeJsonValue 迭代移植（leave 任务后弹 =
  // 活性集防环 :202；稀疏数组 ownKeys 长度查 :207；-0/非有限拒绝 :197）。
  function snapshot(rootValue) {
    const active = new I.Set();
    let root;
    const tasks = [{ leave: false, parent: null, key: null, index: -1, value: rootValue }];
    while (tasks.length > 0) {
      const task = tasks.pop();
      if (task.leave) {
        I.setDelete.call(active, task.value);
        continue;
      }
      const candidate = task.value;
      let detached;
      let isContainer = false;
      if (candidate === null) {
        detached = null;
      } else if (typeof candidate === 'boolean' || typeof candidate === 'string') {
        detached = candidate;
      } else if (typeof candidate === 'number') {
        if (!I.isFinite(candidate) || I.objectIs(candidate, -0)) return undefined;
        detached = candidate;
      } else if (typeof candidate !== 'object') {
        return undefined;
      } else {
        if (I.setHas.call(active, candidate)) return undefined;
        if (I.isArray(candidate)) {
          if (!hasPlainArrayPrototype(candidate)) return undefined;
          const length = candidate.length;
          if (I.ownKeys(candidate).length !== length + 1) return undefined;
          detached = [];
          tasks.push({ leave: true, parent: null, key: null, index: -1, value: candidate });
          for (let index = length - 1; index >= 0; index--) {
            tasks.push({ leave: false, parent: detached, key: null, index, value: candidate[index] });
          }
        } else {
          if (!hasPlainObjectPrototype(candidate)) return undefined;
          const keys = enumerableStringKeys(candidate);
          if (keys === undefined) return undefined;
          detached = I.create(null);
          tasks.push({ leave: true, parent: null, key: null, index: -1, value: candidate });
          for (let index = keys.length - 1; index >= 0; index--) {
            tasks.push({ leave: false, parent: detached, key: keys[index], index: -1, value: candidate[keys[index]] });
          }
        }
        I.setAdd.call(active, candidate);
        isContainer = true;
      }
      if (task.parent === null) {
        root = detached;
      } else if (task.index >= 0) {
        I.defineProperty(task.parent, task.index, { value: detached, enumerable: true, writable: true, configurable: true });
      } else {
        I.defineProperty(task.parent, task.key, { value: detached, enumerable: true, writable: true, configurable: true });
      }
      if (isContainer) {
        // 占位（活性集删除已由 leave 任务承载）。
      }
    }
    return root;
  }

  // args/resolution/completion 的统一编码口：无损 → JSON 文本；否则 undefined。
  function encode(value) {
    const snap = snapshot(value);
    if (snap === undefined) return undefined;
    try {
      return I.stringify(snap);
    } catch {
      return undefined;
    }
  }

  // 纯 JS deferred 工厂（JSCore 原生 Promise——iOS 13+）。
  function deferred() {
    let resolve;
    let reject;
    const promise = new I.Promise((res, rej) => { resolve = res; reject = rej; });
    const out = I.create(null);
    I.defineProperty(out, 'promise', { value: promise });
    I.defineProperty(out, 'resolve', { value: resolve });
    I.defineProperty(out, 'reject', { value: reject });
    return out;
  }

  // bootstrap.ts:245-255 errorClass 物化（name/memberNameProperty own 字段）。
  function makeErrorClass(descriptor) {
    const name = descriptor.name;
    const memberProp = descriptor.memberNameProperty;
    return class extends I.Error {
      constructor(memberName, message) {
        super(message);
        I.defineProperty(this, 'name', { enumerable: true, value: name });
        I.defineProperty(this, memberProp, { enumerable: true, value: memberName });
      }
    };
  }
  // bootstrap.ts:258-260 bindingFailure（无 errorClass = 普通 Error(message)）。
  function newError(cls, memberName, message) {
    const C = cls || I.Error;
    return new C(memberName, message);
  }
  function rejectedPromise(error) {
    return I.promiseReject(error);
  }

  // bootstrap.ts:100-120 console shim（五级；渲染 = 字符串原样 : 非字符串
  // JSON 形态近似 inspect——差异登记⑤；join 经捕获内置）。
  const CONSOLE_LEVELS = ['log', 'info', 'warn', 'error', 'debug'];
  function renderValue(value) {
    try {
      const text = I.stringify(value);
      if (text !== undefined) return text;
    } catch { /* 循环等 stringify 失败 → String 兜底 */ }
    try { return I.string(value); } catch { return 'unrenderable'; }
  }
  function consoleShim(push) {
    const shim = I.create(null);
    for (const level of CONSOLE_LEVELS) {
      I.defineProperty(shim, level, { enumerable: true, value: (...args) => {
        const parts = [];
        for (const arg of args) {
          parts.push(typeof arg === 'string' ? arg : renderValue(arg));
        }
        push(I.join.call(parts, ' '));
      }});
    }
    return shim;
  }

  // bootstrap.ts:405-412 程序构建（AsyncFunction；strict 前缀在 body 内同位）。
  function makeProgram(paramNames, body) {
    const args = [];
    for (const name of paramNames) args.push(name);
    args.push(body);
    return new I.asyncFunction(...args);
  }

  // settlement 桥（then 经捕获内置；handler 为 Swift block）。
  function settle(promise, onResolve, onReject) {
    I.promiseThen.call(promise, onResolve, onReject);
  }

  // bootstrap.ts:216-229 prepareException 的 message 提取（不可渲染 → null）。
  function messageOf(error) {
    try {
      if (error instanceof I.Error) {
        const stack = error.stack;
        if (stack !== undefined && stack !== null) return I.string(stack);
        return I.string(error.message);
      }
      return I.string(error);
    } catch {
      return null;
    }
  }

  function parse(text) {
    return I.parse(text);
  }

  const api = I.create(null);
  I.defineProperty(api, 'nullProto', { value: () => I.create(null) });
  I.defineProperty(api, 'encode', { value: encode });
  I.defineProperty(api, 'deferred', { value: deferred });
  I.defineProperty(api, 'makeErrorClass', { value: makeErrorClass });
  I.defineProperty(api, 'newError', { value: newError });
  I.defineProperty(api, 'rejectedPromise', { value: rejectedPromise });
  I.defineProperty(api, 'consoleShim', { value: consoleShim });
  I.defineProperty(api, 'makeProgram', { value: makeProgram });
  I.defineProperty(api, 'settle', { value: settle });
  I.defineProperty(api, 'messageOf', { value: messageOf });
  I.defineProperty(api, 'parse', { value: parse });
  return api;
})()
"""

// MARK: - Watchdog 硬停（JSCore API 取证兑现）

/// dlsym 取得的 JSContextGroupSetExecutionTimeLimit（JSContextRefPrivate.h，
/// ios(7.0)+——头不在公开 Swift 伞内，符号经 RTLD_DEFAULT 搜索：本二进制已
/// 链接 JavaScriptCore）。nil = Watchdog 不可用（退化面登记⑦）。
private typealias SetExecutionTimeLimitFn = @convention(c) (
    JSContextGroupRef?, Double,
    (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?,
    UnsafeMutableRawPointer?
) -> Void

private let setExecutionTimeLimit: SetExecutionTimeLimitFn? = {
    // RTLD_DEFAULT = (void*)-2——全已加载镜像搜索（含本进程链接的 JavaScriptCore）。
    let defaultHandle = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: -2))
    guard let symbol = dlsym(defaultHandle, "JSContextGroupSetExecutionTimeLimit") else {
        return nil
    }
    return unsafeBitCast(symbol, to: SetExecutionTimeLimitFn.self)
}()

/// 一次 run 的停止请求状态（C 回调 data 指针载体；线程安全——Watchdog 回调在
/// VM 线程、取消在任意线程、finish 在 run 队列）。
final class RunStopState: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingStop: CodeRunFailure?
    /// Watchdog 自然到期（limit=maxWallMs 到点、无显式停止请求）的默认失败
    /// （worker :544 文案逐字）。
    let wallDefaultStop: CodeRunFailure
    let queue: DispatchQueue
    /// finish 入口（RunState 装入；queue 上执行）。
    var finishOnQueue: ((CodeRunFailure) -> Void)?

    init(queue: DispatchQueue, wallDefaultStop: CodeRunFailure) {
        self.queue = queue
        self.wallDefaultStop = wallDefaultStop
    }

    var hasPendingStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingStop != nil
    }

    /// 显式停止请求（首个生效——dsh exactly-one-outcome-wins 语义）。
    func requestStop(_ failure: CodeRunFailure) {
        lock.lock()
        if pendingStop == nil { pendingStop = failure }
        lock.unlock()
    }

    /// Watchdog 回调取停止请求；无显式请求 = 自然到期（墙钟默认）。
    func takeStop() -> CodeRunFailure {
        lock.lock()
        let stop = pendingStop ?? wallDefaultStop
        pendingStop = nil
        lock.unlock()
        return stop
    }

    /// Watchdog 线程入口：停止请求派发到 run 队列收敛（finish 幂等）。
    func dispatchStop() {
        let stop = takeStop()
        queue.async { [weak self] in
            guard let self, let finish = self.finishOnQueue else { return }
            finish(stop)
        }
    }
}

// MARK: - JSCodeRuntime（CodeRuntimeProtocol 的 JSCore 实现）

/// JSCore 后端（language = 'typescript'——Sucrase 转译 TS；isolation =
/// 'jscore'——well-known 三值外的 WanWo 底座，信息性非门控，登记）。
/// 每 run 新 JSContext（隔离 runs）；程序 = AsyncFunction 参数注入形态
/// （bootstrap :405-412 同构）；四预算按拍板项②执行（maxWallMs+maxOutputBytes
/// 权威，computeMs/maxOldGenerationSizeMb 词汇保留）。
final class JSCodeRuntime: CodeRuntimeProtocol, @unchecked Sendable {

    let language = "typescript"
    /// 执行底座标识（信息性非门控——well-known 'worker-thread'/'process'/
    /// 'container' 之外的 JSCore 底座，登记）。
    let isolation = "jscore"

    private let config: JSCodeRuntimeConfig
    private let lock = NSLock()
    private var disposed = false
    private var live: [RunState] = []

    /// sucrase.js 源码串引擎级单例缓存（隔离语义要求逐 context 求值——
    /// 缓存的是源码，不是求值结果）。
    private static let sucraseCacheLock = NSLock()
    private static var sucraseCache: String?

    /// STRIP_WRAP（worker index.ts:84 逐字）。
    static let stripWrapPrefix = "async function __dsh_program__() {\n"
    static let stripWrapSuffix = "\n}"

    /// - Parameters:
    ///   - config: 四预算配置（init 内 validate——dsh 构造期校验同位）。
    ///   - bundle: 资源取样缝（sucrase.js 定位；缺省 = 本类所在 bundle）。
    /// - Throws: 配置校验失败（dsh 文案逐字）。
    init(config: JSCodeRuntimeConfig = JSCodeRuntimeConfig(),
         bundle: Bundle = Bundle(for: JSCodeRuntime.self)) throws {
        try config.validate()
        self.config = config
        _ = Self.loadSucraseSource(bundle: bundle)
    }

    /// sucrase.js 资源加载（单例缓存；资源缺失 = nil——run 期结构化失败）。
    static func loadSucraseSource(bundle: Bundle) -> String? {
        sucraseCacheLock.lock()
        defer { sucraseCacheLock.unlock() }
        if let cached = sucraseCache { return cached }
        guard let url = bundle.url(forResource: "sucrase", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        sucraseCache = source
        return source
    }

    // MARK: 契约校验面（dsh run() reject 面的显式 throwing 形态）

    /// 绑定量契约校验（P1 CodeRuntimeSeam.validateBindings 包装——消费面
    /// pre-flight 用；契约误用文案逐字）。
    func validate(_ request: CodeRunRequest) throws {
        try CodeRuntimeSeam.validateBindings(request.bindings)
    }

    // MARK: CodeRuntimeProtocol

    func run(_ request: CodeRunRequest) async -> CodeRunResult {
        // 契约误用 → 结构化失败结果（dsh reject 文案逐字；登记①——protocol
        // run 不 throws，两态区分保留在 message 词汇）。
        if isDisposed() {
            return failureBeforeWorker(CodeRunFailure(
                kind: .exception,
                message: "dsh-code-runtime-worker-thread: run() after disposal"))
        }
        do {
            try CodeRuntimeSeam.validateBindings(request.bindings)
        } catch {
            return failureBeforeWorker(CodeRunFailure(
                kind: .exception,
                message: (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)))
        }

        let state = RunState(config: config, request: request)
        lock.lock()
        if disposed {
            lock.unlock()
            return failureBeforeWorker(CodeRunFailure(
                kind: .exception,
                message: "dsh-code-runtime-worker-thread: run() after disposal"))
        }
        live.append(state)
        lock.unlock()

        let result = await withTaskCancellationHandler {
            await state.awaitResult()
        } onCancel: {
            // signal→Task cancellation（登记②）：停止请求 + 检查点 finish 分派
            // （挂起情形）+ Watchdog 强制（热循环硬停）。in-flight binding 调用
            // 是 CALLER 的结算责任——运行时只停止询问（resolution 到达被
            // stopRequested 丢弃）。
            state.requestStop(CodeRunFailure(kind: .abort, message: "canceled"))
        }
        lock.lock()
        live.removeAll { $0 === state }
        lock.unlock()
        return result
    }

    /// Dispose to quiescence（worker :278-283 1:1）：标不可用、全 in-flight
    /// settle abort 'runtime disposed'（文案逐字）、await 每个 run 收敛。
    func dispose() async {
        lock.lock()
        disposed = true
        let runs = live
        live = []
        lock.unlock()
        for state in runs {
            state.requestStop(CodeRunFailure(kind: .abort, message: "runtime disposed"))
        }
        for state in runs {
            await state.notifyDone()
        }
    }

    private func isDisposed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disposed
    }

    /// worker :315-317 failureBeforeWorker——执行前失败套外层账本。
    private func failureBeforeWorker(_ error: CodeRunFailure) -> CodeRunResult {
        return OutputLedger(maxBytes: config.maxOutputBytes).failure([], error)
    }

    // MARK: - 一次 run 的宿主侧状态

    /// 单 run 状态机：串行队列承载全部 JS 操作（JSCore ObjC API 单线程纪律）；
    /// binding 异步结算经队列回归；finish 幂等（exactly one outcome wins）。
    final class RunState: @unchecked Sendable {

        private let config: JSCodeRuntimeConfig
        private let request: CodeRunRequest
        private let queue: DispatchQueue
        private let stopState: RunStopState
        private var ledger: OutputLedger
        private var logs: [String] = []
        private var settled = false
        private var settledResult: CodeRunResult?
        private var resultContinuation: CheckedContinuation<CodeRunResult, Never>?
        private var doneContinuations: [CheckedContinuation<Void, Never>] = []
        private var wallTimer: DispatchSourceTimer?
        /// 在飞 binding 的程序侧 Promise 拒绝面（token→reject）——run 中止时
        /// 统一拒绝解堵程序 await（dsh worker.terminate 硬杀的 JSCore 等价面：
        /// dsh 程序随 worker 死亡；JSCore 程序 await 在 deferred 上，不拒绝
        /// 则永不收敛——CI 实证 testAbandoned 挂死）。
        private var inflightBindingRejects: [UUID: JSValue] = [:]
        private var context: JSContext?
        private var api: JSValue?
        private var contextGroupRef: JSContextGroupRef?
        private var stopStateRef: Unmanaged<RunStopState>?

        init(config: JSCodeRuntimeConfig, request: CodeRunRequest) {
            self.config = config
            self.request = request
            self.ledger = OutputLedger(maxBytes: config.maxOutputBytes)
            self.queue = DispatchQueue(label: "wanwo.ptc.jscore.\(UUID().uuidString)")
            self.stopState = RunStopState(
                queue: queue,
                wallDefaultStop: CodeRunFailure(
                    kind: .timeout,
                    message: "wall-clock ceiling reached (\(Int(config.maxWallMs))ms)"))
        }

        private var stopRequested: Bool {
            stopState.hasPendingStop
        }

        /// run 的等待面（continuation 先登记再 start——start 首查停止请求，
        /// 竞态收口：取消早于启动也不丢结算）。
        func awaitResult() async -> CodeRunResult {
            return await withCheckedContinuation { continuation in
                self.queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: CodeRunResult(
                            logs: [],
                            error: CodeRunFailure(kind: .abort, message: "runtime disposed")))
                        return
                    }
                    if let settled = self.settledResult {
                        continuation.resume(returning: settled)
                        return
                    }
                    self.resultContinuation = continuation
                    self.start()
                }
            }
        }

        /// teardown await 面（finish 后即返；已收敛 = 立即返）。
        func notifyDone() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.queue.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    if self.settled {
                        continuation.resume()
                        return
                    }
                    self.doneContinuations.append(continuation)
                }
            }
        }

        /// 显式停止请求（取消/Dispose 面）：登记 + 在飞 binding 统一拒绝
        ///（程序侧 await 解堵——见 inflightBindingRejects 注释）+ 检查点
        /// finish 分派 + Watchdog 强制。
        func requestStop(_ failure: CodeRunFailure) {
            stopState.requestStop(failure)
            queue.async { [weak self] in
                guard let self else { return }
                self.rejectInflightBindings(failure)
                self.finishIfStopped()
            }
            forceWatchdogNow()
        }

        /// 拒绝全部在飞 binding Promise（queue 上执行；settled 后 context 已
        /// 释放——settled 守卫跳过）。
        private func rejectInflightBindings(_ failure: CodeRunFailure) {
            guard !settled, context != nil, api != nil else {
                inflightBindingRejects.removeAll()
                return
            }
            let rejects = Array(inflightBindingRejects.values)
            inflightBindingRejects.removeAll()
            guard !rejects.isEmpty else { return }
            let newErrorFn = api!.objectForKeyedSubscript("newError")!
            for reject in rejects {
                // binding 拒绝错误实例（无 errorClass = 普通 Error(reason)）。
                let errorValue = RunState.rejectionError(
                    context: context!, errorClass: nil,
                    name: JSValue(object: "binding", in: context!)!,
                    message: failure.message, newErrorFn: newErrorFn)
                reject.call(withArguments: [errorValue])
            }
        }

        /// Watchdog 立即到期（setTimeLimit(0)——cpp 内 JSLockHolder，线程安全）。
        private func forceWatchdogNow() {
            guard let setLimit = setExecutionTimeLimit,
                  let group = contextGroupRef,
                  let ref = stopStateRef else { return }
            setLimit(group, 0.0, RunState.interruptCallback, ref.toOpaque())
        }

        // MARK: 启动（全部在 queue 上）

        private func start() {
            // 真机批 B1：引擎面包屑（run_code 挂死取证——程序停在哪一步）。
            CrashBreadcrumb.log("[jscore] run start: \(request.program.prefix(80))")
            // 取消早于启动的竞态收口（continuation 已在 awaitResult 登记）。
            if stopRequested {
                finishIfStopped()
                return
            }
            // JSContext() 构造返回 Optional（ObjC 可空初始化器导入面）——
            // 实际失败面仅内存耗尽，强解包（CI 第二轮实证 optional 未解包）。
            let context = JSContext()!
            self.context = context
            // Watchdog 注册（先于任何脚本执行——头注 :84-86 生效保证）。
            let contextRef = context.jsGlobalContextRef   // 【CI 编译风险登记已兑现：Swift 导入名 jsGlobalContextRef】
            contextGroupRef = JSContextGetGroup(contextRef)
            stopStateRef = Unmanaged.passRetained(stopState)
            stopState.finishOnQueue = { [weak self] failure in
                self?.finishWithFailure(failure)
            }
            if let setLimit = setExecutionTimeLimit {
                setLimit(contextGroupRef, config.maxWallMs / 1000.0,
                         RunState.interruptCallback, stopStateRef!.toOpaque())
            }

            // 墙钟权威计时器（另一队列——热循环阻塞本队列也不受影响）。
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + config.maxWallMs / 1000.0)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.requestStop(CodeRunFailure(
                    kind: .timeout,
                    message: "wall-clock ceiling reached (\(Int(self.config.maxWallMs))ms)"))
            }
            timer.resume()
            wallTimer = timer

            // helper 脚本求值（内置捕获在程序运行前定死）。
            guard let api = context.evaluateScript(jsHelperSource), !api.isUndefined else {
                let detail = context.exception.map { $0.toString() } ?? "unknown"
                context.exception = nil
                finishWithFailure(CodeRunFailure(
                    kind: .exception,
                    message: "dsh-code-runtime-jscore: helper bootstrap failed: \(detail)"))
                return
            }
            self.api = api

            // Sucrase 转译（wrap→transform→首尾切片——dsh :302-303 序）。
            guard let sucraseSource = JSCodeRuntime.loadSucraseSource(
                bundle: Bundle(for: JSCodeRuntime.self)) else {
                finishWithFailure(CodeRunFailure(
                    kind: .exception,
                    message: "dsh-code-runtime-jscore: sucrase resource unavailable"))
                return
            }
            context.evaluateScript(sucraseSource)
            if let ex = context.exception {
                context.exception = nil
                finishWithFailure(CodeRunFailure(
                    kind: .exception,
                    message: "dsh-code-runtime-jscore: sucrase bootstrap failed: \(ex.toString())"))
                return
            }
            let prefix = JSCodeRuntime.stripWrapPrefix
            let suffix = JSCodeRuntime.stripWrapSuffix
            let wrapped = prefix + request.program + suffix
            let transform = context.globalObject
                .objectForKeyedSubscript("Sucrase")?
                .objectForKeyedSubscript("transform")
            let options = JSValue(object: ["transforms": ["typescript"]], in: context)
            let transformed = transform?.call(withArguments: [
                JSValue(object: wrapped, in: context), options,
            ])
            if transformed == nil || transformed!.isUndefined {
                let ex = context.exception
                context.exception = nil
                let message = ex.map { exceptionMessage($0) }
                    ?? "program failed to type-strip"
                // strip 失败 = 程序失败 exception，无程序执行发生（:304-309）。
                finishWithFailure(CodeRunFailure(kind: .exception, message: message))
                return
            }
            var stripped = transformed!.objectForKeyedSubscript("code")?.toString() ?? ""
            // sucrase 尾随换行差异防御（dsh node strip 严格位置保持——登记）。
            if !stripped.hasSuffix(suffix), stripped.hasSuffix(suffix + "\n") {
                stripped = String(stripped.dropLast(1))
            }
            guard stripped.hasPrefix(prefix), stripped.hasSuffix(suffix) else {
                finishWithFailure(CodeRunFailure(
                    kind: .exception,
                    message: "dsh-code-runtime-jscore: transform wrapper mismatch"))
                return
            }
            let code = String(stripped.dropFirst(prefix.count).dropLast(suffix.count))

            // bindings 桥（bootstrap :315-359 形态：null-prototype namespace +
            // 每 declared 名 own 函数 = 返回 Promise 的桥；args 无损预检）。
            // 参数序：按 namespace 序（global+errorClass 相邻），两表自身对齐
            // （bootstrap 分组序的等价重排——登记⑧）。
            var paramNames: [String] = []
            var parameterValues: [JSValue] = []
            for namespace in request.bindings {
                let nsObject = api.objectForKeyedSubscript("nullProto")!
                    .call(withArguments: [])!
                for (name, function) in namespace.functions {
                    let bridge = makeBindingBridge(
                        name: name, function: function,
                        errorClass: namespace.errorClass)
                    nsObject.setObject(bridge, forKeyedSubscript: name as NSString)
                }
                paramNames.append(namespace.global)
                parameterValues.append(nsObject)
                if let descriptor = namespace.errorClass {
                    let cls = api.objectForKeyedSubscript("makeErrorClass")!
                        .call(withArguments: [JSValue(object: [
                            "name": descriptor.name,
                            "memberNameProperty": descriptor.memberNameProperty,
                        ], in: context)])!
                    paramNames.append(descriptor.name)
                    parameterValues.append(cls)
                }
            }
            // console 捕获版注入（裁定：logs 保真 + RESERVED 槽不放松——两事不冲突）。
            let push: @convention(block) (JSValue) -> Void = { [weak self] value in
                self?.handleConsolePush(value)
            }
            let consoleShim = api.objectForKeyedSubscript("consoleShim")!
                .call(withArguments: [unsafeBitCast(push, to: AnyObject.self)])!
            paramNames.append("console")
            parameterValues.append(consoleShim)

            CrashBreadcrumb.log("[jscore] program dispatched (stripped \(code.utf8.count)B, bindings \(paramNames.count))")
            // 程序调用 → promise → settlement 桥（bootstrap :412 同构）。
            let program = api.objectForKeyedSubscript("makeProgram")!
                .call(withArguments: [
                    JSValue(object: paramNames, in: context),
                    JSValue(object: "'use strict';\n" + code, in: context),
                ])
            let promise = program!.call(withArguments: parameterValues)
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

        // MARK: bindings 桥

        /// 单个 binding 成员的 JS 函数（bootstrap :326-355 形态：args 无损
        /// 预检 → deferred promise → Swift async 结算回归队列）。
        private func makeBindingBridge(
            name: String,
            function: @escaping CodeBindingFunction,
            errorClass: CodeBindingErrorClass?
        ) -> Any {
            let context = self.context!
            let api = self.api!
            let errorClassValue: JSValue?
            if let descriptor = errorClass {
                errorClassValue = api.objectForKeyedSubscript("makeErrorClass")!
                    .call(withArguments: [JSValue(object: [
                        "name": descriptor.name,
                        "memberNameProperty": descriptor.memberNameProperty,
                    ], in: context)])
            } else {
                errorClassValue = nil
            }
            let nameValue = JSValue(object: name, in: context)!
            let encode = api.objectForKeyedSubscript("encode")!
            let deferredFn = api.objectForKeyedSubscript("deferred")!
            let rejectedFn = api.objectForKeyedSubscript("rejectedPromise")!
            let queue = self.queue
            let state = self
            let bridge: @convention(block) (JSValue) -> JSValue = { argsJS in
                // 运行于 queue（JS 执行线程）。
                let encoded = encode.call(withArguments: [argsJS])
                if encoded == nil || encoded!.isUndefined {
                    // bootstrap :336——args 无损预检拒绝（errorClass 实例化）。
                    let error = RunState.rejectionError(
                        context: context, errorClass: errorClassValue,
                        name: nameValue, message: "binding arguments must be lossless JSON",
                        newErrorFn: api.objectForKeyedSubscript("newError")!)
                    return rejectedFn.call(withArguments: [error])!
                }
                CrashBreadcrumb.log("[jscore] binding call: \(name) args=\(encoded!.toString()?.count ?? -1)B")
                let deferred = deferredFn.call(withArguments: [])
                let promise = deferred!.objectForKeyedSubscript("promise")!
                let resolve = deferred!.objectForKeyedSubscript("resolve")!
                let reject = deferred!.objectForKeyedSubscript("reject")!
                let bindingToken = UUID()
                state.registerBindingReject(bindingToken, reject)
                let argsText = encoded!.toString() ?? "null"
                Task {
                    var outcome: Result<JSONValue, Error>
                    do {
                        let decoded = try JSONDecoder().decode(
                            JSONValue.self, from: Data(argsText.utf8))
                        let value = try await function(decoded)
                        outcome = .success(value)
                    } catch {
                        outcome = .failure(error)
                    }
                    queue.async {
                        state.performBindingResolution(
                            outcome: outcome, resolve: resolve, reject: reject,
                            errorClass: errorClassValue, name: nameValue,
                            token: bindingToken)
                    }
                }
                return promise
            }
            return unsafeBitCast(bridge, to: AnyObject.self)
        }

        /// binding 拒绝错误实例（bootstrap :258-260 bindingFailure 形态；
        /// 无 errorClass = 普通 Error——helper newError 内回落）。
        private static func rejectionError(
            context: JSContext, errorClass: JSValue?, name: JSValue,
            message: String, newErrorFn: JSValue
        ) -> JSValue {
            let messageValue = JSValue(object: message, in: context)!
            let cls = errorClass ?? JSValue(nullIn: context)
            return newErrorFn.call(withArguments: [cls, name, messageValue])!
        }

        /// 在飞 binding reject 登记（run 中止面统一拒绝用）。
        func registerBindingReject(_ token: UUID, _ reject: JSValue) {
            if !settled { inflightBindingRejects[token] = reject }
        }

        /// binding 结算回归（worker :489-506 语义：resolution 无损检查 →
        /// resolve / 抛错 → messageOf reject；stopRequested 丢弃 = 只停止询问）。
        private func performBindingResolution(
            outcome: Result<JSONValue, Error>, resolve: JSValue, reject: JSValue,
            errorClass: JSValue?, name: JSValue, token: UUID
        ) {
            // RunState 可变态全在 run 队列串行（无锁——外层 lock 属 JSCodeRuntime）。
            inflightBindingRejects.removeValue(forKey: token)
            guard !settled, !stopRequested else {
                CrashBreadcrumb.log("[jscore] binding resolution dropped (settled/stop): \(name)")
                return
            }
            CrashBreadcrumb.log("[jscore] binding resolved: \(name) ok=\((try? outcome.get()) != nil ? 1 : 0)")
            let context = self.context!
            let api = self.api!
            let newErrorFn = api.objectForKeyedSubscript("newError")!
            switch outcome {
            case .success(let value):
                // resolution 无损由类型面保证；编码失败（如非有限 double）=
                // 'binding resolution must be lossless JSON'（:499）。
                guard let data = try? JSONEncoder().encode(value),
                      let text = String(data: data, encoding: .utf8) else {
                    let error = RunState.rejectionError(
                        context: context, errorClass: errorClass, name: name,
                        message: "binding resolution must be lossless JSON",
                        newErrorFn: newErrorFn)
                    reject.call(withArguments: [error])
                    return
                }
                let parsed = api.objectForKeyedSubscript("parse")!
                    .call(withArguments: [JSValue(object: text, in: context)])
                resolve.call(withArguments: [parsed!])
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)   // worker :504 messageOf 形态
                let errorValue = RunState.rejectionError(
                    context: context, errorClass: errorClass, name: name,
                    message: message, newErrorFn: newErrorFn)
                reject.call(withArguments: [errorValue])
            }
        }

        // MARK: 产出通道（logs / completion / failure）

        private func handleConsolePush(_ value: JSValue) {
            guard !settled else { return }
            let text = value.toString() ?? ""
            // worker :514-518——admit 失败 = limit（text 未入 logs，随账本重建）。
            if !ledger.admit(text, into: &logs) {
                finish(result: ledger.limit(logs + [text]))
            }
        }

        private func handleResolve(_ value: JSValue) {
            CrashBreadcrumb.log("[jscore] program resolve path entered")
            guard !settled, !stopRequested else {
                CrashBreadcrumb.log("[jscore] resolve dropped (settled/stop)")
                return
            }
            // bootstrap :171——undefined completion = 无值成功。
            if value.isUndefined {
                finish(result: ledger.success(logs, nil))
                return
            }
            let encoded = api!.objectForKeyedSubscript("encode")!
                .call(withArguments: [value])
            if encoded == nil || encoded!.isUndefined {
                // bootstrap :178-185——snapshot 失败 = invalid-output。
                finish(result: ledger.failure(logs, CodeRunFailure(
                    kind: .invalidOutput,
                    message: "program completion must be lossless JSON")))
                return
            }
            let text = encoded!.toString() ?? "null"
            guard let json = try? JSONDecoder().decode(
                JSONValue.self, from: Data(text.utf8)) else {
                finish(result: ledger.failure(logs, CodeRunFailure(
                    kind: .invalidOutput,
                    message: "program completion must be lossless JSON")))
                return
            }
            // bootstrap :186-188——字节超限 = output-limit。
            if OutputJSON.jsonValueBytesUpTo(json, ledger.remainingOutputBytes()) == nil {
                finish(result: ledger.failure(logs, CodeRunFailure(
                    kind: .outputLimit,
                    message: "outer output exceeded \(config.maxOutputBytes) bytes")))
                return
            }
            finish(result: ledger.success(logs, json))
        }

        private func handleReject(_ error: JSValue) {
            CrashBreadcrumb.log("[jscore] program reject path entered")
            guard !settled, !stopRequested else {
                CrashBreadcrumb.log("[jscore] reject dropped (settled/stop)")
                return
            }
            // bootstrap :216-229 prepareException——stack??message→String，
            // 不可渲染 = 固定文案。
            let rendered = api!.objectForKeyedSubscript("messageOf")!
                .call(withArguments: [error])
            let message = rendered.flatMap {
                ($0.isNull || $0.isUndefined) ? nil : $0.toString()
            } ?? "program threw an unrenderable value"
            finish(result: ledger.failure(logs, CodeRunFailure(
                kind: .exception, message: message)))
        }

        private func exceptionMessage(_ exception: JSValue) -> String {
            let rendered = api?.objectForKeyedSubscript("messageOf")?
                .call(withArguments: [exception])
            return rendered.flatMap {
                ($0.isNull || $0.isUndefined) ? nil : $0.toString()
            } ?? exception.toString()
        }

        // MARK: 收敛（exactly one outcome wins）

        /// Watchdog 回调（C 函数指针，无捕获——状态经 data 指针承载）。
        private static let interruptCallback: @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool = { _, data in
            guard let data else { return false }
            let stopState = Unmanaged<RunStopState>.fromOpaque(data).takeUnretainedValue()
            stopState.dispatchStop()
            return true   // 终止脚本执行（热循环硬停——Watchdog 语义）
        }

        private func finishIfStopped() {
            guard !settled, stopState.hasPendingStop else { return }
            // 尚未启动（continuation 已登记、start 未跑）——保持 pending，
            // start() 首查收口。
            guard resultContinuation != nil else { return }
            let stop = stopState.takeStop()
            finish(result: ledger.failure(logs, stop))
        }

        private func finishWithFailure(_ failure: CodeRunFailure) {
            guard !settled else { return }
            finish(result: ledger.failure(logs, failure))
        }

        /// 幂等收敛：清理计时器/Watchdog/JS 引用，结算 continuation 与 done 面。
        private func finish(result: CodeRunResult) {
            guard !settled else { return }
            CrashBreadcrumb.log("[jscore] finish: \(result.error?.kind.rawValue ?? "success") logs=\(result.logs.count)")
            settled = true
            settledResult = result
            wallTimer?.cancel()
            wallTimer = nil
            if let ref = stopStateRef {
                stopStateRef = nil
                ref.release()   // Unmanaged 平衡 passRetained
            }
            contextGroupRef = nil
            api = nil
            inflightBindingRejects.removeAll()   // context 释放后拒绝面失效
            context = nil   // JS 引用随 context 释放（块↔状态环由 context 死亡破除）
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
            let dones = doneContinuations
            doneContinuations = []
            for continuation in dones {
                continuation.resume()
            }
        }
    }
}
