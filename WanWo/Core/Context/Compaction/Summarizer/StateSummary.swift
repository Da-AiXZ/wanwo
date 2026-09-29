//
//  StateSummary.swift
//  WanWo
//
//  【语义移植 · M8 批2 件B2】出处：
//    - OpenHands structured_summary_condenser.py（0.44.0）:24-99 StateSummary Pydantic 模型
//      → Swift Codable（平台适配登记：Pydantic → Swift Codable，b2-report.md §六）
//    - :101-126 StateSummary.tool_description() → tool schema（每字段 {type:"string",description}，
//      工具名 create_state_summary，required=[user_intent, pending_tasks, current_work]——
//      对拍 OpenHands 必填三件 user_context/completed_tasks/pending_tasks 语义 + 万我字段表）
//    - :128-158 __str__ Markdown 渲染（分组标题语义：# State Summary / ## Core Information /
//      ## Code Changes / ## Additional Context 逐字；Optional Next Step 取 Claude Code ⑨板块题；
//      Security Constraints 为万我增强组）
//    - 11 字段表 = context-upgrade-brief.md §三（用户拍板：Claude Code 9 板块 × OpenHands 结构化结合；
//      user_messages/next_step 自由文本、security_constraints 万我增强 verbatim）
//  字段 description 逐字来源：①-⑨ = claudecode-compact-template-verify.md §1.4 原文；
//  user_messages 追加万我 verbatim 升级（brief 决策点②：升级须明写，CC 原文无此要求）；
//  other_context = OpenHands 第 18 字段 description 原文。
//

import Foundation

/// 结合摘要 11 字段（全 String，缺省 ""——对拍 OpenHands `default ''`）。
struct StateSummary: Codable, Equatable, Sendable {
    var userIntent: String
    var techContext: String
    var filesAndCode: String
    var errorsAndFixes: String
    var problemSolving: String
    var userMessages: String
    var pendingTasks: String
    var currentWork: String
    var nextStep: String
    var securityConstraints: String
    var otherContext: String

    init(userIntent: String = "", techContext: String = "", filesAndCode: String = "",
         errorsAndFixes: String = "", problemSolving: String = "", userMessages: String = "",
         pendingTasks: String = "", currentWork: String = "", nextStep: String = "",
         securityConstraints: String = "", otherContext: String = "") {
        self.userIntent = userIntent
        self.techContext = techContext
        self.filesAndCode = filesAndCode
        self.errorsAndFixes = errorsAndFixes
        self.problemSolving = problemSolving
        self.userMessages = userMessages
        self.pendingTasks = pendingTasks
        self.currentWork = currentWork
        self.nextStep = nextStep
        self.securityConstraints = securityConstraints
        self.otherContext = otherContext
    }

    /// 缺省 "" 解码（OpenHands `default ''` 语义：模型漏字段不炸解码，空值走渲染/兜底链）。
    private enum Keys: String, CodingKey {
        case userIntent = "user_intent"
        case techContext = "tech_context"
        case filesAndCode = "files_and_code"
        case errorsAndFixes = "errors_and_fixes"
        case problemSolving = "problem_solving"
        case userMessages = "user_messages"
        case pendingTasks = "pending_tasks"
        case currentWork = "current_work"
        case nextStep = "next_step"
        case securityConstraints = "security_constraints"
        case otherContext = "other_context"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        userIntent = try c.decodeIfPresent(String.self, forKey: .userIntent) ?? ""
        techContext = try c.decodeIfPresent(String.self, forKey: .techContext) ?? ""
        filesAndCode = try c.decodeIfPresent(String.self, forKey: .filesAndCode) ?? ""
        errorsAndFixes = try c.decodeIfPresent(String.self, forKey: .errorsAndFixes) ?? ""
        problemSolving = try c.decodeIfPresent(String.self, forKey: .problemSolving) ?? ""
        userMessages = try c.decodeIfPresent(String.self, forKey: .userMessages) ?? ""
        pendingTasks = try c.decodeIfPresent(String.self, forKey: .pendingTasks) ?? ""
        currentWork = try c.decodeIfPresent(String.self, forKey: .currentWork) ?? ""
        nextStep = try c.decodeIfPresent(String.self, forKey: .nextStep) ?? ""
        securityConstraints = try c.decodeIfPresent(String.self, forKey: .securityConstraints) ?? ""
        otherContext = try c.decodeIfPresent(String.self, forKey: .otherContext) ?? ""
    }
}

// MARK: - 工具 schema（SSS:101-126 语义）

extension StateSummary {
    static let toolName = "create_state_summary"

    /// 必填三件（对拍 OpenHands required=[user_context, completed_tasks, pending_tasks]
    /// 语义 + 万我字段表映射：user_intent / pending_tasks / current_work）。
    static let requiredFields = ["user_intent", "pending_tasks", "current_work"]

    /// 工具 description（SSS:101-126 语义 + 万我 11 字段重述）。
    static let toolDescription =
        "Creates a comprehensive summary of the current state of the interaction to preserve "
        + "context when history grows too large. You must include non-empty values for "
        + "user_intent, pending_tasks, and current_work."

    /// 每字段 description（来源见文件头；顺序即字段表顺序）。
    static let fieldDescriptions: [(key: String, description: String)] = [
        ("user_intent",
         "Capture all of the user's explicit requests and intents in detail"),
        ("tech_context",
         "List all important technical concepts, technologies, and frameworks discussed."),
        ("files_and_code",
         "Enumerate specific files and code sections examined, modified, or created. Pay special "
         + "attention to the most recent messages and include full code snippets where applicable "
         + "and include a summary of why this file read or edit is important."),
        ("errors_and_fixes",
         "List all errors that you ran into, and how you fixed them. Pay special attention to "
         + "specific user feedback that you received, especially if the user told you to do "
         + "something differently."),
        ("problem_solving",
         "Document problems solved and any ongoing troubleshooting efforts."),
        ("user_messages",
         "List ALL user messages that are not tool results. These are critical for understanding "
         + "the users' feedback and changing intent. Reproduce every message verbatim, without "
         + "summarizing, paraphrasing, or omitting any."),
        ("pending_tasks",
         "Outline any pending tasks that you have explicitly been asked to work on."),
        ("current_work",
         "Describe in detail precisely what was being worked on immediately before this summary "
         + "request, paying special attention to the most recent messages from both user and "
         + "assistant. Include file names and code snippets where applicable."),
        ("next_step",
         "List the next step that you will take that is related to the most recent work you were "
         + "doing. IMPORTANT: ensure that this step is DIRECTLY in line with the user's explicit "
         + "requests, and the task you were working on immediately before this summary request. "
         + "If your last task was concluded, then only list next steps if they are explicitly in "
         + "line with the users request. Do not start on tangential requests without confirming "
         + "with the user first. If there is a next step, include direct quotes from the most "
         + "recent conversation showing exactly what task you were working on and where you left "
         + "off. This should be verbatim to ensure there's no drift in task interpretation."),
        ("security_constraints",
         "Preserve any security, privacy, permission, or other critical constraints stated during "
         + "the conversation VERBATIM, in their full original wording. Leave empty if none were "
         + "stated."),
        ("other_context",
         "Any other important information that doesn't fit into the categories above."),
    ]

    /// create_state_summary 工具 schema（每字段 {type:"string",description}；
    /// required = 必填三件；不写 additionalProperties——OpenHands tool_description 未见此键，不自创）。
    static func makeToolSchema() -> ToolSchemaEntry {
        var properties: [String: JSONValue] = [:]
        for field in fieldDescriptions {
            properties[field.key] = .object([
                "type": .string("string"),
                "description": .string(field.description),
            ])
        }
        let parameters = JSONValue.object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(requiredFields.map { .string($0) }),
        ])
        return ToolSchemaEntry(name: toolName, description: toolDescription, parameters: parameters)
    }
}

// MARK: - Markdown 渲染（SSS:128-158 __str__ 分组标题语义）

extension StateSummary {
    /// 渲染 Markdown。空字段跳过（OpenHands default '' 语义下空值无信息量；
    /// files_and_code 的空值由 StructuredSummarizer 先走 Files 兜底再渲染）。
    /// 分组映射（登记见 b2-report.md §三）：Core Information / Code Changes /
    /// Additional Context 逐字取自 __str__；Optional Next Step 取 CC ⑨板块题；
    /// Security Constraints 为万我增强组。
    func renderMarkdown() -> String {
        var lines: [String] = ["# State Summary"]
        let groups: [(title: String, fields: [(name: String, value: String)])] = [
            ("Core Information", [
                ("user_intent", userIntent),
                ("tech_context", techContext),
                ("user_messages", userMessages),
                ("pending_tasks", pendingTasks),
                ("current_work", currentWork),
            ]),
            ("Code Changes", [
                ("files_and_code", filesAndCode),
                ("errors_and_fixes", errorsAndFixes),
                ("problem_solving", problemSolving),
            ]),
            ("Optional Next Step", [("next_step", nextStep)]),
            ("Security Constraints", [("security_constraints", securityConstraints)]),
            ("Additional Context", [("other_context", otherContext)]),
        ]
        for group in groups {
            let filled = group.fields.filter { !$0.value.isEmpty }
            guard !filled.isEmpty else { continue }
            lines.append("")
            lines.append("## \(group.title)")
            for field in filled {
                lines.append("")
                lines.append("### \(field.name)")
                lines.append(field.value)
            }
        }
        return lines.joined(separator: "\n")
    }
}
