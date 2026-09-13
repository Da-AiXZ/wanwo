//
//  HookBridgeRuntime.swift
//  WanWo
//
//  【M4-E 批 E4 · Documents/hooks/ 装配】出处（逐行亲读，file:line 对拍）：
//    - hooks-claude-code/src/index.ts:96-116（apply 装载语义 + warn 文案）
//    - hooks-codex/src/index.ts:81-97（同构装载 + warn 文案）
//  装载语义（两桥 index.ts 实证）：
//    · 读文件 → JSON.parse → parse → parsed；skipped 逐条 warn 日志
//      （CC index.ts:110-112 / codex :91-93，文案逐字保留）。
//    · 读失败/解析失败 → warn 日志 + 零 hooks 注册，agent 照常启动
//      （CC index.ts:113-116 / codex :94-97 fail open）。
//    · 文件不存在 = 该桥未安装（零注册，非错误）——dsh 拍板项①「文件
//      存在=桥激活」口径：不存在静默（不产出 runtime）、存在但坏 warn
//      （runtime 空组，桥保持已安装态）。
//  替换变量取值（拍板项②）：projectDir=WanWo 装配常量
//  WanWoPaths.workspaceLinuxDir（/var/wanwo/workspace，会话工作区 guest
//  视角，与 dsh 默认 session.header.cwd 同语义）；pluginRoot=WanWo 无插件
//  机制 → 不设（token verbatim 保留，config.ts:59 条件替换）。CLAUDE_
//  PROJECT_DIR env 注入在 E5（HookRunner.env），本层只做解析期替换。
//  配置位置：沙盒 Documents/hooks/（hooks-claude-code.json + hooks-codex.json）
//  ——loader 目录 init 注入（测试临时目录 fixture，勿真读沙盒 Documents）。
//

import Foundation

// MARK: - warn 文案（两桥 index.ts 逐字保真）

enum HookBridgeWarnings {
    /// CC 桥 skipped warn（hooks-claude-code index.ts:111 逐字）。
    static func claudeSkip(_ skipped: SkippedClaudeHook) -> String {
        "hooks-claude-code: skipping unsupported \"\(skipped.type)\" hook on "
            + "\(skipped.event) (only command hooks run)"
    }

    /// Codex 桥 skipped warn（hooks-codex index.ts:92 逐字）。
    static func codexSkip(_ skipped: SkippedCodexHook) -> String {
        "hooks-codex: skipping \(skipped.reason) on \(skipped.event) "
            + "(only sync command hooks run)"
    }

    /// CC 桥装载失败 warn（hooks-claude-code index.ts:114 逐字形态）。
    static func claudeLoadFailure(path: String, error: String) -> String {
        "hooks-claude-code: could not load hook config \"\(path)\": \(error) "
            + "— no hooks registered"
    }

    /// Codex 桥装载失败 warn（hooks-codex index.ts:95 逐字形态）。
    static func codexLoadFailure(path: String, error: String) -> String {
        "hooks-codex: could not load hook config \"\(path)\": \(error) "
            + "— no hooks registered"
    }
}

// MARK: - 桥运行时（E5 runPoint 直接消费）

/// 每桥一个装配产物：解析后的分组表 + 方言轴常量 + warn 清单。
/// E5 五挂点接线按 dialect 分流取用，不再触碰解析层。
struct HookBridgeRuntime: Equatable, Sendable {
    /// 桥方言（事件对 dialect 字段 / payload 尾换行 / matcher 模式的同源）。
    let dialect: HookDialect
    /// 解析产物：事件名 → matcher 组表（组空事件不入——config.ts:119/:82）。
    var groups: [String: [MatcherGroup]]
    /// warn 日志清单（skipped 逐字文案 + 装载失败文案；持有方负责输出）。
    var warnings: [String]
    /// payload 尾换行方言轴（CC true / Codex false——E2 runner 轴）。
    let trailingNewline: Bool
    /// matcher 解释模式（E1 MatcherMode；CC literal/regex 二态、Codex 恒 regex）。
    let matcherMode: MatcherMode
    /// hook/result stderrSummary 字符帽（dsh DEFAULT_STDERR_SUMMARY_MAX_CHARS）。
    let stderrSummaryMaxChars: Int
    /// 默认每 hook 超时 ms（dsh DEFAULT_HOOK_TIMEOUT_MS）。
    let defaultTimeoutMs: Int
    /// Codex 桥 payload 的 model 字段（WanWo 无模型名概念——常量空串保形，
    /// codex index.ts:99 `config.model ?? ''` 同语义）。
    let model: String
}

// MARK: - 装配器

/// hooks 配置装配器：从配置目录装载两桥 runtime。
/// 目录 init 注入（生产 = Documents/hooks/；测试 = 临时目录 fixture）。
struct HookConfigLoader {
    /// hooks 配置目录。
    let directory: URL

    /// CC 桥配置文件名（Documents/hooks/ 内）。
    static let claudeConfigFileName = "hooks-claude-code.json"
    /// Codex 桥配置文件名。
    static let codexConfigFileName = "hooks-codex.json"

    /// `${CLAUDE_PROJECT_DIR}` 解析期替换值 = WanWo 装配常量（会话工作区
    /// guest 视角；单一事实源 WanWoPaths.workspaceLinuxDir）。
    static let projectDir = WanWoPaths.workspaceLinuxDir

    /// 生产落点：沙盒 Documents/hooks/。
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hooks", isDirectory: true)
    }

    /// 装配两桥。文件不存在=桥未安装（静默，不产出 runtime）；存在但坏=
    /// warn+零 hooks（runtime 空组，桥保持已安装态）。
    func load() -> [HookBridgeRuntime] {
        var runtimes: [HookBridgeRuntime] = []
        if let claude = loadClaude() { runtimes.append(claude) }
        if let codex = loadCodex() { runtimes.append(codex) }
        return runtimes
    }

    // MARK: CC 桥装载（hooks-claude-code index.ts:101-116）

    private func loadClaude() -> HookBridgeRuntime? {
        let fileURL = directory.appendingPathComponent(Self.claudeConfigFileName)
        let path = fileURL.path
        // 文件不存在 = 桥未安装（零注册非错误——拍板项①口径）。
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var groups: [String: [MatcherGroup]] = [:]
        var warnings: [String] = []
        do {
            let data = try Data(contentsOf: fileURL)
            let raw = try JSONDecoder().decode(JSONValue.self, from: data)
            // 解析期替换：projectDir=装配常量；pluginRoot 不设（verbatim）。
            let parsed = try HookBridgeConfig.parseClaudeCodeConfig(
                raw, vars: SubstitutionVars(projectDir: Self.projectDir))
            groups = parsed.config
            warnings = parsed.skipped.map(HookBridgeWarnings.claudeSkip)
        } catch {
            // fail open：读失败/解析失败 warn + 零 hooks，agent 照常启动
            //（CC index.ts:113-116）。
            warnings = [HookBridgeWarnings.claudeLoadFailure(
                path: path, error: String(describing: error))]
        }
        return HookBridgeRuntime(
            dialect: .claudeCode,
            groups: groups,
            warnings: warnings,
            trailingNewline: true,        // E2 方言轴：CC 有尾换行
            matcherMode: .claudeCode,
            stderrSummaryMaxChars: HookSessionEvents.defaultStderrSummaryMaxChars,
            defaultTimeoutMs: HookRunner.defaultHookTimeoutMs,
            model: "")
    }

    // MARK: Codex 桥装载（hooks-codex index.ts:86-97）

    private func loadCodex() -> HookBridgeRuntime? {
        let fileURL = directory.appendingPathComponent(Self.codexConfigFileName)
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var groups: [String: [MatcherGroup]] = [:]
        var warnings: [String] = []
        do {
            let data = try Data(contentsOf: fileURL)
            let raw = try JSONDecoder().decode(JSONValue.self, from: data)
            let parsed = try HookBridgeConfig.parseCodexConfig(raw)
            groups = parsed.config
            warnings = parsed.skipped.map(HookBridgeWarnings.codexSkip)
        } catch {
            // fail open（codex index.ts:94-97）。
            warnings = [HookBridgeWarnings.codexLoadFailure(
                path: path, error: String(describing: error))]
        }
        return HookBridgeRuntime(
            dialect: .codex,
            groups: groups,
            warnings: warnings,
            trailingNewline: false,       // E2 方言轴：Codex 无尾换行
            matcherMode: .codex,
            stderrSummaryMaxChars: HookSessionEvents.defaultStderrSummaryMaxChars,
            defaultTimeoutMs: HookRunner.defaultHookTimeoutMs,
            model: "")                    // WanWo 无模型名——常量空串保形
    }
}
