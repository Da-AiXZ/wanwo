//
//  PermissionRules.swift
//  WanWo
//
//  【语义移植 · codex execpolicy · M3 T2】出处：
//    - 06-codex-gap1 §六 —— 规则文件语法：prefix_rule 的 pattern 为 token
//      序列（元素可为多选一，如 [["npm","pnpm"],"run"]）；network_rule 的
//      host 精确匹配、禁通配（含 "*" 的规则永不命中——fail closed）。
//    - §七.1/§七.2 —— 多层规则文件低→高叠加；同名规则重复无害；一次判定
//      命中多条取最严（allow < prompt < forbidden，与
//      ApprovalDecisionVerdict.strictest 同序）。
//    - §七.3 —— 沉淀四类中 WanWo 本批实现两类：ApprovedExecpolicyAmendment
//      （审批通过的 bash 命令沉淀为前缀规则，落盘 user 层）+ ApprovedForSession
//      （会话级审批缓存，内存态）；禁推黑名单与沉淀配套（codex
//      BANNED_PREFIX_SUGGESTIONS 的 WanWo 自拟清单，全集见批次报告）。
//    - §八.3 —— 审批缓存键完备性：key = 环境(cwd) + 可执行(工具) +
//      规范化参数 + 沙箱权限 + 策略指纹。
//    - 策略指纹（codex requirements 指纹语义）= 审批策略值 + 规则库版本摘要。
//  fail-closed 纪律：wrapper 命令（bash -c 等）内外层逐段判定，任一层无规则
//  命中即整体回落启发式矩阵（规则只收紧，不放宽未覆盖面）；黑名单命中永不
//  沉淀；通配 host 规则永不匹配。
//

import Foundation
import Darwin

// MARK: - 规则判定词汇

/// 规则判定词汇（codex Decision 的持久化字符串形态；gap1 §3.1）。
enum PermissionRuleVerdict: String, Codable, Equatable, Sendable {
    case allow
    case prompt
    case forbidden

    var decision: ApprovalDecisionVerdict {
        switch self {
        case .allow: return .allow
        case .prompt: return .prompt
        case .forbidden: return .forbidden
        }
    }

    static func from(decision: ApprovalDecisionVerdict) -> PermissionRuleVerdict {
        switch decision {
        case .allow: return .allow
        case .prompt: return .prompt
        case .forbidden: return .forbidden
        }
    }
}

// MARK: - 规则记录（user 层 JSONL 行 1:1）

/// 一条权限规则。kind: "prefix"（pattern 生效）| "network"（host 生效）。
/// 来源可溯：source + origin（审批沉淀记原始命令全文；手工添加记输入原文）。
struct PermissionRule: Identifiable, Equatable, Codable, Sendable {
    var id: String = UUID().uuidString
    /// "prefix" | "network"。
    var kind: String
    /// prefix 规则的 token 序列（外层元素逐位对齐命令 token，内层元素 = 多选一）。
    var pattern: [[String]]?
    /// network 规则的 host（可带 scheme 前缀；含 "*" 永不匹配——fail closed）。
    var host: String?
    /// PermissionRuleVerdict.rawValue。
    var verdict: String
    /// 来源："remembered"（审批沉淀）| "manual"（用户手工添加）。
    var source: String
    /// 溯源原文。
    var origin: String?
    var createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    /// 规则签名（去重与指纹输入；同签名追加 = 幂等 no-op）。
    var signature: String {
        if kind == "prefix", let pattern {
            return "prefix:" + pattern.map { $0.sorted().joined(separator: "|") }
                .joined(separator: "\u{1}") + ":" + verdict
        }
        if kind == "network", let host {
            return "network:" + host + ":" + verdict
        }
        return "unknown:\(id)"
    }
}

// MARK: - 禁推黑名单（沉淀红线）

/// 禁推黑名单（codex BANNED_PREFIX_SUGGESTIONS 的 WanWo 自拟清单；
/// 「允许并记住」沉淀红线：命中即拒，永不落盘）。全集见批次报告。
enum BannedPrefixSuggestions {
    /// 首位 token 黑名单：提权/身份切换、破坏性/系统级、动态执行/载入、
    /// 解释器与 shell 包装器（wrapper 的内层无法前缀化——整体禁推）。
    static let firstTokens: Set<String> = [
        // 提权与身份切换
        "sudo", "su", "doas", "pkexec",
        // 破坏性 / 系统级
        "rm", "dd", "mkfs", "shutdown", "reboot", "halt", "poweroff",
        // 动态执行 / 载入
        "eval", "exec", "source", ".",
        // shell 与解释器包装器
        "bash", "sh", "ash", "dash", "zsh", "ksh",
        "python", "python3", "node", "perl", "ruby", "php",
        "cmd", "powershell", "pwsh", "osascript",
    ]

    /// 返回命中的首个禁推 token（nil = 可沉淀）。
    static func violation(in tokens: [String]) -> String? {
        guard let first = tokens.first else { return nil }
        return firstTokens.contains(first) ? first : nil
    }
}

// MARK: - 规则引擎（纯函数判定）

/// 规则引擎（gap1 §七：多层低→高叠加、同名重复无害、命中取最严）。
struct PermissionRulesEngine: Sendable {
    /// 判定候选段（bash：外层 token 序列 + wrapper 拆出的内层序列；
    /// network：host 段）。
    enum Candidate: Sendable {
        case tokens([String])
        case host(host: String, scheme: String?)
    }

    /// 层序列（低 → 高）；每层为有序规则表。
    var layers: [[PermissionRule]] = []

    /// 判定一笔工具调用。返回 nil = 无规则命中（调用方回落启发式矩阵）。
    /// bash → 命令 token 序列；web_fetch → URL host；其余工具不适用（nil）。
    func decide(tool: String, args: JSONValue) -> ApprovalDecisionVerdict? {
        guard !layers.isEmpty else { return nil }
        switch tool {
        case "bash":
            guard let command = args.field("command")?.stringValue, !command.isEmpty else {
                return nil
            }
            return decideCandidates(Self.candidates(forCommand: command))
        case "web_fetch":
            guard let urlText = args.field("url")?.stringValue,
                  let url = URL(string: urlText),
                  let host = url.host, !host.isEmpty else { return nil }
            return decideCandidates([.host(host: host, scheme: url.scheme?.lowercased())])
        default:
            return nil
        }
    }

    /// 多段判定（gap1 §六：wrapper 拆内层逐条判定）。任一段无规则命中 →
    /// 整体 nil（fail closed：规则未覆盖的面交回启发式矩阵，绝不静默放行）；
    /// 全覆盖 → 各段命中取最严后跨段再取最严。
    func decideCandidates(_ candidates: [Candidate]) -> ApprovalDecisionVerdict? {
        var overall: ApprovalDecisionVerdict?
        for candidate in candidates {
            var matched: ApprovalDecisionVerdict?
            for layer in layers {
                for rule in layer {
                    guard let verdict = Self.matchedVerdict(rule: rule, candidate: candidate)
                    else { continue }
                    matched = matched.map { ApprovalDecisionVerdict.strictest($0, verdict) }
                        ?? verdict
                }
            }
            guard let matched else { return nil }
            overall = overall.map { ApprovalDecisionVerdict.strictest($0, matched) } ?? matched
        }
        return overall
    }

    /// 单规则 × 单候选匹配（kind 不对齐 / 形状不合法 → nil）。
    static func matchedVerdict(rule: PermissionRule,
                               candidate: Candidate) -> ApprovalDecisionVerdict? {
        guard let verdict = PermissionRuleVerdict(rawValue: rule.verdict)?.decision else {
            return nil
        }
        if rule.kind == "prefix", case .tokens(let tokens) = candidate {
            guard let pattern = rule.pattern,
                  Self.prefixMatches(pattern, tokens) else { return nil }
            return verdict
        }
        if rule.kind == "network", case .host(let host, let scheme) = candidate {
            guard let spec = rule.host,
                  Self.hostMatches(spec, host: host, scheme: scheme) else { return nil }
            return verdict
        }
        return nil
    }

    /// prefix 匹配（codex prefix_rule：pattern 逐位对齐，元素 = 多选一；
    /// 空备选元素永不匹配——畸形规则 fail closed）。
    static func prefixMatches(_ pattern: [[String]], _ tokens: [String]) -> Bool {
        guard !pattern.isEmpty, pattern.count <= tokens.count else { return false }
        for (index, alternatives) in pattern.enumerated() {
            guard !alternatives.isEmpty, alternatives.contains(tokens[index]) else {
                return false
            }
        }
        return true
    }

    /// network 匹配（codex network_rule：host 精确、禁通配；规则带 scheme 时
    /// 协议必须一致，裸 host 两种协议均匹配）。
    static func hostMatches(_ spec: String, host: String, scheme: String?) -> Bool {
        guard !spec.contains("*") else { return false }
        if let range = spec.range(of: "://") {
            let ruleScheme = String(spec[..<range.lowerBound]).lowercased()
            let ruleHost = String(spec[range.upperBound...]).lowercased()
            return ruleScheme == (scheme ?? "") && ruleHost == host.lowercased()
        }
        return spec.lowercased() == host.lowercased()
    }

    // MARK: - bash 候选段（wrapper 拆内层）

    /// wrapper 可执行（首位命中即尝试拆内层命令）。
    private static let wrapperExecutables: Set<String> =
        ["bash", "sh", "ash", "dash", "zsh", "ksh"]
    /// 内层命令旗标（其后一个 token 为内层命令原文）。
    private static let wrapperInnerFlags: Set<String> = ["-c", "-lc"]

    /// bash 命令 → 候选段列表（外层 + wrapper 内层；gap1 §六 bash -lc 拆段）。
    static func candidates(forCommand command: String) -> [Candidate] {
        let tokens = tokenize(command)
        guard !tokens.isEmpty else { return [] }
        var out: [Candidate] = [.tokens(tokens)]
        if wrapperExecutables.contains(tokens[0]),
           let flagIndex = tokens.firstIndex(where: { wrapperInnerFlags.contains($0) }),
           flagIndex + 1 < tokens.count {
            let inner = tokenize(tokens[flagIndex + 1])
            if !inner.isEmpty { out.append(.tokens(inner)) }
        }
        return out
    }

    /// shell 词法切分（空白分隔；单/双引号内空白不切分；未闭合引号的余段
    /// 并入末 token——判定用保守形态，不追求 shell 语义完备）。
    static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        for char in command {
            if let openQuote = quote {
                if char == openQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            switch char {
            case "'", "\"":
                quote = char
                hasToken = true
            case " ", "\t", "\n", "\r":
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(char)
                hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}

// MARK: - 规则库（user 层 JSONL；flock 排他 + 签名去重 + 版本指纹）

/// 权限规则库（App 级共享；进程内 NSLock + 跨进程 flock 双层串行化）。
final class PermissionRulesStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var storage: [PermissionRule] = []
    /// 版本号（每次有效变更 +1；策略指纹输入）。
    private(set) var version = 1

    private static let logger = AppLogger(category: "PermissionRules")

    init(fileURL: URL) {
        self.fileURL = fileURL
        loadFromDisk()
    }

    var rules: [PermissionRule] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 追加规则（签名去重：同签名已存在 → no-op 返回 false——gap1 §七.1
    /// 「同名重复无害」的持久化形态）。落盘失败不进内存（fail closed）。
    @discardableResult
    func add(_ rule: PermissionRule) -> Bool {
        lock.lock()
        if storage.contains(where: { $0.signature == rule.signature }) {
            lock.unlock()
            return false
        }
        do {
            try appendToDisk(rule)
        } catch {
            lock.unlock()
            Self.logger.error("permission rule append failed: \(String(describing: error))")
            return false
        }
        storage.append(rule)
        version += 1
        lock.unlock()
        return true
    }

    /// 删除规则（JSONL 追加模型 → 全量快照原子重写）。
    @discardableResult
    func remove(id: String) -> Bool {
        lock.lock()
        guard let index = storage.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        storage.remove(at: index)
        version += 1
        let snapshot = storage
        lock.unlock()
        rewrite(snapshot)
        return true
    }

    /// 引擎快照（单 user 层；builtin 层缺位——出厂零规则，fail closed 缺省）。
    func engine() -> PermissionRulesEngine {
        PermissionRulesEngine(layers: [rules])
    }

    /// 规则库摘要（策略指纹输入；FNV-1a 64 + 版本号）。
    func signatureDigest() -> String {
        lock.lock()
        defer { lock.unlock() }
        let joined = storage.map(\.signature).sorted().joined(separator: "\u{2}")
        var hash: UInt64 = 1_469_598_103_934_665_6037
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "rules-v\(version):\(String(hash, radix: 16))"
    }

    // MARK: - 磁盘

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        var loaded: [PermissionRule] = []
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let rule = try? decoder.decode(PermissionRule.self, from: Data(line)),
                  // 加载期同样去重（手改文件引入的重复行不放大）。
                  seen.insert(rule.signature).inserted else { continue }
            loaded.append(rule)
        }
        lock.lock()
        storage = loaded
        lock.unlock()
    }

    /// flock 排他追加（fsync 落盘——与 SessionWriter「append 即 durable」同纪律）。
    private func appendToDisk(_ rule: PermissionRule) throws {
        var line = try JSONEncoder().encode(rule)
        line.append(UInt8(ascii: "\n"))
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: "PermissionRules", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "open(\(fileURL.path)) failed",
            ])
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw NSError(domain: "PermissionRules", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "flock failed for \(fileURL.path)",
            ])
        }
        defer { flock(fd, LOCK_UN) }
        var written = 0
        while written < line.count {
            let n = line.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: written), raw.count - written)
            }
            guard n > 0 else {
                throw NSError(domain: "PermissionRules", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "write failed for \(fileURL.path)",
                ])
            }
            written += n
        }
        fsync(fd)
    }

    private func rewrite(_ snapshot: [PermissionRule]) {
        var data = Data()
        for rule in snapshot {
            if let line = try? JSONEncoder().encode(rule) {
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 会话级审批缓存（codex ApprovedForSession）

/// 会话级审批缓存（内存态、会话生命周期）。键 = gap1 §八.3 完备键
/// （cwd + 工具 + 规范化参数 + 沙箱权限 + 策略指纹）；指纹内含规则库版本，
/// 规则/策略一变旧键自然失效（无需失效扫描）。FIFO 封顶防无界增长。
final class SessionApprovalCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []
    private var order: [String] = []
    private let capacity = 256

    /// 规范化缓存键（bash 命令做 token 规范化——引号/空白形态差异归一；
    /// 其余工具参数走确定性 JSON 文本——ERR-026 排序编码保证稳定）。
    static func key(cwd: String, tool: String, args: JSONValue,
                    sandboxMode: String, policyFingerprint: String) -> String {
        let normalizedArgs: String
        if tool == "bash", let command = args.field("command")?.stringValue {
            normalizedArgs = PermissionRulesEngine.tokenize(command)
                .joined(separator: "\u{1}")
        } else {
            normalizedArgs = (try? JSONEncoder().encode(args))
                .map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
        }
        return [cwd, tool, normalizedArgs, sandboxMode, policyFingerprint]
            .joined(separator: "\u{3}")
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains(key)
    }

    func insert(_ key: String) {
        lock.lock()
        if keys.insert(key).inserted {
            order.append(key)
            if order.count > capacity {
                keys.remove(order.removeFirst())
            }
        }
        lock.unlock()
    }
}
