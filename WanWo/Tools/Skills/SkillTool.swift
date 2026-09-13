//
//  SkillTool.swift
//  WanWo
//
//  【M4-D 件 D5 · F030 skill 工具（渐进二级）】语义移植 · dsh 契约：
//  skills.md:235（`skill({name})` 全契约）+:194（重读正文不缓存，正文改动
//  即时生效）。codex 锚点：render.rs:19 MAX_SKILL_PROMPT_BYTES=8_000 +
//  :1180-1183 truncate_utf8_to_bytes（char boundary 截断）；extension.rs:472
//  截断告警文案逐字；catalog_prompt.rs :24-40 守则段落（host-aliases 变体
//  最小适配——WanWo 全本地无 alias 机制，见头注登记）。
//
//  契约顺序（lead 派单 1:1）：name 非空+kebab 校验 → snapshot 查 summary
//  （invocation-neutral 含 user-only）→ 未找到="unknown or no longer available"
//  → isModelInvocable 门（先于加载）→ 重读正文（不缓存）→ invocation 复检
//  （重读间隙技能可能被改——快照复检防 TOCTOU）→ 三段返回
//  `<skill_content>`/`<skill_resources>`/`<skill_instructions>`。
//
//  简化授权登记（lead 给授权）：①资源段=目录路径+read 自取引导文本，
//  不枚举文件清单；②守则段=codex catalog_prompt.rs host-aliases 守则的
//  最小适配（去掉 alias 展开子句、补"截断续读"与正文已装载语境；Missing/
//  blocked 段不收——unknown/不可调用已在工具面确定性拒绝）；③8KB=8000 字节
//  （codex 常量逐字，非 8192）。
//
//  R2：工具调用=tool/call+tool/result 既有对 ✓；R4：presentCall/Result 默认
//  nil（M9 对齐）✓。exposure=.direct（内置元工具恒 direct，mcp_server_config
//  死锁防线同源）。
//

import Foundation

struct SkillTool: AgentTool {
    let name = "skill"
    let description = "Load a skill's full instructions by name. Use it when the user "
        + "explicitly names a skill (e.g. $name) or when the task clearly matches a skill "
        + "listed in the available skills catalog. The body is re-read on every call."

    let parameters: JSONValue = .schemaObject(
        properties: [
            "name": .stringSchema(
                description: "The skill name (kebab-case), exactly as listed in "
                    + "<available_skills>."),
        ],
        required: ["name"])

    /// 构造注入（ToolSearchTool corpusProvider 同款模式；internal 供测试 @testable 直达）。
    let registry: SkillRegistry

    /// codex render.rs:19 逐字（8KB=8000 字节）。
    static let maxSkillPromptBytes = 8_000

    /// codex extension.rs:472 截断告警文案逐字（[warning] 前缀=WanWo 文内标记）。
    static let truncationWarningPrefix = "[warning] Skill `"
    static let truncationWarningSuffix = "` exceeded the main prompt context limit and was truncated."

    init(registry: SkillRegistry) {
        self.registry = registry
    }

    /// 纯读取无共享可变态（正文每次重读，dsh:194）——显式 parallel。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // ① name 非空。
        guard let name = args.objectValue?["name"]?.stringValue?
            .trimmingCharacters(in: .whitespaces),
            !name.isEmpty else {
            return .failure("missing required parameter \"name\"", code: "INVALID_ARGS")
        }
        // ② kebab 校验（skills.md:85 契约的工具入口面；D1/D2 明确不加、D5 承接）。
        guard SkillRegistry.isKebabCase(name) else {
            return .failure("invalid skill name \"\(name)\": must match "
                + "^[a-z0-9]+(?:-[a-z0-9]+)*$ (kebab-case)", code: "INVALID_SKILL_NAME")
        }
        // ③ snapshot 查找（invocation-neutral：含 user-only 技能——门在后）。
        guard let summary = registry.snapshot().summaries
            .first(where: { $0.name == name }) else {
            return .failure("skill \"\(name)\" is unknown or no longer available.",
                            code: "SKILL_NOT_FOUND")
        }
        // ④ isModelInvocable 门（先于加载——user-only 技能明确拒绝）。
        guard summary.invocation.modelInvocable else {
            return .failure("skill \"\(name)\" is not model-invocable "
                + "(disable-model-invocation is set); it can only be triggered "
                + "explicitly by the user.", code: "SKILL_NOT_MODEL_INVOCABLE")
        }
        // ⑤ 重读正文（不缓存——dsh:194：正文改动即时生效）。
        guard let contents = try? String(contentsOf: URL(fileURLWithPath: summary.bodyPath),
                                         encoding: .utf8) else {
            return .failure("failed to read skill \"\(name)\" body at \(summary.bodyPath).",
                            code: "SKILL_BODY_READ_FAILED")
        }
        // ⑥ invocation 复检（重读间隙技能可能被改/移除——快照复检防 TOCTOU）。
        guard let rechecked = registry.snapshot().summaries
            .first(where: { $0.name == name }),
            rechecked.invocation.modelInvocable,
            rechecked.bodyPath == summary.bodyPath else {
            return .failure("skill \"\(name)\" changed while loading; retry the call.",
                            code: "SKILL_CHANGED")
        }
        // ⑦ 8KB 截断（char boundary）+ 文内告警标记。
        let (body, truncated) = Self.truncateToBytes(contents, maxBytes: Self.maxSkillPromptBytes)
        var contentSection = body
        if truncated {
            contentSection += "\n\n" + Self.truncationWarningPrefix + name
                + Self.truncationWarningSuffix
        }

        let text = "<skill_content name=\"\(name)\">\n\(contentSection)\n</skill_content>\n"
            + "<skill_resources>\n\(Self.resourcesGuidance(for: summary))\n</skill_resources>\n"
            + "<skill_instructions>\n\(Self.usageInstructions)\n</skill_instructions>"
        return .success(text)
    }

    // MARK: - 三段辅助

    /// 资源引导段（简化授权：目录路径+read 自取，不枚举清单）。
    static func resourcesGuidance(for summary: SkillSummary) -> String {
        "The skill directory is \(summary.resourceBase). Files referenced by the skill "
            + "body (scripts/, references/, assets/) live next to its SKILL.md file; read "
            + "them with the `read` tool using paths under this directory."
    }

    /// 守则段（codex catalog_prompt.rs :24-40 host-aliases 变体最小适配，见头注）。
    static let usageInstructions = """
        - Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown in the skills catalog, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
        - How to use a skill (progressive disclosure):
          1) The skill body above is the skill's `SKILL.md`: read it completely before taking task actions. If it was truncated, read the remainder from the file before acting.
          2) When the body references relative paths (e.g., `scripts/foo.py`), resolve them relative to the skill directory given in `<skill_resources>` first, and only consider other paths if needed.
          3) If the body points to extra folders such as `references/`, use its routing instructions to identify the files required for the task. The main agent must read each required instruction or reference file itself before acting on it. Do not delegate reading, summarizing, or interpreting skill instructions to a subagent. Subagents may still perform task work when the selected skill allows it.
          4) If `scripts/` exist, prefer running or patching them instead of retyping large code blocks.
          5) If `assets/` or templates exist, reuse them instead of recreating from scratch.
        - Coordination and sequencing:
          - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.
          - Announce which skill(s) you're using and why (one short line). If you skip an obvious skill, say why.
        - Context hygiene:
          - Progressive disclosure applies to selecting relevant files, not partially reading a selected instruction file. Do not load unrelated references, scripts, or assets.
          - Avoid deep reference-chasing: prefer opening only files directly linked from the body unless you're blocked.
          - When variants exist (frameworks, providers, domains), pick only the relevant reference file(s) and note that choice.
        - Safety and fallback: If a skill can't be applied cleanly (missing files, unclear instructions), state the issue, pick the next-best approach, and continue.
        """

    // MARK: - 截断（codex render.rs:1180-1183 等价：char boundary 安全）

    /// UTF-8 字节截断，回落至 Character 边界；返回 (内容, 是否截断)。
    static func truncateToBytes(_ contents: String, maxBytes: Int) -> (String, Bool) {
        let utf8 = Array(contents.utf8)
        guard utf8.count > maxBytes, maxBytes > 0 else { return (contents, false) }
        var cut = maxBytes
        // 回退跨界的 UTF-8 续字节（0b10xxxxxx）至字符起始字节。
        while cut > 0 && (utf8[cut] & 0xC0) == 0x80 { cut -= 1 }
        return (String(decoding: utf8[0..<cut], as: UTF8.self), true)
    }
}
