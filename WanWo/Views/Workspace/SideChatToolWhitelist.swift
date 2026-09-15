//
//  SideChatToolWhitelist.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 10-design §5.8 / m6-scope-brief §6.2】
//  侧边聊天工具层硬白名单（M9.7 既有设计提前落位——较 codex 提示词软约束更强）：
//    · 白名单外工具不可见（注册表 unregister——模型 schema 不再暴露）；
//    · preExecute fail closed 复核：registry guard 单调否定兜住后注册
//      （MCP 异步激活等晚到工具）与 run_code SDK 子派发等一切旁路——
//      白名单外一律 DENIED_BY_GUARD 合成错误，无放行路径。
//  白名单 = 只读面：fs 读四件 + web 读两件。写类（bash/write/edit/
//  str_replace_editor/browser_use/jobs/技能/计划出口/提问/PTC）一概不可用。
//

import Foundation

enum SideChatToolWhitelist {

    /// 只读白名单（WanWo 既有工具名的封闭集合）。
    static let allowed: Set<String> = [
        "read", "glob", "grep", "read_image",
        "web_search", "web_fetch",
    ]

    /// 写类/副作用类工具名集（白名单矩阵单测的必测反面——本批安全语义面）。
    /// 注：run_code（保留 transport）、MCP 动态工具名不在静态集中——guard
    /// 语义为「不在白名单即拒」，反面矩阵覆盖静态集即可保证 fail closed。
    static let writeClass: Set<String> = [
        "bash", "write", "edit", "str_replace_editor",
        "browser_use", "job_output", "job_list", "job_kill",
        "skill", "exit_plan_mode", "ask_user_question", "run_code",
    ]

    /// guard 拒绝理由（白名单外统一文案；dsh ToolGuard 单调否定词汇）。
    static func guardReason(name: String) -> String? {
        if allowed.contains(name) { return nil }
        return "侧边聊天为只读探索会话：工具 \"\(name)\" 不可用"
            + "（写类操作在侧边聊天中不可见且被拒绝；如需变更请回到主对话）。"
    }

    /// 应用白名单到注册表：注销白名单外全部已知工具 + 挂 fail closed guard。
    /// （注销即时收窄模型可见面；guard 兜住晚到注册与子派发旁路。）
    static func apply(to registry: ToolRegistry) {
        for name in registry.knownNames where !allowed.contains(name) {
            registry.unregister(name)
        }
        registry.addGuard { name, _ in guardReason(name: name) }
    }
}
