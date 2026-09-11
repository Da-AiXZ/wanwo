//
//  MCPEnvScrub.swift
//  WanWo
//
//  【M4-A 件7 · 凭据擦除 scrub】dsh 子进程缝共享清洗词汇。定义本体=上游
//  原文（呈报①裁决：lead 自 GitHub 上游 deepseek-ai/deepseek-harness @
//  master 补齐，存档 analysis/dsh-subprocess-refs/index.ts = packages/
//  subprocess/subprocess/src/index.ts）：
//    · index.ts:56 SENSITIVE_ENV_PATTERN = /KEY|PASSWORD|SECRET|TOKEN/i
//      （无锚点子串）；
//    · index.ts:75-89 scrubbedParentEnv：value !== undefined &&
//      !PATTERN.test(key) && !key.toUpperCase().startsWith(DSH_ENV_PREFIX)
//      ——**前缀比对先转大写**（:64-67 注释：Windows 环境名大小写不敏感，
//      否则父进程 dsh_* 小写键幸存并在子进程读回 $env:DSH_*；POSIX 上
//      刻意的小写 dsh_* 命名不可信）；
//    · index.ts:84-87 proxyEnvironmentForChild() overlay（宿主代理归一化
//      还原）——WanWo 无宿主代理机制，属平台侧机制非凭据擦除语义，不移植
//      （平台差异登记；将来 WanWo 做代理功能需补此位）。
//  消费形态旁证：mcp-client/transport.ts:21-23 buildChildEnv =
//  { ...scrubbedParentEnv(), ...extra }——scrub 只清 ambient，显式覆盖在
//  合并侧保留，本件不交付合并。
//  WanWo 形态（呈报逐项见 project 汇报）：
//    ①纯函数入参化——dsh scrubbedParentEnv() 无参读 process.env，WanWo
//      无全局 process.env 形态且单测需注入父环境（件12 锚点），父环境作
//      参数；ProcessInfo 取样归调用侧（M4-B stdio 接线，红线 R6）。
//    ②前缀适配 DSH_* → WANWO_*（简报已批的平台适配）。
//    ③落点 WanWo/MCP/（本批消费面=MCP stdio）；dsh 本体属 subprocess
//      seam、dsh-shell re-export 共享——shell 消费出现时上移 ISHRuntime。
//  单测锚点（件12 断言，简报指定+lead 件7 review 补充）：KEY/PASSWORD/
//  SECRET/TOKEN 大小写混合变体擦除、WANWO_ 前缀全删（含 `wanwo_test` 小写
//  变体必须被擦——大小写不敏感前缀比对锚点）、正常变量保留、显式覆盖保留
//  （合并侧语义）。
//

import Foundation

/// dsh 子进程缝共享清洗（scrubbedParentEnv + SENSITIVE_ENV_PATTERN）的
/// Swift 纯函数形态。擦除=两条独立规则（上游 index.ts:78 循环体 1:1）：
///   1. 名称含 /KEY|PASSWORD|SECRET|TOKEN/i 子串（regex 无词边界——
///      MONKEY/tokenize 等过擦属 dsh fail-closed 设计语义，1:1 保留）；
///   2. 名称以管理命名空间前缀开头——**大小写不敏感**（dsh 先
///      toUpperCase 再比前缀；WanWo 上游注语义同款：WanWo 无 Windows 宿主
///      形态差异，但 iOS 宿主进程环境可含任意来源键，按原文全等保留大小写
///      不敏感语义）。
/// 显式覆盖保留=调用侧合并语义（transport.ts:22 extra 在基座之上），
/// 本函数只清 ambient、不做合并；proxy overlay 不移植（头注登记）。
enum MCPEnvScrub {

    /// 管理环境命名空间前缀（dsh DSH_ENV_PREFIX，types.ts 定义、e2b 消费
    /// 实证为字面 'DSH_'；平台适配 WANWO_——简报已批）。比对恒作用于
    /// uppercased 键（见 isScrubbed）。
    static let managedNamespacePrefix = "WANWO_"

    /// SENSITIVE_ENV_PATTERN（上游 index.ts:56 `/KEY|PASSWORD|SECRET|TOKEN/i`）：
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

    /// 两规则合并判定（上游 index.ts:78 保留谓词 1:1：!test(key) &&
    /// !key.toUpperCase().startsWith(PREFIX)；WanWo 前缀=managedNamespace-
    /// Prefix，前缀比对大小写不敏感=先 uppercased）。
    static func isScrubbed(_ name: String) -> Bool {
        name.uppercased().hasPrefix(managedNamespacePrefix) || isSensitiveEnvName(name)
    }

    /// dsh scrubbedParentEnv() 的 WanWo 形态（呈报①：父环境入参化）。
    /// 返回擦除后的 ambient 基座——调用侧在其上合并显式 env（保留语义在
    /// 合并侧，transport.ts:21-23 形态；本件不交付合并）。
    static func scrubbedParentEnv(_ parent: [String: String]) -> [String: String] {
        parent.filter { name, _ in !isScrubbed(name) }
    }
}
