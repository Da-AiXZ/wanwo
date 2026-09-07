//
//  PromptSections.swift
//  WanWo
//
//  【语义移植 · dsh · ERR-025③】system prompt 内容注册（M2.2 完整性补齐）。
//  出处（逐字移植，仅改 Swift 字符串字面量语法）：
//    - packages/fs/tool-fs/src/read.ts    → section "tool:read"
//    - packages/fs/tool-fs/src/write.ts   → section "tool:write"
//    - packages/fs/tool-fs/src/edit.ts    → section "tool:edit"
//    - packages/fs/tool-fs-search/src/glob.ts → section "tool:glob"
//      （over-cap 文案取 non-sampling 变体 "keeps the modification-time-ordered
//      head"，与 WanWo FsGlobTool 超限行为一致：保 mtime 头部、不跨顶层抽样）
//    - packages/fs/tool-fs-search/src/grep.ts → section "tool:grep"
//    - packages/context/file-reference/src/index.ts → section
//      "context:file-reference"（FILE_REFERENCE_PROMPT 逐字；dsh 注册条件
//      为 read 工具存在——M2 恒注册 read，故无条件注册）
//  布局位经 PromptAssembler.SECTION_ORDERS（dsh SECTION_ORDERS 数值 1:1）。
//
//  【dsh 环境特有段落——未移植，列单报批（ERR-025 派单方式）】：
//    1. harness:identity（"You are an AI agent powered by DeepSeek Harness."）
//       ——声明宿主身份；WanWo 是否沿用 DeepSeek Harness 名称需拍板。
//    2. harness:source（dsh checkout 路径说明）——dsh 开发环境特有，iOS 无意义。
//    3. app:web-surface（dsh Web GUI 本地 URL）——dsh web 壳特有。
//    4. deployment:persona（order 0，部署方 config.persona 提供）——M2 无部署
//       persona 配置源；空段落本来就被组装器丢弃。
//    5. tool:bash / tool:pwsh（SECTION_ORDERS 1000/1010）——dsh OSS 快照只保留
//       布局位，无公开 section 文本（闭源部署插件）；WanWo 有 ShellTool(bash)，
//       需自拟文案，待批准后补注册。
//    6. tool:web-search / tool:web-fetch（2000/2100）——同上，dsh 无公开文本；
//       WanWo WebTools 已有 schema description，section 待批准后自拟。
//    7. WanWo 本地新增工具 read_image / str_replace_editor——dsh 无对应物，
//       无可移植文本；是否为其写 section 待拍板。
//    8. plan:policy / team:policy / ptc-only / tools-sdk /
//       deliverable-file-references / structured-output——dsh 子系统 sections，
//       对应子系统不在 M0-M2 范围（plan/team/PTC/SDK/结构化输出均未排期）。
//    9. CONTEXT_ORDERS 动态上下文位：sandbox-policy(110) / approval-policy(115) /
//       subagent-delegation(120)——M2 为 AutoApprovalSeam 占位、无沙箱与
//       子代理，均无内容可注入（快照对应位为空）。
//   10. time（dsh packages/context/time-context）——opt-in 独立注入通道（非快照
//       组成项），M2 不移植；快照自此无时间戳（ERR-025① 缓存断点嫌疑消除）。
//

import Foundation

/// system prompt 静态段落注册表（ERR-025③：dsh 工具 sections 逐字移植）。
/// 装配点：AppEnvironment.makeAgentStack（每个 agent 栈注册一次；
/// PromptAssembler 对重名注册 fatalError，故不得重复调用）。
enum PromptSections {

    // MARK: - 逐字文本（dsh 源码原句）

    /// dsh tool-fs read.ts —— "tool:read"。
    static let toolRead = "Use the read tool — not shell commands like cat — to inspect text files. "
        + "Results include line numbers. Use offset and limit to continue reading large files."

    /// dsh tool-fs write.ts —— "tool:write"。
    static let toolWrite = "Use the write tool to create files or completely replace file contents. "
        + "Existing files are overwritten, so read an existing file first "
        + "(the default fs-observation-policy requires it) and prefer edit for targeted changes."

    /// dsh tool-fs edit.ts —— "tool:edit"。
    static let toolEdit = "Use the edit tool for targeted changes to existing UTF-8 text files. "
        + "It replaces literal old_string with new_string; by default old_string must appear exactly once. "
        + "If old_string appears multiple times, provide a more specific old_string or set replace_all to true. "
        + "Read the file first (the default fs-observation-policy requires it), "
        + "unless you just created or edited it in this session."

    /// dsh tool-fs-search glob.ts —— "tool:glob"（over-cap 非 sampling 变体，
    /// 与 FsGlobTool 的 mtime 头部截断行为一致）。
    static let toolGlob = "Use the glob tool — not shell find — to discover files by path pattern. "
        + "A pattern with no \"/\" matches basenames at any depth, so \"*\" matches every file in the tree "
        + "rather than its top level. "
        + "Results are files only, never directories, and include hidden and ignored files: "
        + "a result that fits comes back in modification-time order, "
        + "while a larger one keeps the modification-time-ordered head."

    /// dsh tool-fs-search grep.ts —— "tool:grep"。
    static let toolGrep = "Use the grep tool — not shell grep or rg — to search file contents. "
        + "Use read on a matched file when you need surrounding context."

    /// dsh context/file-reference index.ts —— FILE_REFERENCE_PROMPT
    /// （"context:file-reference"；@file 注入的模型侧指引，F040 配套）。
    static let fileReference = "Tokens prefixed with @ are workspace paths the user explicitly referenced, "
        + "relative to the workspace root. A trailing slash marks a directory: list it when its contents matter. "
        + "Anything else is a file: use the read tool when its contents are needed, "
        + "and do not claim to have inspected it before reading. "
        + "@\"...\" quotes a path containing spaces."

    // MARK: - 注册

    /// 把 M2 范围内的 dsh 逐字段落注册进组装器。
    /// 顺序由 SECTION_ORDERS 决定（file-reference 900 → read 1000 后的
    /// 1100/1200/1300/1400/1500），与 dsh 段落布局一致。
    static func registerAll(into assembler: PromptAssembler) {
        assembler.section(PromptSection(
            name: "context:file-reference",
            order: SECTION_ORDERS.fileReference,
            text: fileReference))
        assembler.section(PromptSection(
            name: "tool:read",
            order: SECTION_ORDERS.toolRead,
            text: toolRead))
        assembler.section(PromptSection(
            name: "tool:write",
            order: SECTION_ORDERS.toolWrite,
            text: toolWrite))
        assembler.section(PromptSection(
            name: "tool:edit",
            order: SECTION_ORDERS.toolEdit,
            text: toolEdit))
        assembler.section(PromptSection(
            name: "tool:glob",
            order: SECTION_ORDERS.toolGlob,
            text: toolGlob))
        assembler.section(PromptSection(
            name: "tool:grep",
            order: SECTION_ORDERS.toolGrep,
            text: toolGrep))
    }
}
