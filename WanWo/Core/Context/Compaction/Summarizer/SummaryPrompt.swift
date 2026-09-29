//
//  SummaryPrompt.swift
//  WanWo
//
//  【逐字移植 · M8 批2 件B2】出处（逐字保文，禁意译——平台适配登记：
//  j2/Pydantic 模板 → Swift 字符串常量）：
//    - system prompt：claudecode §1.5 system-compact.prompt.md 逐字全文
//    - NO_TOOLS_PREAMBLE：claudecode §②b 新版原文，开头/结尾双声明（dual-instruction
//      pattern，oldeucryptoboi 源码级证据）
//    - <analysis> 草稿阶段指令：claudecode §1.3 逐字
//    - 9 板块填写指令：claudecode §1.4 逐字（字段名换 11 字段对应——括注目标字段；
//      另追加 10/11 两条万我增强/合并来源板块，登记见 b2-report.md §三）
//    - 收尾指令：claudecode §1.5 首句逐字（其后的 Additional Instructions 示例块
//      为 CC 自定义摘要指令注入机制，万我未实现该机制，不移植——登记）
//    - 增量折叠拼接 + Conversation 段：Cline buildSummaryRequest（agentic-compaction.ts:
//      669-703）"Previous summary:" 段语义（:139-151），防摘要的摘要漂移
//

import Foundation

enum SummaryPrompt {
    // MARK: system（claudecode §1.5 逐字全文）

    static let systemPrompt = "You are a helpful AI assistant tasked with summarizing conversations."

    // MARK: NO_TOOLS_PREAMBLE（claudecode §②b 逐字，首尾双声明）

    static let noToolsPreamble = """
    CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.
    - Do NOT use Read, Bash, Grep, Glob, Edit, Write, or ANY other tool.
    - You already have all the context you need in the conversation above.
    - Tool calls will be REJECTED and will waste your only turn — you will fail the task.
    - Your entire response must be plain text: an <analysis> block followed by a <summary> block.
    """

    // MARK: <analysis> 草稿阶段指令（claudecode §1.3 逐字）

    static let analysisInstructions = """
    Before providing your final summary, wrap your analysis in <analysis> tags to organize your thoughts and ensure you've covered all necessary points. In your analysis process:

    1. Chronologically analyze each message and section of the conversation. For each section thoroughly identify:
       - The user's explicit requests and intents
       - Your approach to addressing the user's requests
       - Key decisions, technical concepts and code patterns
       - Specific details like:
         - file names
         - full code snippets
         - function signatures
         - file edits
       - Errors that you ran into and how you fixed them
       - Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.

    2. Double-check for technical accuracy and completeness, addressing each required element thoroughly.
    """

    // MARK: 板块填写指令（claudecode §1.4 逐字 + 字段对应括注；10/11 为万我增强/合并板块）

    static let sectionInstructions = """
    1. Primary Request and Intent (user_intent): Capture all of the user's explicit requests and intents in detail
    2. Key Technical Concepts (tech_context): List all important technical concepts, technologies, and frameworks discussed.
    3. Files and Code Sections (files_and_code): Enumerate specific files and code sections examined, modified, or created. Pay special attention to the most recent messages and include full code snippets where applicable and include a summary of why this file read or edit is important.
    4. Errors and fixes (errors_and_fixes): List all errors that you ran into, and how you fixed them. Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
    5. Problem Solving (problem_solving): Document problems solved and any ongoing troubleshooting efforts.
    6. All user messages (user_messages): List ALL user messages that are not tool results. These are critical for understanding the users' feedback and changing intent. Reproduce every message verbatim, without summarizing, paraphrasing, or omitting any.
    7. Pending Tasks (pending_tasks): Outline any pending tasks that you have explicitly been asked to work on.
    8. Current Work (current_work): Describe in detail precisely what was being worked on immediately before this summary request, paying special attention to the most recent messages from both user and assistant. Include file names and code snippets where applicable.
    9. Optional Next Step (next_step): List the next step that you will take that is related to the most recent work you were doing. IMPORTANT: ensure that this step is DIRECTLY in line with the user's explicit requests, and the task you were working on immediately before this summary request. If your last task was concluded, then only list next steps if they are explicitly in line with the users request. Do not start on tangential requests without confirming with the user first.
       If there is a next step, include direct quotes from the most recent conversation showing exactly what task you were working on and where you left off. This should be verbatim to ensure there's no drift in task interpretation.
    10. Security Constraints (security_constraints): Preserve any security, privacy, permission, or other critical constraints stated during the conversation VERBATIM, in their full original wording. Leave empty if none were stated.
    11. Other Context (other_context): Any other important information that doesn't fit into the categories above.
    """

    // MARK: 收尾指令（claudecode §1.5 首句逐字）

    static let closingInstruction =
        "Please provide your summary based on the conversation so far, following this structure "
        + "and ensuring precision and thoroughness in your response."

    // MARK: user prompt 组装

    /// 组装摘要请求 user prompt：
    /// NO_TOOLS_PREAMBLE（首）→ analysis 指令 → 板块指令 → 收尾指令 → NO_TOOLS_PREAMBLE（尾）
    /// → [增量折叠] Previous summary 段（Cline :139-151 语义）→ Conversation 段
    /// （Cline buildSummaryRequest :669-703 语义，空序列化 = "(empty)"）。
    static func userPrompt(previousSummary: String?, serializedEvents: [String]) -> String {
        var parts: [String] = [
            noToolsPreamble,
            analysisInstructions,
            sectionInstructions,
            closingInstruction,
            noToolsPreamble,
        ]
        if let previousSummary, !previousSummary.isEmpty {
            parts.append("Previous summary:\n\(previousSummary)")
        }
        let conversation = serializedEvents.isEmpty
            ? "(empty)"
            : serializedEvents.joined(separator: "\n\n")
        parts.append("Conversation:\n\(conversation)")
        return parts.joined(separator: "\n\n")
    }
}
