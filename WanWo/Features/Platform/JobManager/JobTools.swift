//
//  JobTools.swift
//  WanWo
//
//  【M5-A 批 J3 · 后台作业三工具 + 完成通知文本 + tool:jobs prompt 段】
//  出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/jobs/tool-jobs/src/index.ts（401 行全文）：
//    - :54-95  PublicJobSnapshot + publicJob（bookkeeping 字段剥除）
//    - :97-106 statusLine（`[status: N]` / `[status: N, detail]` 双形态）
//    - :108-166 TextRetainer head/tail 消费面 + fitWithSuffix +
//      fitCompletionNotice 四段降级链（UTF-8 字节语义）
//    - :191-197 validateJobId（非空约束，文案逐字）
//    - :262-266 tool:jobs prompt 段（文本逐字；order=TOOL_JOBS=1600）
//    - :278-299 onJobDone 完成通知（文本面 = JobCompletionNotice；投递面
//      在 AppEnvironment.makeAgentStack 接线）
//    - :301-339 job_output / :341-359 job_list / :361-400 job_kill
//  平台差异登记：
//    - dsh output.schema + render + finalizeContent 管线 → WanWo ToolOutput
//      单文本形态：render 与 finalizeContent 规范路径在 execute 内合流
//      （job_output 用 '\n[output truncated]' 预算拟合、job_kill 用
//      '\n[result truncated]' 的 boundSingleText 形态、job_list 无预算）。
//      字节预算来源同为作业的 outputLimitBytes（dsh 经 visibleOutputLimit
//      预取——快照字段静态，读路径等价，登记）。
//    - dsh wait/kill 的 AbortSignal → Task cancellation（J1 裁定延续）；
//      超时等待返回作业态而非 TOOL_TIMEOUT 错 → 本工具不用协议 timeoutMs
//      （dsh :306-308 同注）。
//    - dsh presentTaskCall 的 card:'generic' → ToolCardIntent(.generic)。
//    - 完成通知投递：dsh busy inject / idle wakeup + spentWakes 预算 →
//      WanWo 恒注入（AgentLoop.inject）；wakeup 预算登记不实现（派单裁定，
//      TODO(wakeup-budget) 上游同注）。
//

import Foundation

// MARK: - 公共快照投影（index.ts:54-95）

/// 模型侧安全的任务状态（dsh PublicJobSnapshot：ownership 与通知记账字段
/// outputLimitBytes / ownerSessionId / reported 剥除——publicJob :85-95 1:1；
/// Swift 结构体可选 nil ≡ dsh 条件展开的缺键，wire 等价，登记）。
public struct PublicJobSnapshot: Equatable, Sendable {
    public let id: String
    public let kind: JobKind
    public let label: String
    public let status: JobStatus
    public let detail: String?
    public let startedAt: Int64
    public let finishedAt: Int64?
}

/// index.ts:85-95 publicJob 1:1：从注册表快照剥除持有与记账字段。
func publicJob(_ snapshot: JobSnapshot) -> PublicJobSnapshot {
    PublicJobSnapshot(
        id: snapshot.id,
        kind: snapshot.kind,
        label: snapshot.label,
        status: snapshot.status,
        detail: snapshot.detail,
        startedAt: snapshot.startedAt,
        finishedAt: snapshot.finishedAt)
}

// MARK: - 状态行（index.ts:97-106）

/// index.ts:102-106 statusLine 1:1：detail 在场 = `[status: N, detail]`，
/// 否则 `[status: N]`。
func jobStatusLine(status: JobStatus, detail: String?) -> String {
    if let detail {
        return "[status: \(status.rawValue), \(detail)]"
    }
    return "[status: \(status.rawValue)]"
}

// MARK: - UTF-8 边界保留截断（output-retention TextRetainer 消费面）

/// dsh output-retention index.ts:211-222 trimTrailingPartialUtf8 1:1：头部
/// 截点回扫 continuation 字节（0b10xxxxxx）到 lead 字节；lead 宣称的序列长
/// 度未凑齐即裁掉（截点永不产出替换符）。真畸形内部序列留给解码器替换。
private func trimTrailingPartialUtf8(_ bytes: [UInt8]) -> [UInt8] {
    var i = bytes.count - 1
    // 最多回扫 3 个（最长序列 4 字节）；越界由循环守卫承担。
    while i >= 0 && (bytes[i] & 0xC0) == 0x80 && bytes.count - i <= 3 { i -= 1 }
    if i < 0 { return bytes }
    let lead = bytes[i]
    let expected = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : lead < 0xF8 ? 4 : 0
    // expected 0 → 不是 lead 字节（孤立 continuation / 非法）：不动。
    if expected == 0 { return bytes }
    return bytes.count - i < expected ? Array(bytes[0..<i]) : bytes
}

/// index.ts:228-233 trimLeadingContinuationUtf8 1:1：尾部截点丢弃开头
/// continuation 字节，从 lead/ASCII 字节重新起步。
private func trimLeadingContinuationUtf8(_ bytes: [UInt8]) -> [UInt8] {
    var i = 0
    while i < bytes.count && (bytes[i] & 0xC0) == 0x80 { i += 1 }
    return Array(bytes[i...])
}

/// TextRetainer head 形态单推消费面（index.ts:247-386 中 head 语义 + finish
/// 截点边界修剪）。字节数不超预算=全保不裁（retainer 层 prefixLen =
/// min(total, cap) 同语义）；`String(decoding:)` 非致命解码（内部畸形 →
/// U+FFFD，dsh TextDecoder non-fatal 同语义）。
func retainHead(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    let bytes = Array(text.utf8)
    guard bytes.count > maxBytes else { return text }
    return String(decoding: trimTrailingPartialUtf8(Array(bytes[0..<maxBytes])), as: UTF8.self)
}

/// TextRetainer tail 形态单推消费面（同上，tail 变体）。
func retainTail(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    let bytes = Array(text.utf8)
    guard bytes.count > maxBytes else { return text }
    return String(decoding: trimLeadingContinuationUtf8(Array(bytes[(bytes.count - maxBytes)...])), as: UTF8.self)
}

/// index.ts:122-134 fitWithSuffix 1:1：content+suffix 预算内直返；超限先补
/// omitted 标记（content 已带该标记则不重复——JS trimStart() 仅去头部空白，
/// Swift Character.isWhitespace 覆盖 \n）；补完仍超 → 纯尾部保留整串；
/// 否则尾部保留 content 腾出 fixedBytes 后接 fixed。
func fitWithSuffix(_ content: String, _ suffix: String,
                   _ maxBytes: Int?, _ omitted: String) -> String {
    guard let maxBytes else { return content + suffix }
    let complete = content + suffix
    if complete.utf8.count <= maxBytes { return complete }
    let trimmedOmitted = String(omitted.drop(while: { $0.isWhitespace }))
    let fixed = (content.hasSuffix(trimmedOmitted) ? "" : omitted) + suffix
    let fixedBytes = fixed.utf8.count
    if fixedBytes >= maxBytes { return retainTail(fixed, maxBytes: maxBytes) }
    return retainTail(content, maxBytes: maxBytes - fixedBytes) + fixed
}

// MARK: - 完成通知文本（index.ts:136-166）

/// 作业完成通知的模型侧文本（dsh fitCompletionNotice 四段降级链 1:1；
/// 字节预算 = 快照的 outputLimitBytes）。投递面（owner 过滤 + inject）在
/// AppEnvironment.makeAgentStack——dsh onJobDone 回调的 WanWo 对应。
enum JobCompletionNotice {
    /// index.ts:145-166 fitCompletionNotice 1:1。降级链：完整 →
    /// prefix+头部保留 detail+omitted+action → prefix+action →
    /// 尾部保留 action / 头部保留 prefix+action。
    static func text(for snapshot: JobSnapshot) -> String {
        // 【系统通知】前缀（真机批 B4）：投影层 markerPrefixes 据此隐藏
        // （用户无感——纸条是给 AI 的中间事件，不冒充用户气泡）；AI 侧
        // 前缀即来源标识，语义清晰。
        let prefix = "【系统通知】background job \(snapshot.id)"
        let detail = " (\(snapshot.kind.rawValue): \(snapshot.label)) finished "
            + jobStatusLine(status: snapshot.status, detail: snapshot.detail)
        let action = "\nDone; job_output."
        let complete = "\(prefix)\(detail). Read its output with job_output."
        guard let maxBytes = snapshot.outputLimitBytes else { return complete }
        if complete.utf8.count <= maxBytes { return complete }
        let omitted = "\n[notice truncated]"
        let fixed = "\(prefix)\(omitted)\(action)"
        let fixedBytes = fixed.utf8.count
        if fixedBytes <= maxBytes {
            return fixedBytes == maxBytes
                ? fixed
                : "\(prefix)\(retainHead(detail, maxBytes: maxBytes - fixedBytes))\(omitted)\(action)"
        }
        let compact = "\(prefix)\(action)"
        if compact.utf8.count <= maxBytes { return compact }
        let actionBytes = action.utf8.count
        if actionBytes >= maxBytes { return retainTail(action, maxBytes: maxBytes) }
        return "\(retainHead(prefix, maxBytes: maxBytes - actionBytes))\(action)"
    }
}

// MARK: - job_id 校验（index.ts:191-197）

/// index.ts:192-197 validateJobId 1:1：ParameterSchemaSpec 表达不了的非空
/// 约束（文案逐字——JSON.stringify("") = `""`）。
func validateJobId(_ value: String) throws -> String {
    if value.isEmpty {
        throw JobRegistryError(message: "invalid job_id: expected a non-empty string, got \"\"")
    }
    return value
}

// MARK: - 工具错误出口

/// 注册表错误的 WanWo 失败身份：message 逐字透传（dsh execute 抛错经框架
/// 合成错误结果——WanWo 由 pipeline 合成面承接，此处 ToolOutput.failure 同
/// 语义；name/code 面为 WanWo 工具失败身份，非 dsh 词汇，登记）。
private func jobFailure(_ error: Error, code: String) -> ToolOutput {
    .failure((error as? JobRegistryError)?.message ?? String(describing: error), code: code)
}

// MARK: - job_output（index.ts:301-339）

/// 读取后台作业（dsh job_output 的 WanWo 形态）。流式作业只回上次读取以来
/// 的增量；仅终态输出作业在结算后回结果。响应恒以 `[status: ...]` 收尾。
struct JobOutputTool: AgentTool {
    let name = "job_output"
    let description = "Read a background job. Stream jobs return only output since the previous read; "
        + "final-output jobs return their result after settlement. Every response ends with "
        + "`[status: ...]`. Reads are non-blocking unless `wait: true`, which waits up to the configured cap."

    /// 超时的等待返回作业态而非 TOOL_TIMEOUT 错（dsh :306-308 注释）——
    /// 本工具自持 deadline，不用协议协作超时（默认 nil）。
    let timeoutMs: Int? = nil

    let sessionId: String
    /// 注册表缝（dsh ctx.jobs；装配注入——ShellTool.jobs 同模式）。
    let jobs: JobRegistryProtocol

    /// dsh Config 缺省（index.ts:48-49）：waitTimeoutMs 30s / maxWaitTimeoutMs 10min。
    static let waitDefaultMs = 30_000
    static let waitCapMs = 600_000

    let parameters: JSONValue = .schemaObject(properties: [
        "job_id": .stringSchema(description: "Job id returned by the tool that started the background work."),
        "wait": .booleanSchema(description: "Block until the job reaches a terminal status or the timeout expires. A timed-out wait returns [status: running] and leaves the job alive."),
        "timeout_ms": .numberSchema(description: "Max wait in milliseconds (only meaningful with wait: true). Defaults to the configured wait timeout; capped by the configured maximum."),
    ], required: ["job_id"])

    /// dsh presentTaskCall(:338)：generic 卡 + rawInput=job_id。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        let jobId = args.objectValue?["job_id"]?.stringValue ?? ""
        return ToolCardIntent(kind: .generic,
                              title: "Read output from background job \(jobId)",
                              detail: jobId)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let rawId = args.objectValue?["job_id"]?.stringValue else {
            return .failure("missing required parameter \"job_id\"", code: "INVALID_ARGS")
        }
        let id: String
        do {
            id = try validateJobId(rawId)
        } catch {
            return jobFailure(error, code: "INVALID_JOB_ID")
        }
        // dsh :331-334：wait=true 才等待；timeout = min(timeout_ms ?? 30s, 600s)。
        if args.objectValue?["wait"]?.boolValue == true {
            let requested = args.objectValue?["timeout_ms"]?.intValue ?? Self.waitDefaultMs
            let timeoutMs = min(requested, Self.waitCapMs)
            _ = try await jobs.wait(id: id, timeoutMs: Int64(timeoutMs),
                                    callerSessionId: ctx.sessionId)
        }
        let read: JobRead
        do {
            read = try jobs.read(id: id, callerSessionId: ctx.sessionId)
        } catch {
            return jobFailure(error, code: "JOB_OUTPUT_FAILED")
        }
        // dsh render(:323-327) 与 finalizeContent 规范路径(:241-253)合流：
        // body = text | '(no new output)'；content 去掉一个尾换行；
        // suffix = '\n' + statusLine；有预算时 fitWithSuffix(
        // content, suffix, maxBytes, '\n[output truncated]')。
        let body = read.text.isEmpty ? "(no new output)" : read.text
        let content = body.hasSuffix("\n") ? String(body.dropLast()) : body
        let suffix = "\n" + jobStatusLine(status: read.snapshot.status,
                                          detail: read.snapshot.detail)
        let text = fitWithSuffix(content, suffix, read.snapshot.outputLimitBytes,
                                 "\n[output truncated]")
        return .success(text, meta: .object([
            "jobId": .string(read.snapshot.id),
            "status": .string(read.snapshot.status.rawValue),
        ]))
    }
}

// MARK: - job_list（index.ts:341-359）

/// 列出 caller 可见（own + unowned）的后台作业（dsh job_list 的 WanWo 形态）。
struct JobListTool: AgentTool {
    let name = "job_list"
    let description = "List your background jobs (running and finished) with their ids, kinds, and statuses."
    let timeoutMs: Int? = nil

    let sessionId: String
    let jobs: JobRegistryProtocol

    let parameters: JSONValue = .schemaObject(properties: [:], required: [])

    /// dsh presentTaskCall(:358)。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .generic, title: "List background jobs")
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // dsh :354-356：ctx.jobs.list(exec.agent) → publicJob 逐条。
        let snapshots = jobs.list(callerSessionId: ctx.sessionId).map(publicJob)
        // dsh render(:347-352)：空集 '(no background jobs)'；否则单行
        // `<id> [<kind>] <status> — <label>` 按换行拼接（无输出预算面）。
        let text = snapshots.isEmpty
            ? "(no background jobs)"
            : snapshots
                .map { "\($0.id) [\($0.kind.rawValue)] \($0.status.rawValue) — \($0.label)" }
                .joined(separator: "\n")
        return .success(text)
    }
}

// MARK: - job_kill（index.ts:361-400）

/// 按作业 id 请求取消在飞后台作业（dsh job_kill 的 WanWo 形态）。立即返回；
/// 作业在其工作实际停止后结算为 killed。
struct JobKillTool: AgentTool {
    let name = "job_kill"
    let description = "Request cancellation of a running background job by job id. Returns immediately; the job settles as killed once its work actually stops."
    let timeoutMs: Int? = nil

    let sessionId: String
    let jobs: JobRegistryProtocol

    let parameters: JSONValue = .schemaObject(properties: [
        "job_id": .stringSchema(description: "Job id returned by the tool that started the background work."),
        "reason": .stringSchema(description: "Optional short reason, recorded in the log and forwarded to the job."),
    ], required: ["job_id"])

    /// dsh presentTaskCall(:399)。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        let jobId = args.objectValue?["job_id"]?.stringValue ?? ""
        return ToolCardIntent(kind: .generic,
                              title: "Kill background job \(jobId)",
                              detail: jobId)
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let rawId = args.objectValue?["job_id"]?.stringValue else {
            return .failure("missing required parameter \"job_id\"", code: "INVALID_ARGS")
        }
        let id: String
        do {
            id = try validateJobId(rawId)
        } catch {
            return jobFailure(error, code: "INVALID_JOB_ID")
        }
        do {
            let result = try jobs.kill(id: id, callerSessionId: ctx.sessionId,
                                       reason: args.objectValue?["reason"]?.stringValue)
            // dsh :392-393 注释：快照描述当前状态，不消费待读输出。
            let snapshot = try jobs.get(id: id, callerSessionId: ctx.sessionId)
            let outcome = result == .alreadyFinished ? "already-finished" : "cancellation-requested"
            // dsh render(:382-387) 逐字。
            let rendered = outcome == "already-finished"
                ? "job \(snapshot.id) had already finished "
                    + jobStatusLine(status: snapshot.status, detail: snapshot.detail)
                : "requested cancellation of job \(snapshot.id)"
            // dsh finalizeContent job_kill 面(:237-256 → boundSingleText
            // :175-182)：fitWithSuffix(text, '', maxBytes, '\n[result truncated]')。
            let text = fitWithSuffix(rendered, "", snapshot.outputLimitBytes,
                                     "\n[result truncated]")
            return .success(text, meta: .object([
                "jobId": .string(snapshot.id),
                "outcome": .string(outcome),
            ]))
        } catch {
            return jobFailure(error, code: "JOB_KILL_FAILED")
        }
    }
}

// MARK: - 装配（dsh apply 的 WanWo 对应面）

/// J3 装配面：三工具注册 + tool:jobs prompt 段 + 完成通知文本。
enum JobTools {

    /// dsh tool-jobs index.ts:265 逐字（跨调用指引：跨文件系统段落之后、
    /// 产品段落之前——order = SECTION_ORDERS.toolJobs = dsh TOOL_JOBS = 1600）。
    static let promptSectionText = "Track every background job id you start. You are notified in-session "
        + "when a job finishes — do not busy-poll or sleep on one; keep working on independent steps "
        + "and do not duplicate a running job's work. Before giving a final answer, collect every "
        + "still-relevant job with job_output (set wait: true only when you are genuinely blocked on "
        + "it), and job_kill jobs that stopped mattering."

    /// index.ts:262-266 section 注册形态 1:1（name 'tool:jobs'）。
    static func promptSection() -> PromptSection {
        PromptSection(name: "tool:jobs",
                      order: SECTION_ORDERS.toolJobs,
                      text: promptSectionText)
    }

    /// 三工具注册（dsh ctx.tools.register ×3 对应）。controller 挂接
    /// （dsh :259 attachController('tool-jobs')）已在 AppEnvironment init
    /// 随 jobRegistry 建立——此处不重复挂。
    static func registerAll(into registry: ToolRegistry,
                            sessionId: String,
                            jobs: JobRegistryProtocol) {
        registry.register(JobOutputTool(sessionId: sessionId, jobs: jobs))
        registry.register(JobListTool(sessionId: sessionId, jobs: jobs))
        registry.register(JobKillTool(sessionId: sessionId, jobs: jobs))
    }
}
