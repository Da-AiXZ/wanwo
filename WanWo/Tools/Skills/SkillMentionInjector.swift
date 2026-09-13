//
//  SkillMentionInjector.swift
//  WanWo
//
//  【M4-D 件 D6 · F034 显式触发（$name 提及 → 正文注入）】语义移植 · codex 锚点：
//  skills/src/mentions.rs 全 230 行（ToolMentions{names,paths,plain_names} /
//  extract_tool_mentions_with_sigil 逐字节扫描 / parse_linked_tool_mention 链接
//  形态 / is_common_env_var 11 个排除 / is_mention_name_char 六类）+
//  skills/src/selection.rs:42-197（collect_explicit_skill_mentions：路径匹配遍
//  先于裸名遍、保序、skill_count!=1 歧义跳过）。
//
//  WanWo 形态（lead 派单钉死）：
//    · 扫描对象 = 派生面（DeriveFold 产物）真用户消息——排除 `<system-reminder>`
//      （D4 目录消息）与 `<skill `（本件注入产物，防自吞）开头；
//    · 选择面 = snapshot（D7 启停覆盖层已在 registry 出口过滤，selection.rs
//      is_skill_enabled 门同位）；重名/不存在跳过 = 歧义保护（selection.rs
//      :178-190 skill_count==1 才选；registry 同名先见者胜 ⇒ 正常恒 1，防御性
//      保留计数判定）；
//    · 去重 = 派生面已有 `<skill name="X">` 且晚于该消息 → 跳过（无状态幂等：
//      每步全量重扫 + 位置去重，与 D4 派生面基线同一"派生面即状态"模式）；
//    · 正文注入 = user/message，`<skill name="X">` 包裹正文（8KB 截断 =
//      SkillTool.truncateToBytes 同缝；告警文案 extension.rs:472 逐字复用），
//      多技能单消息 `\n\n` 连接（实现选择，登记）；
//    · user-only（disable-model-invocation）技能显式提及照常注入——用户显式
//      提及 = 用户调用通道（dsh 四象限：user-only 只挡模型自发调用）。
//
//  降级不做（lead 裁定）：MCP 依赖联动（selection.rs connector_slug_counts 面
//  + turn.rs:727 connectors 查询）——WanWo connector_count 恒 0（条件恒过）；
//  app_id_from_path / plugin_config_name_from_path 无消费方不移植；结构化
//  UserInput::Skill 输入（blocked_plain_names 遍）WanWo 无该输入形态不移植。
//  name_counts.rs 的 ASCII-lowercase 计数图不移植（消费面=connector 小写匹配，
//  同属降级面）；exact 计数图保留（歧义保护消费）。
//
//  R2：注入=user/message 既有词汇 ✓；呈现过滤=ConversationProjector.
//  markerPrefixes 扩 `<skill ` 前缀（注入消息不渲染气泡）。
//

import Foundation

/// 提及提取产物（mentions.rs:3-7 ToolMentions 等价；值语义）。
struct SkillToolMentions: Equatable, Sendable {
    /// 全部提及名（链接形态按 kind 过滤后的 + 裸名）。
    var names: Set<String> = []
    /// 链接形态的路径原文（含 scheme 前缀，selection 面归一）。
    var paths: Set<String> = []
    /// 裸 `$name` 名（selection 裸名遍消费）。
    var plainNames: Set<String> = []

    var isEmpty: Bool { names.isEmpty && paths.isEmpty }
}

/// 提及路径种类（mentions.rs:27-34 ToolMentionKind 等价）。
enum SkillToolMentionKind: Equatable, Sendable {
    case app, mcp, plugin, skill, other
}

/// 显式触发注入（纯函数命名空间，无状态——派生面即状态）。
enum SkillMentionInjector {

    static let appPathPrefix = "app://"
    static let mcpPathPrefix = "mcp://"
    static let pluginPathPrefix = "plugin://"
    static let skillPathPrefix = "skill://"
    static let skillFilename = "SKILL.md"
    /// sigil（mentions.rs:41 '$'）。
    static let toolMentionSigil: UInt8 = UInt8(ascii: "$")

    /// 注入消息内单技能包裹开标（去重识别 + 投影过滤共用标记）。
    static func marker(for name: String) -> String { "<skill name=\"\(name)\">" }

    // MARK: - 路径分类（mentions.rs:43-60）

    static func toolKind(forPath path: String) -> SkillToolMentionKind {
        if path.hasPrefix(appPathPrefix) { return .app }
        if path.hasPrefix(mcpPathPrefix) { return .mcp }
        if path.hasPrefix(pluginPathPrefix) { return .plugin }
        if path.hasPrefix(skillPathPrefix) || isSkillFilename(path) { return .skill }
        return .other
    }

    /// mentions.rs:57-60：末段（'/' 或 '\' 切分）ASCII 忽略大小写等于 SKILL.md。
    static func isSkillFilename(_ path: String) -> Bool {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        let fileName = parts.last.map(String.init) ?? path
        // eq_ignore_ascii_case 的 Swift 等价（比较目标纯 ASCII，语义等价）。
        return fileName.utf8.count == skillFilename.utf8.count
            && fileName.lowercased() == skillFilename.lowercased()
    }

    /// mentions.rs:72-74：剥 skill:// 前缀（无则原样）。
    static func normalizeSkillPath(_ path: String) -> String {
        path.hasPrefix(skillPathPrefix) ? String(path.dropFirst(skillPathPrefix.count)) : path
    }

    // MARK: - 提取（mentions.rs:85-146 逐式；字节级扫描）

    /// extract_tool_mentions：缺省 sigil '$'。
    static func extractToolMentions(_ text: String) -> SkillToolMentions {
        extractToolMentionsWithSigil(text, sigil: toolMentionSigil)
    }

    static func extractToolMentionsWithSigil(_ text: String,
                                             sigil: UInt8) -> SkillToolMentions {
        let bytes = Array(text.utf8)
        var mentionedNames: Set<String> = []
        var mentionedPaths: Set<String> = []
        var plainNames: Set<String> = []

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            // 链接形态（mentions.rs:94-109）：'[' 开头 → parse_linked；失败则
            // 原地前进一字节继续扫（"[$a]" 会退化为裸名 'a'——Rust 同款语义）。
            if byte == UInt8(ascii: "["),
               let parsed = parseLinkedToolMention(bytes, start: index, sigil: sigil) {
                if !isCommonEnvVar(parsed.name) {
                    let kind = toolKind(forPath: parsed.path)
                    if kind != .app && kind != .mcp && kind != .plugin {
                        mentionedNames.insert(parsed.name)
                    }
                    mentionedPaths.insert(parsed.path)
                }
                index = parsed.end
                continue
            }

            if byte != sigil {
                index += 1
                continue
            }

            // 裸名形态（mentions.rs:116-138）：sigil 后首个字符必须为名字字符，
            // 连续扫到非名字字符。
            let nameStart = index + 1
            guard nameStart < bytes.count, isMentionNameChar(bytes[nameStart]) else {
                index += 1
                continue
            }
            var nameEnd = nameStart + 1
            while nameEnd < bytes.count, isMentionNameChar(bytes[nameEnd]) {
                nameEnd += 1
            }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
            if !isCommonEnvVar(name) {
                mentionedNames.insert(name)
                plainNames.insert(name)
            }
            index = nameEnd
        }
        return SkillToolMentions(names: mentionedNames, paths: mentionedPaths,
                                 plainNames: plainNames)
    }

    /// mentions.rs:148-203 逐式：`[$name](path)`——sigil 在 `[` 后一位、名字
    /// 六类字符、']'、可选 ASCII 空白、'('、path 至 ')'、trim 后非空。
    /// 返回 (name, trim 后 path, 消费终止下标)。
    static func parseLinkedToolMention(_ bytes: [UInt8], start: Int,
                                       sigil: UInt8) -> (name: String, path: String, end: Int)? {
        let sigilIndex = start + 1
        guard sigilIndex < bytes.count, bytes[sigilIndex] == sigil else { return nil }

        let nameStart = sigilIndex + 1
        guard nameStart < bytes.count, isMentionNameChar(bytes[nameStart]) else { return nil }

        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, isMentionNameChar(bytes[nameEnd]) {
            nameEnd += 1
        }
        guard nameEnd < bytes.count, bytes[nameEnd] == UInt8(ascii: "]") else { return nil }

        var pathStart = nameEnd + 1
        while pathStart < bytes.count, isASCIIWhitespace(bytes[pathStart]) {
            pathStart += 1
        }
        guard pathStart < bytes.count, bytes[pathStart] == UInt8(ascii: "(") else { return nil }

        var pathEnd = pathStart + 1
        while pathEnd < bytes.count, bytes[pathEnd] != UInt8(ascii: ")") {
            pathEnd += 1
        }
        guard pathEnd < bytes.count else { return nil }

        let path = String(decoding: bytes[(pathStart + 1)..<pathEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }

        let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
        return (name, path, pathEnd + 1)
    }

    /// mentions.rs:205-221 逐字（ASCII 大写归一后比对）。
    static func isCommonEnvVar(_ name: String) -> Bool {
        switch name.uppercased() {
        case "PATH", "HOME", "USER", "SHELL", "PWD", "TMPDIR",
             "TEMP", "TMP", "LANG", "TERM", "XDG_CONFIG_HOME":
            return true
        default:
            return false
        }
    }

    /// mentions.rs:223-225 逐字：a-z A-Z 0-9 _ - : 六类（ASCII 字节判定）。
    static func isMentionNameChar(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ":"):
            return true
        default:
            return false
        }
    }

    /// u8::is_ascii_whitespace 逐字（空格/\t/\n/\f/\r——不含垂直制表）。
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == 0x09 || byte == 0x0A
            || byte == 0x0C || byte == 0x0D
    }

    // MARK: - 选择（selection.rs:42-197 的 WanWo 形态）

    /// name_counts.rs:8 等价（exact 计数图；lowercase 图不移植——见头注降级登记）。
    static func buildSkillNameCounts(_ skills: [SkillSummary]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for skill in skills { counts[skill.name, default: 0] += 1 }
        return counts
    }

    /// 从提及选择技能：路径匹配遍先于裸名遍（selection.rs 结构保序——产物按
    /// snapshot.summaries 既有序）；禁用技能已在 registry 出口过滤（is_skill_
    /// enabled 门同位）；connector_slug_counts 恒 0（MCP 联动降级，条件恒过）。
    static func selectSkills(mentions: SkillToolMentions,
                             from snapshot: SkillSnapshot) -> [SkillSummary] {
        guard !mentions.isEmpty else { return [] }
        var selected: [SkillSummary] = []
        var seenNames: Set<String> = []
        var seenPaths: Set<String> = []

        // selection.rs:130-139：路径集归一，App/Mcp/Plugin kind 不参与匹配。
        let mentionSkillPaths = Set(mentions.paths
            .filter { path in
                let kind = toolKind(forPath: path)
                return kind != .app && kind != .mcp && kind != .plugin
            }
            .map(normalizeSkillPath))

        // selection.rs:141-162 路径匹配遍：canonical（bodyPath）或发现路径等价
        // （WanWo 等价：bundle=resourceBase 目录、bundle 正文=resourceBase+
        // "/SKILL.md"、平铺=resourceBase——三形态归一后比对，登记为平台差异）。
        for skill in snapshot.summaries {
            let canonical = normalizeSkillPath(skill.bodyPath)
            let discoveryMatches =
                mentionSkillPaths.contains(normalizeSkillPath(skill.resourceBase))
                || mentionSkillPaths.contains(
                    normalizeSkillPath(skill.resourceBase + "/SKILL.md"))
            if mentionSkillPaths.contains(canonical) || discoveryMatches {
                if seenPaths.insert(skill.bodyPath).inserted {
                    seenNames.insert(skill.name)
                    selected.append(skill)
                }
            }
        }

        // selection.rs:164-196 裸名遍：歧义保护（skill_count != 1 → 跳过）；
        // connector 计数恒 0 恒过（降级登记）。
        let nameCounts = buildSkillNameCounts(snapshot.summaries)
        for skill in snapshot.summaries {
            if seenPaths.contains(skill.bodyPath) { continue }
            guard mentions.plainNames.contains(skill.name) else { continue }
            guard nameCounts[skill.name] == 1 else { continue }
            if seenNames.insert(skill.name).inserted {
                seenPaths.insert(skill.bodyPath)
                selected.append(skill)
            }
        }
        return selected
    }

    // MARK: - 投影（lead 派单形态；无状态幂等）

    /// 组装期投影：派生面真用户消息逐条提取 → 选择 → 位置去重 → 注入全文；
    /// nil = 无需注入。
    static func project(snapshot: SkillSnapshot,
                        events: [SessionEvent]) -> String? {
        let messages = DeriveFold(events).messages
        var pending: [SkillSummary] = []
        var seen = Set<String>()

        for (index, message) in messages.enumerated() {
            // 真用户消息识别：排除目录消息（<system-reminder>）与本件注入产物
            // （<skill ，防自吞正文中的 $name 再触发）。
            guard message.role == .user,
                  !message.content.hasPrefix("<system-reminder>"),
                  !message.content.hasPrefix("<skill ") else { continue }
            let mentions = extractToolMentions(message.content)
            guard !mentions.isEmpty else { continue }
            for skill in selectSkills(mentions: mentions, from: snapshot) {
                guard !seen.contains(skill.name) else { continue }
                // 去重：派生面已有 <skill name="X"> 且晚于该消息 → 跳过。
                let marker = marker(for: skill.name)
                if messages[(index + 1)...].contains(where: { $0.content.contains(marker) }) {
                    continue
                }
                seen.insert(skill.name)
                pending.append(skill)
            }
        }

        guard !pending.isEmpty else { return nil }
        let blocks = pending.compactMap(skillBlock)
        guard !blocks.isEmpty else { return nil }
        return blocks.joined(separator: "\n\n")
    }

    /// 单技能注入块：`<skill name="X">` + 正文（8KB 截断 = D5 同缝；告警文案
    /// 复用 SkillTool 逐字常量）。正文读失败 → nil（fail open 跳过——TOCTOU：
    /// 技能文件在快照后删除，下一快照周期自然收敛）。
    static func skillBlock(_ skill: SkillSummary) -> String? {
        guard let contents = try? String(contentsOf: URL(fileURLWithPath: skill.bodyPath),
                                         encoding: .utf8) else {
            return nil
        }
        let (body, truncated) = SkillTool.truncateToBytes(
            contents, maxBytes: SkillTool.maxSkillPromptBytes)
        var section = body
        if truncated {
            section += "\n\n" + SkillTool.truncationWarningPrefix + skill.name
                + SkillTool.truncationWarningSuffix
        }
        return marker(for: skill.name) + "\n" + section + "\n</skill>"
    }
}
