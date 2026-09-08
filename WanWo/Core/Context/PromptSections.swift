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
//  【自拟段落批次 · 用户批准稿（2026，analysis/draft-sections.md 逐字）】：
//    - harness:identity（WanWo 版，order -1000）——dsh 原文一句
//      "You are an AI agent powered by DeepSeek Harness." 替换为 WanWo
//      宿主身份 + 运行环境说明（iPad 原生 + 内嵌 Alpine Linux 沙箱 iSH），
//      是模型区分 bash（guest 内执行）与 fs 工具（宿主 workspace 直读）语义
//      分野的前提。
//    - tool:bash（order 1000）——dsh OSS 快照仅有布局位无文本；纯自拟，
//      逐条对拍 ShellTool 实际行为（busybox ash 默认 / BashismDetector 按需
//      装 bash / 每命令独立 fork / 900000 ms 默认超时 / sanitizer 截断），
//      并承载跨工具路由策略（read 优先于 bash cat；fs 工具优先于 shell
//      等价物——dsh notes 2026-08-07-ptc-executor-collapse.md:44 口径）+
//      iSH 适配（guest 磁盘写慢→nohup 后台化装包；双通道同一 workspace
//      内容可见性；apk 镜像切换 tsinghua/aliyun）。
//    - tool:web_search（2000）/ tool:web_fetch（2100）——dsh 无公开文本；
//      纯自拟，对拍 WebTools 行为（model-mediated 摘要 + UNVERIFIED 语义；
//      web_fetch 文本净化截断、二进制只回元信息）。
//    - tool:read_image（1600）/ tool:str_replace_editor（1700）——WanWo 本地
//      工具，dsh 无对应物；1600/1700 为本次新增槽位（已入 SECTION_ORDERS）。
//      read_image 明确声明模型当前收不到像素数据，防止模型谎称"已看过图"；
//      str_replace_editor 定位为 edit 族的补充形态（主力仍是 read/write/
//      edit/glob/grep），避免绕开 fs-observation-policy 既有语义。
//
//  【dsh 环境特有段落——未移植（ERR-025 派单方式）】：
//    1. harness:identity —— 已解决：WanWo 版自拟文案于本批注册（见上批注）。
//    2. harness:source（dsh checkout 路径说明）——dsh 开发环境特有，iOS 无意义。
//    3. app:web-surface（dsh Web GUI 本地 URL）——dsh web 壳特有。
//    4. deployment:persona（order 0，部署方 config.persona 提供）——M2 无部署
//       persona 配置源；空段落本来就被组装器丢弃。
//    5. tool:bash —— 已解决：自拟文案于本批注册；tool:pwsh（1010）WanWo 无
//       对应工具，不注册。
//    6. tool:web-search / tool:web-fetch —— 已解决：自拟文案于本批注册。
//    7. WanWo 本地工具 read_image / str_replace_editor —— 已解决：自拟文案
//       于本批注册（新槽位 1600/1700）。
//    8. plan:policy / team:policy / ptc-only / tools-sdk /
//       deliverable-file-references / structured-output——dsh 子系统 sections。
//       M3 T3：plan:policy 已激活——PlanModeController 装配期注册（order 500 =
//       SECTION_ORDERS.planPolicy；text="{{plan_policy}}" 变量门控，active 时
//       变量= cordis.patch.yml:311-321 PLAN_POLICY 原文、inactive 时=""，空段落
//       被 assemble 丢弃）；team/PTC/SDK/结构化输出仍不在排期范围。
//    9. CONTEXT_ORDERS 动态上下文位：sandbox-policy(110) / approval-policy(115) /
//       subagent-delegation(120)——M2 为 AutoApprovalSeam 占位、无沙箱与
//       子代理，均无内容可注入（快照对应位为空）。M3 T2：approval-policy(115)
//       已激活——PermissionCoordinator.approvalPolicyContextLine 供值，经
//       ContextInjector.approvalPolicyProvider 走快照通道注入（快照不进 system，
//       值跟随变化、仅变化才重注入——ERR-024 纪律）；sandbox-policy(110) 仍空
//       （sandbox/mode 事件词汇已随 T2.1 补批注册并持久化，110 快照位供值
//       未排期）；subagent-delegation(120) 不变。
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

    // MARK: - 自拟文本（用户批准稿；analysis/draft-sections.md 逐字）

    /// "harness:identity"（WanWo 版；dsh 原文仅一句 DeepSeek Harness 身份声明，
    /// WanWo 版保持同等克制的分量，补运行环境说明——bash 语义（guest 内执行）
    /// 与 fs 工具语义（宿主 workspace 直读）分野的前提）。
    static let harnessIdentity = "You are an AI agent running in the WanWo harness: a native iPad app whose "
        + "execution environment is an embedded Alpine Linux sandbox (iSH) for shell "
        + "commands, plus a host-side workspace for file tools and web access."

    /// "tool:bash"（dsh 快照无文本，纯自拟；对拍 ShellTool 行为 + 跨工具路由
    /// 策略 + iSH 适配：guest 磁盘写慢 nohup 后台化、双通道一致性、apk 镜像切换）。
    static let toolBash = "Use the bash tool to run shell commands in the session's Alpine Linux guest. "
        + "The default shell is busybox ash (POSIX sh); bash-only syntax is detected "
        + "automatically and bash is installed on demand, but prefer plain POSIX "
        + "constructs so commands run without that extra setup. Each command runs in its "
        + "own process with no shared state: cd, export, and background jobs do not "
        + "persist between calls. The working directory is the session workspace "
        + "(/var/wanwo/workspace). Commands default to a 900000 ms (15 minute) timeout; "
        + "pass timeout_ms to override. Output is sanitized (terminal control sequences "
        + "stripped) and truncated to keep the head and tail — structure long output with "
        + "head, tail, or grep inside the same command. Guest disk writes are slow — "
        + "large apk installs (e.g. nodejs) can take many minutes; run long installs "
        + "detached with nohup and poll the log instead of blocking on the tool timeout. "
        + "The file tools (read/write/edit/glob/grep) and bash operate on the same "
        + "workspace contents, so files created either way are visible to both. When apk "
        + "installs are slow or fail, check /etc/apk/repositories and switch to a nearby "
        + "mirror (e.g. https://mirrors.tuna.tsinghua.edu.cn/alpine/ or "
        + "https://mirrors.aliyun.com/alpine/) that serves the current Alpine version, "
        + "then retry. Route file work to the dedicated tools first: use read — not bash cat — to inspect "
        + "text files, and glob/grep/"
        + "edit for finding and changing files; use bash for what those tools cannot do: "
        + "package management (apk), process control, and guest-side builds and scripts."

    /// "tool:web_search"（dsh 无公开文本，纯自拟；对拍 WebSearchTool：
    /// model-mediated 摘要 + UNVERIFIED——结果是线索不是实据）。
    static let toolWebSearch = "Use the web_search tool to search the web for current information. Results "
        + "are synthesized summaries with source URLs and snippets; the search backend "
        + "is model-mediated, so items may be marked UNVERIFIED. Treat results as leads, "
        + "not ground truth: before relying on a specific claim, fetch its source URL "
        + "with web_fetch and confirm the wording there."

    /// "tool:web_fetch"（dsh 无公开文本，纯自拟；对拍 WebFetchTool：文本净化
    /// 截断回注（max_bytes 默认 200000）、二进制只回元信息）。
    static let toolWebFetch = "Use the web_fetch tool to retrieve a specific URL over HTTP(S). Text "
        + "responses (text, json, xml, javascript) are returned sanitized and capped "
        + "(max_bytes defaults to 200000); binary responses return metadata only — "
        + "content type and size, never the bytes. Prefer web_fetch for reading a known "
        + "page or API endpoint, and for verifying a source surfaced by web_search."

    /// "tool:read_image"（WanWo 本地工具，无 dsh 对应物；对拍 FsReadImageTool：
    /// 模型当前收不到像素数据——文案防止模型谎称"已看过图"）。
    static let toolReadImage = "Use the read_image tool to inspect an image file (PNG/JPEG/WebP/GIF) in the "
        + "workspace. It returns the image's metadata — path, format, dimensions, and "
        + "size — and the image itself is presented to the user in the tool card. The "
        + "model does not receive the pixel data in the current build: do not claim to "
        + "have visually inspected the image; rely on the reported metadata and on the "
        + "user's descriptions."

    /// "tool:str_replace_editor"（WanWo 本地工具，无 dsh 对应物；四命令
    /// view/create/str_replace/insert；定位为 edit 族补充形态，主力仍是
    /// read/write/edit/glob/grep，避免绕开 fs-observation-policy 既有语义）。
    static let toolStrReplaceEditor = "The str_replace_editor tool offers Anthropic-style single-call editing as a "
        + "complement to the read/write/edit tools: `view` shows a file with line "
        + "numbers (optionally limited by a 1-based `view_range`), `create` writes a new "
        + "file from `file_text` and fails if the path already exists, `str_replace` "
        + "replaces `old_str` with `new_str` (old_str must appear exactly once), and "
        + "`insert` places `new_str` after the 1-based line `insert_line`. Prefer the "
        + "edit tool for routine changes and read the file first (the default "
        + "fs-observation-policy requires it), unless you just created or edited it in "
        + "this session; reach for str_replace_editor when its single-call command shape "
        + "fits the change better."

    // MARK: - 注册

    /// 把 system prompt 静态段落注册进组装器。
    /// 顺序由 SECTION_ORDERS 决定，与 dsh 段落布局一致：
    /// harness:identity -1000 → file-reference 900 → bash 1000 → read 1100 /
    /// write 1200 / edit 1300 / glob 1400 / grep 1500 / read_image 1600 /
    /// str_replace_editor 1700 → web_search 2000 / web_fetch 2100。
    static func registerAll(into assembler: PromptAssembler) {
        assembler.section(PromptSection(
            name: "harness:identity",
            order: SECTION_ORDERS.harnessIdentity,
            text: harnessIdentity))
        assembler.section(PromptSection(
            name: "context:file-reference",
            order: SECTION_ORDERS.fileReference,
            text: fileReference))
        assembler.section(PromptSection(
            name: "tool:bash",
            order: SECTION_ORDERS.toolBash,
            text: toolBash))
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
        assembler.section(PromptSection(
            name: "tool:read_image",
            order: SECTION_ORDERS.toolReadImage,
            text: toolReadImage))
        assembler.section(PromptSection(
            name: "tool:str_replace_editor",
            order: SECTION_ORDERS.toolStrReplaceEditor,
            text: toolStrReplaceEditor))
        assembler.section(PromptSection(
            name: "tool:web_search",
            order: SECTION_ORDERS.toolWebSearch,
            text: toolWebSearch))
        assembler.section(PromptSection(
            name: "tool:web_fetch",
            order: SECTION_ORDERS.toolWebFetch,
            text: toolWebFetch))
    }
}
