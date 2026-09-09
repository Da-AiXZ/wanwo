//
//  SandboxPolicy.swift
//  WanWo
//
//  【语义移植 · dsh · P1-3 判定矩阵重做】出处（源码原件逐条对位）：
//    - dsh packages/sandbox/sandbox/src/index.ts:23-29 —— SandboxMode 三值词汇
//      （read-only 仅必需 sinks 如 /dev/null；workspace-write 加 workspace+temp；
//      网络与进程可见性不在词汇内）。
//    - dsh packages/sandbox/sandbox-policy/src/index.ts:41-58
//      renderPolicyContext —— 三段模型可见策略文案逐字（110 号上下文位）。
//    - dsh packages/sandbox/sandbox/src/roots.ts:38-55 writableRoots ——
//      read-only 返回空表；workspace-write 返回 workspaceRoot + /tmp + 平台
//      temp dir（去重 + canonical 化）。
//    - dsh packages/sandbox/sandbox-policy/src/index.ts:55-71 resolve ——
//      approved 显式（本调用 stamp）> 会话末条 sandbox/mode > 部署默认。
//  WanWo 落地差异（登记）：
//    · workspaceRoot = /var/wanwo/workspace（对齐广告口径——ShellTool description
//      与 FsContextRouter 既有口径；dsh 用会话 cwd 或部署配置，差异呈报用户裁决）。
//    · guest 是 Linux 语义：temp 白名单 = /tmp（dsh 的宿主 tmpdir() 分支在
//      WanWo 无对应物——fs 工具宿主直读只达工作区桶；词法围栏承认 /tmp，
//      实际写 /tmp 由 WorkspaceFileAccess 现有边界拒绝，非沙箱拒绝）。
//

import Foundation

// MARK: - SandboxMode（dsh sandbox/src/index.ts:23-29 三值词汇）

/// 沙箱模式三值闭集（dsh SandboxMode 1:1；rawValue = wire 词汇）。
enum SandboxMode: String, Equatable, Sendable, Codable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    /// dsh SANDBOX_MODES 全集。
    static let all: [SandboxMode] = [.readOnly, .workspaceWrite, .dangerFullAccess]
}

// MARK: - 沙箱策略常量（workspaceRoot + writableRoots + renderPolicyContext）

enum SandboxPolicy {
    /// 会话工作区（guest 视角；对齐 ShellTool/FsContextRouter 广告口径）。
    static let workspaceRoot = WanWoPaths.workspaceLinuxDir
    /// temp 白名单（Linux guest 语义；dsh roots.ts 的 /tmp 分支 1:1）。
    static let tempRoot = "/tmp"

    /// dsh roots.ts:38-55 writableRoots：read-only 空表；workspace-write =
    /// workspace root + temp（dsh 另含宿主 tmpdir()，WanWo 无对应物——见头注）。
    static func writableRoots(_ mode: SandboxMode) -> [String] {
        switch mode {
        case .readOnly:
            return []
        case .workspaceWrite:
            // dsh 去重语义（Set）：workspaceRoot ≠ /tmp 时两元素。
            return workspaceRoot == tempRoot ? [workspaceRoot] : [workspaceRoot, tempRoot]
        case .dangerFullAccess:
            // dsh 全挡不限写（writableRoots 只服务 workspace-write 围栏）。
            return [workspaceRoot, tempRoot]
        }
    }

    /// dsh renderPolicyContext（sandbox-policy index.ts:41-58）三段逐字；
    /// workspace-write 段的 `${JSON.stringify(policy.workspaceRoot)}` 以带引号
    /// 字面量承载（JSON.stringify("/var/wanwo/workspace") === "\"/var/wanwo/workspace\""）。
    static func renderPolicyContext(_ mode: SandboxMode) -> String {
        switch mode {
        case .readOnly:
            return "Current DSH file policy: read-only. Any available operation enforced "
                + "by the DSH file sandbox cannot modify files in the standing mode. Do not "
                + "refuse a required modification from this policy alone: try an available "
                + "tool normally and follow any denial and escalation guidance it returns."
        case .workspaceWrite:
            return "Current DSH file policy: workspace-write. Any available operation "
                + "enforced by the DSH file sandbox may modify files under the session "
                + "workspace: \"\(workspaceRoot)\". Some platform temporary areas may also be writable."
        case .dangerFullAccess:
            return "Current DSH file policy: danger-full-access. The DSH file sandbox does "
                + "not restrict file modifications by available operations."
        }
    }
}
