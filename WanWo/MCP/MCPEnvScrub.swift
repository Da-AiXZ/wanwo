//
//  MCPEnvScrub.swift
//  WanWo
//
//  【M4-A 件7 · 凭据擦除 scrub】dsh 子进程缝共享清洗词汇（出处：
//  packages/subprocess/subprocess——定义本体）。锚点取证说明（呈报①）：
//  本地快照不含 packages/subprocess/ 目录（docs/subsystems/subprocess.md:5/:7
//  引用的 packages/subprocess/subprocess/src/{types,index}.ts 落空；快照非
//  git 仓库无历史可考），定义本体源码缺失——锚点降级为：
//    · packages/mcp/mcp-client/README.md:133（dsh 自述的 scrub 定义：
//      「ambient names matching /KEY|PASSWORD|SECRET|TOKEN/i and ambient
//      DSH_* names are dropped — and the configured env merges on top, so
//      explicit overrides survive」）；
//    · packages/e2b/subprocess-e2b/src/environment.ts:65/:79（源码级消费
//      实证：`name.startsWith('DSH_') || SENSITIVE_ENV_PATTERN.test(name)`
//      两条规则、前缀为字面 'DSH_'、pattern 为带 .test 的 RegExp）；
//    · docs/subsystems/subprocess.md:5/:15（seam 拥有 managed DSH_* 命名
//      空间与共享 credential scrub；ambient DSH_* 在显式 env 合并前丢弃）；
//    · packages/mcp/mcp-client/src/transport.ts:21-23（消费形态：
//      buildChildEnv = { ...scrubbedParentEnv(), ...extra }——scrub 只清
//      ambient，显式覆盖在合并侧保留，本件不交付合并）。
//  WanWo 形态（呈报逐项见 project 汇报）：
//    ①纯函数入参化——dsh scrubbedParentEnv() 无参读 process.env，WanWo
//      无全局 process.env 形态且单测需注入父环境（件12 锚点），父环境作
//      参数；ProcessInfo 取样归调用侧（M4-B stdio 接线，红线 R6）。
//    ②前缀适配 DSH_* → WANWO_*（简报已批的平台适配）。
//    ③落点 WanWo/MCP/（本批消费面=MCP stdio）；dsh 本体属 subprocess
//      seam、dsh-shell re-export 共享——shell 消费出现时上移 ISHRuntime。
//  单测锚点（件12 断言，简报指定）：KEY/PASSWORD/SECRET/TOKEN 大小写混合
//  变体擦除、WANWO_ 前缀全删、正常变量保留、显式覆盖保留（合并侧语义）。
//

import Foundation

/// dsh 子进程缝共享清洗（scrubbedParentEnv + SENSITIVE_ENV_PATTERN）的
/// Swift 纯函数形态。擦除=两条独立规则（e2b environment.ts:65 消费实证）：
///   1. 名称含 /KEY|PASSWORD|SECRET|TOKEN/i 子串（regex 无词边界——
///      MONKEY/tokenize 等过擦属 dsh fail-closed 设计语义，1:1 保留）；
///   2. 名称以管理命名空间前缀开头（dsh 'DSH_' → WanWo 'WANWO_'）。
/// 显式覆盖保留=调用侧合并语义（transport.ts:22 extra 在基座之上），
/// 本函数只清 ambient、不做合并。
enum MCPEnvScrub {

    /// 管理环境命名空间前缀（dsh DSH_ENV_PREFIX/'DSH_' 字面，e2b :65 实证；
    /// 平台适配 WANWO_——简报已批）。
    static let managedNamespacePrefix = "WANWO_"

    /// SENSITIVE_ENV_PATTERN（README:133 `/KEY|PASSWORD|SECRET|TOKEN/i`）：
    /// 预编译，firstMatch=无锚点子串搜索（=RegExp.test 语义）。模式为
    /// 编译期字面常量，try! 失败即程序员错误（fail loud 纪律）。
    static let sensitivePattern = try! NSRegularExpression(
        pattern: "KEY|PASSWORD|SECRET|TOKEN",
        options: [.caseInsensitive])

    /// 规则 1：名称含敏感子串（无词边界，大小写不敏感）。
    static func isSensitiveEnvName(_ name: String) -> Bool {
        let full = NSRange(name.startIndex..., in: name)
        return sensitivePattern.firstMatch(in: name, range: full) != nil
    }

    /// 两规则合并判定（e2b :65 `startsWith('DSH_') || pattern.test(name)`
    /// 的跳过谓词 1:1；WanWo 前缀=managedNamespacePrefix）。
    static func isScrubbed(_ name: String) -> Bool {
        name.hasPrefix(managedNamespacePrefix) || isSensitiveEnvName(name)
    }

    /// dsh scrubbedParentEnv() 的 WanWo 形态（呈报①：父环境入参化）。
    /// 返回擦除后的 ambient 基座——调用侧在其上合并显式 env（保留语义在
    /// 合并侧，transport.ts:21-23 形态；本件不交付合并）。
    static func scrubbedParentEnv(_ parent: [String: String]) -> [String: String] {
        parent.filter { name, _ in !isScrubbed(name) }
    }
}
