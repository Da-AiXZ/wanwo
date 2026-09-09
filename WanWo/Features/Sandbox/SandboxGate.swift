//
//  SandboxGate.swift
//  WanWo
//
//  【语义移植 · dsh · P1-3 判定矩阵重做】执行层围栏 + 提权缝的工具侧统一入口。
//  出处（源码原件逐条对位）：
//    - dsh packages/fs/tool-fs/src/sandbox.ts:87-108 resolvePolicy —— 每次执行
//      先 validateEscalationArgs，无提权参数返回 standing policy，有则
//      approveEscalation（subject='operation'）→ {...policy, mode: approvedMode}
//      （approved 模式仅 stamp 本调用）。
//    - dsh packages/fs/fs-sandbox/src/index.ts:122-144 checkedTarget 三分支 ——
//      danger-full-access 直通（:125）/ read-only 拒绝一切 mutation（:127）/
//      workspace-write 对 fresh canonical path 做 containment（:132-139）。
//    - dsh packages/fs/tool-fs/src/sandbox.ts:124-130 mapError —— 沙箱拒绝
//      合成 `${sandboxDenialMarker(mode)}\n${escalationHintMarker(subject)}`，
//      code FS_SANDBOX_DENIED（isError 结果，原文案被整体替换）。
//    - dsh 头注 fs-sandbox index.ts:1-27 —— Reads pass through untouched：
//      每个模式都允许读取；围栏只拦 mutation。
//  WanWo 平台近似（A2 登记 · 不可抗力）：
//    · fs 三件（write/edit/str_replace_editor）在宿主直读工作区桶上执行——
//      围栏为词法前缀 containment（guest Linux 语义：root=/var/wanwo/workspace
//      + /tmp 白名单；`..` 逃逸由 WorkspaceFileAccess.resolve 既有防线拦截）。
//    · bash 无内核级围栏：read-only 档以启发式写检测近似（重定向/tee/cp/mv/
//      rm/dd/mkdir/touch/sed -i/chmod/chown/ln/truncate 等模式表 + 重定向
//      字符扫描兜底，/dev/null sink 豁免——dsh read-only「仅必需 sinks」语义）；
//      workspace-write 档不设围栏（启发式无法验证 containment，dsh 由内核
//      强制——漏检面登记为 A2 不可抗力）。
//

import Foundation

// MARK: - 提权参数 schema 字段（dsh tool-fs sandbox.ts schemaFields :59-73）

extension SandboxGate {
    /// sandbox_permissions + justification 的 schema 字段（registry-global 闭集
    /// enum = ESCALATION_TARGETS；严格加宽是执行时 per-call 检查）。fs 三件
    /// noun = "file operation"（description 逐字）；bash noun = "command"
    /// （dsh escalation.ts:140 subject 文档的名词形态——登记 A2 适配）。
    static func escalationSchemaFields(noun: String) -> [String: JSONValue] {
        [
            "sandbox_permissions": .enumSchema(
                description: "The wider sandbox mode this \(noun) needs. Only valid as a one-shot retry "
                    + "of an operation the sandbox just denied; requires justification and user approval.",
                allowedValues: SandboxEscalationTargets.all.map(\.rawValue)),
            "justification": .stringSchema(
                description: "Required with sandbox_permissions: one sentence for the user explaining "
                    + "why this exact \(noun) needs the wider access."),
        ]
    }
}

// MARK: - 每调用模式解析（dsh tool-fs sandbox.ts resolvePolicy 语义）

enum SandboxGate {

    /// 解析一笔调用的生效模式：无提权参数 → standing 模式；有 → 校验成对 +
    /// approveEscalation（授予模式仅 stamp 本调用）。
    /// - Returns: `.success(mode)` = 可执行；`.failure(message)` = 合成错误
    ///   结果（message = dsh 逐字文案；什么都没执行）。
    static func resolveMode(tool: String,
                            args: JSONValue,
                            standingMode: SandboxMode,
                            subject: String,
                            callId: String?,
                            approver: SandboxEscalationApprover?) async
        -> Result<SandboxMode, String> {
        let requested = args.objectValue?["sandbox_permissions"]?.stringValue
        let justification = args.objectValue?["justification"]?.stringValue
        // 成对校验先行（dsh resolvePolicy 第一步；三条逐字错误）。
        do {
            try validateEscalationArgs(sandboxPermissions: requested,
                                       justification: justification)
        } catch let error as SandboxEscalationError {
            return .failure(error.message)
        } catch {
            return .failure(String(describing: error))
        }
        guard let requested, let justification else {
            return .success(standingMode)
        }
        do {
            let granted = try await SandboxEscalation.approve(
                requestedMode: requested,
                justification: justification,
                effectiveMode: standingMode,
                subject: subject,
                toolName: tool,
                callId: callId,
                approver: approver)
            return .success(granted)
        } catch let error as SandboxEscalationError {
            return .failure(error.message)
        } catch {
            return .failure(String(describing: error))
        }
    }

    // MARK: fs 围栏（checkedTarget 三分支 + 词法 containment）

    /// 词法前缀 containment（guest Linux 语义）。相对路径（含 ./）按 cwd=工作区
    /// 归入；绝对路径必须落在 workspaceRoot 或 /tmp 白名单内（dsh roots.ts
    /// writableRoots 的 WanWo 形态，见 SandboxPolicy 头注）。
    static func fsPathUnderWritableRoots(_ path: String, mode: SandboxMode) -> Bool {
        switch mode {
        case .dangerFullAccess:
            return true   // dsh checkedTarget :125 直通
        case .readOnly:
            return false  // dsh checkedTarget :127：read-only 拒绝一切 mutation
        case .workspaceWrite:
            break
        }
        // 归一：剥引号与首部 "./"。
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("\"") && p.hasSuffix("\"") && p.count >= 2 {
            p = String(p.dropFirst().dropLast())
        }
        if p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        if !p.hasPrefix("/") {
            return true   // 相对路径：cwd 恒为工作区（dsh session cwd 语义）
        }
        let roots = SandboxPolicy.writableRoots(.workspaceWrite)
        for root in roots {
            if p == root || p.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// fs mutation 的完整门（resolvePolicy → checkedTarget → mapError）。
    /// - Returns: nil = 放行（工具体继续）；非 nil = 合成错误结果（isError）。
    static func authorizeFsMutation(tool: String,
                                    path: String,
                                    args: JSONValue,
                                    standingMode: SandboxMode,
                                    callId: String?,
                                    approver: SandboxEscalationApprover?) async -> ToolOutput? {
        let mode: SandboxMode
        switch await resolveMode(tool: tool, args: args, standingMode: standingMode,
                                 subject: "operation", callId: callId, approver: approver) {
        case .success(let resolved): mode = resolved
        case .failure(let message):
            return .failure(message, code: "SANDBOX_ESCALATION_ERROR")
        }
        guard fsPathUnderWritableRoots(path, mode: mode) else {
            // dsh mapError（tool-fs sandbox.ts:124-130）：denial marker + hint
            // 逐字，原文案整体替换；isError 结果。
            return .failure(sandboxDenialMarker(mode) + "\n" + escalationHintMarker("operation"),
                            code: "FS_SANDBOX_DENIED")
        }
        return nil
    }

    // MARK: bash 近似围栏（启发式写检测 · A2 不可抗力）

    /// read-only 档的 bash 门（workspace-write / danger-full-access 不设围栏）。
    /// - Returns: nil = 放行；非 nil = 合成错误结果（isError）。
    static func authorizeBash(tool: String,
                              command: String,
                              args: JSONValue,
                              standingMode: SandboxMode,
                              callId: String?,
                              approver: SandboxEscalationApprover?) async -> ToolOutput? {
        let mode: SandboxMode
        switch await resolveMode(tool: tool, args: args, standingMode: standingMode,
                                 subject: "command", callId: callId, approver: approver) {
        case .success(let resolved): mode = resolved
        case .failure(let message):
            return .failure(message, code: "SANDBOX_ESCALATION_ERROR")
        }
        guard mode == .readOnly, bashLikelyWrites(command) else { return nil }
        return .failure(sandboxDenialMarker(mode) + "\n" + escalationHintMarker("command"),
                        code: "FS_SANDBOX_DENIED")
    }

    /// 启发式写检测模式表（read-only 档近似；dsh 内核围栏的 WanWo 形态——
    /// 漏检面登记 A2 不可抗力）。
    static func bashLikelyWrites(_ command: String) -> Bool {
        // ① 必需 sink 豁免（dsh read-only「仅必需 sinks 如 /dev/null」语义）：
        //    剥掉所有 `N> /dev/null` / `>/dev/null` 形态后再扫重定向。
        let devNull = try? NSRegularExpression(pattern: "[0-9]*>\\s*/dev/null")
        let stripped = devNull.map {
            $0.stringByReplacingMatches(in: command,
                                        range: NSRange(command.startIndex..., in: command),
                                        withTemplate: "")
        } ?? command
        // ② 重定向字符扫描兜底（fail closed：任何残余 `>` / `>>` 均视为写，
        //    包括 `2>`、`&>`、heredoc 到文件等复杂形态）。
        if stripped.contains(">") { return true }
        // ③ 首 token 白名单式写命令表（引号不切分的保守形态足够——首 token
        //   恒在首个未引用空白前）。
        let first = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = first.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .first.map(String.init) ?? ""
        let writeCommands: Set<String> = [
            "cp", "mv", "rm", "dd", "mkdir", "touch", "chmod", "chown", "chgrp",
            "ln", "truncate", "mkfs", "shred", "install", "patch", "tee",
            "apk", "apt", "apt-get", "pip", "pip3", "npm", "wget", "curl",
        ]
        if writeCommands.contains(head) { return true }
        // ④ 原位编辑旗标（sed -i / --in-place）。
        if head == "sed" {
            let tokens = Set(command.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init))
            if tokens.contains("-i") || tokens.contains("--in-place") { return true }
        }
        // ⑤ tee 可出现在管道中段（如 `cat x | tee y`）——独立扫 token。
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        if tokens.contains("tee") { return true }
        return false
    }
}
