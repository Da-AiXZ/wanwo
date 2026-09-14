//
//  NetworkPolicy.swift
//  WanWo
//
//  【语义移植 · dsh/codex · M5-B N1 · F028 沙箱网络隔离】出处：
//  · dsh packages/util/http-proxy/src/policy.ts（343 行全文——SUPPORTED_PROTOCOLS
//    http/https 白名单 :57、isLoopbackHost :257-266（localhost/`.localhost` 后缀/
//    全 127/8/IPv4-mapped 两拼写）、bypassesProxy 域名条目匹配 :279-295（大小写/
//    尾点归一化、子域后缀匹配））；
//  · codex network-proxy/src/policy.rs（Host 归一化 :101-148、域名三形态
//    exact / `*.` 仅子域 / `**.` 含 apex :185-231/:321-331、is_non_public_ip
//    SSRF 段表 :45-98——stdlib 私网段 + CGNAT/TEST-NET/benchmark/reserved 显式
//    CIDR、IPv6 mapped/unique-local/link-local）；
//  · 06-codex-gap6 §4.4（"受限网络 = 只能连托管代理" invariant + Deny>Allow +
//    决策 reason 细分 denied/not_allowed/not_allowed_local）；
//  · 07 清单 F028 iOS 注记："iOS 本地经 App Sandbox + 代理配置近似；完整三平台
//    隔离逻辑部署于远程沙箱"。
//
//  WanWo 形态（最小收官件）：
//    · 纯函数裁决面 judge(url)/judge(host:scheme:)——deny 优先：scheme 面 →
//      SSRF（IP 字面量非公网恒拒，含白名单命中时）→ 域名白名单；
//    · 挂接点 = WebFetchTool（AI 的工具出站裁决前置）；LLM adapter 面不受限
//      （模型 API 本体白名单外——dsh http-proxy 管 harness 全局，WanWo 收窄到
//      工具面=近似近似，登记）；guest 侧（iSH curl/fetch 直连宿主网络栈）无
//      裁点——guest 出站白名单留 M6（登记）；
//    · 独立 NetworkPolicy 配置（非 SandboxMode 维度——dsh index.ts:30-31
//      "Network and process visibility are outside this vocabulary" 同构）。
//
//  登记差异：
//    ① 白名单 pattern 语法取 codex 三形态（exact / `*.` 仅子域 / `**.` 含
//      apex + `*` 全局）——dsh noProxy 是旁路列表语义（子域后缀匹配、无
//      apex/子域区分），白名单需区分故取 codex 形态；归一化两源一致
//      （大小写/尾点/括号/单冒号端口剥离）。
//    ② 端口不设白名单：dsh policy.ts 仅 scheme 面（http/https，SOCKS 显式
//      拒），端口不约束；codex 无端口约束。WanWo 同。
//    ③ IP 字面量不做规范化 Canonical 化（codex normalize_ip_literal 经
//      stdlib parse 规范化）——按解析判定 SSRF（::ffff:127.0.0.1 等 mapped
//      拼写经解析归一处置），白名单 IP 条目按字面匹配。
//    ④ scope-id 字面量（fe80::1%lo0）恒判非公网（scope 只出现在 link-local）。
//    ⑤ loopback 主机名面取 dsh∪codex 并集："localhost"/`.localhost` 后缀
//      （dsh :259）/ IP 解析 loopback（codex :33-43）。
//    ⑥ 重定向跟随面未裁决（URLSession 默认跟随——逐跳裁决留后续件登记；
//      codex connect 阶段 TargetCheckedTcpConnector 同面）。
//    ⑦ codex 逃生门（dangerously_allow_*）与 Ask 可升级审批不移植（第一版
//      只有终局 deny/allow 两值）。
//    ⑧ IPv4 字面前导零容忍（"010.0.0.1" 按十进制解析为私网 → 拒）——codex
//      stdlib parse 拒绝前导零整串退化主机名；WanWo 取 deny 方向（前导零
//      拼写不得绕过私网段判定）。
//

import Foundation

// MARK: - 主机归一化

/// 主机归一化（codex normalize_host :101-148 / dsh bypassesProxy :282 同构）：
/// 去首尾空白、剥 IPv6 括号、单冒号端口剥离、小写化、去尾点、scope-id 保留。
enum HostNormalization {
    static func normalize(_ raw: String) -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return normalizeDnsHostOrIPLiteral(String(host[host.index(after: host.startIndex)..<close]))
        }
        // 防御性端口剥离：恰好一个冒号时按 host:port 处置（codex :110-114；
        // 未加括号的 IPv6 字面量多冒号，原样保序）。
        if host.filter({ $0 == ":" }).count == 1 {
            let bare = String(host.prefix(while: { $0 != ":" }))
            return normalizeDnsHostOrIPLiteral(bare)
        }
        return normalizeDnsHostOrIPLiteral(host)
    }

    private static func normalizeDnsHostOrIPLiteral(_ host: String) -> String {
        // 尾点剥离（FQDN 与无点变体同判）；scope-id 原样保留（codex :500-503）。
        var trimmed = host.lowercased()
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }
}

// MARK: - IP 字面量解析

/// IP 字面量解析与分类（纯 Swift——SSRF 段表 codex policy.rs:45-98 1:1）。
enum IPAddressLiteral {

    /// 解析结果：非字面量 / scoped 字面量（%lo0——恒 link-local 面）/ 地址。
    enum ParseResult: Equatable {
        case notLiteral
        case scopedLiteral
        case address(Address)
    }

    enum Address: Equatable {
        case v4(UInt32)
        case v6([UInt16])  // 8 组 16 位
    }

    /// 解析 host 为 IP 字面量。scoped（`%` 后缀）字面量单独回报（登记④）。
    static func parse(_ raw: String) -> ParseResult {
        if let percent = raw.firstIndex(of: "%") {
            let base = String(raw[..<percent])
            // codex unscoped_ip_literal :130-134：% 后须仍是合法 IP 才算 scoped
            // 字面量；否则整串按主机名处置。
            guard case .address? = parseUnscoped(base) else { return .notLiteral }
            return .scopedLiteral
        }
        return parseUnscoped(raw) ?? .notLiteral
    }

    private static func parseUnscoped(_ raw: String) -> ParseResult? {
        if let v4 = parseIPv4(raw) { return .address(.v4(v4)) }
        if let v6 = parseIPv6(raw) { return .address(.v6(v6)) }
        return nil
    }

    /// 严格点分四段（每段 0-255；`127.999.1.1` 拒——dsh OCTET 语义 :240）。
    static func parseIPv4(_ raw: String) -> UInt32? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber })
            else { return nil }
            // 前导零容忍（JSON/URL 实践常见）；段值 0-255 强制。
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    /// IPv6 解析：完整/`::` 压缩/内嵌 IPv4 尾段（::ffff:1.2.3.4 与 ::1.2.3.4）。
    static func parseIPv6(_ raw: String) -> [UInt16]? {
        // 内嵌 IPv4 尾段 → 两 u16 组。
        var segments: [UInt16] = []
        var body = raw
        var hadV4Tail = false
        if let lastColon = body.lastIndex(of: ":"),
           body.index(after: lastColon) < body.endIndex {
            let tail = String(body[body.index(after: lastColon)...])
            if tail.contains(".") {
                guard let v4 = parseIPv4(tail) else { return nil }
                segments.append(UInt16((v4 >> 16) & 0xffff))
                segments.append(UInt16(v4 & 0xffff))
                body = String(body[..<lastColon])
                hadV4Tail = true
            }
        } else if body.contains(".") {
            // 纯 IPv4（无冒号）不是 IPv6。
            return nil
        }

        let groups = body.split(separator: ":", omittingEmptySubsequences: false)
        if body.contains("::") {
            // 压缩形：`::` 至多一次，展开为至少一组零段。
            let pieces = body.components(separatedBy: "::")
            guard pieces.count <= 2 else { return nil }
            let head = pieces[0].isEmpty ? [] : pieces[0].split(separator: ":")
            let tail = pieces.count == 2 && !pieces[1].isEmpty
                ? pieces[1].split(separator: ":") : []
            guard head.count + tail.count <= 7 else { return nil }
            var parsed: [UInt16] = []
            for part in head { guard let g = hexGroup(part) else { return nil }; parsed.append(g) }
            let headCount = parsed.count
            for part in tail { guard let g = hexGroup(part) else { return nil }; parsed.append(g) }
            let fill = 8 - parsed.count
            guard fill >= 1 else { return nil }
            segments = Array(parsed[..<headCount])
                + Array(repeating: 0, count: fill)
                + Array(parsed[headCount...])
            if hadV4Tail {
                // v4 尾段已在 segments 尾部——重排：head + fill + tail + v4tail。
                let headSegs = Array(parsed[..<headCount])
                let tailSegs = Array(parsed[headCount...])
                let v4Segs = segments.suffix(2)
                let inner = 8 - headSegs.count - tailSegs.count - 2
                guard inner >= 1 else { return nil }
                segments = headSegs + Array(repeating: 0, count: inner)
                    + tailSegs + Array(v4Segs)
            }
        } else {
            // 完整形：恰好 8 组；含 v4 尾段时冒号组为 6（尾段已折成两 u16）。
            let expected = hadV4Tail ? 6 : 8
            guard groups.count == expected else { return nil }
            var parsed: [UInt16] = []
            for part in groups { guard let g = hexGroup(part) else { return nil }; parsed.append(g) }
            parsed.append(contentsOf: segments)  // v4 尾段（如有）补在尾部
            segments = parsed
        }
        guard segments.count == 8 else { return nil }
        return segments
    }

    private static func hexGroup(_ part: Substring) -> UInt16? {
        guard !part.isEmpty, part.count <= 4,
              part.allSatisfy({ $0.isHexDigit }) else { return nil }
        return UInt16(part, radix: 16)
    }

    // MARK: SSRF 段表（codex is_non_public_ip :45-98 1:1）

    /// IPv4 in CIDR（codex ipv4_in_cidr :72-81 同式）。
    static func ipv4(_ ip: UInt32, inCidr base: UInt32, prefix: Int) -> Bool {
        guard prefix > 0 else { return true }
        let mask: UInt32 = prefix >= 32 ? .max : .max << (32 - prefix)
        return (ip & mask) == (base & mask)
    }

    static func isNonPublicIPv4(_ ip: UInt32) -> Bool {
        return inCidr(ip, 127 << 24, 8)          // loopback（全 /8）
            || inCidr(ip, 10 << 24, 8)           // private 10/8
            || inCidr(ip, (172 << 24) | (16 << 16), 12)  // private 172.16/12
            || inCidr(ip, (192 << 24) | (168 << 16), 16) // private 192.168/16
            || inCidr(ip, (169 << 24) | (254 << 16), 16) // link-local 169.254/16
            || ip == 0                           // unspecified 0.0.0.0
            || inCidr(ip, 0, 8)                  // "this network" 0/8（RFC 1122）
            || (ip & 0xf000_0000) == 0xe000_0000 // multicast 224/4
            || ip == 0xffff_ffff                 // broadcast
            || inCidr(ip, (100 << 24) | (64 << 16), 10)  // CGNAT（RFC 6598）
            || inCidr(ip, (192 << 24), 24)       // IETF Protocol Assignments（RFC 6890）
            || inCidr(ip, (192 << 24) | (2 << 16), 24)   // TEST-NET-1（RFC 5737）
            || inCidr(ip, (198 << 24) | (18 << 16), 15)  // Benchmarking（RFC 2544）
            || inCidr(ip, (198 << 24) | (51 << 16) | (100 << 8), 24) // TEST-NET-2
            || inCidr(ip, (203 << 24) | (113 << 8), 24)  // TEST-NET-3
            || inCidr(ip, (240 << 24), 4)        // Reserved（RFC 6890）
    }

    /// Rust to_ipv4 语义：前 5 组全零 → 尾两组合成 IPv4
    ///（::ffff:8.8.8.8 与 ::8.8.8.8 同判——codex :84-86）。
    private static func mappedIPv4(of segments: [UInt16]) -> UInt32? {
        guard segments[0] == 0, segments[1] == 0, segments[2] == 0,
              segments[3] == 0, segments[4] == 0 else { return nil }
        return (UInt32(segments[6]) << 16) | UInt32(segments[7])
    }

    static func isNonPublicIPv6(_ segments: [UInt16]) -> Bool {
        if let v4 = mappedIPv4(of: segments) {
            // codex :84-85——mapped 形走 IPv4 判定，外加 ::1 loopback 直判。
            return isNonPublicIPv4(v4) || segments == [0, 0, 0, 0, 0, 0, 0, 1]
        }
        let loopback = segments[0] == 0 && segments[1] == 0 && segments[2] == 0
            && segments[3] == 0 && segments[4] == 0 && segments[5] == 0
            && segments[6] == 0 && segments[7] == 1
        let unspecified = segments.allSatisfy { $0 == 0 }
        let multicast = (segments[0] & 0xff00) == 0xff00
        let uniqueLocal = (segments[0] & 0xfe00) == 0xfc00       // fc00::/7
        let linkLocal = (segments[0] & 0xffc0) == 0xfe80         // fe80::/10
        return loopback || unspecified || multicast || uniqueLocal || linkLocal
    }

    /// 字符串便捷判定：非 IP 字面量 → nil（由调用方走主机名面）。
    static func nonPublicIfLiteral(_ normalizedHost: String) -> Bool? {
        switch parse(normalizedHost) {
        case .notLiteral:
            return nil
        case .scopedLiteral:
            return true  // scope-id 只出现在 link-local（登记④）
        case .address(.v4(let ip)):
            return isNonPublicIPv4(ip)
        case .address(.v6(let segments)):
            return isNonPublicIPv6(segments)
        }
    }
}

// MARK: - 域名 pattern

/// 白名单 pattern（codex DomainPattern :226-231 三形态 + `*` 全局）：
/// `example.com` 精确 / `*.example.com` 仅子域（不含 apex）/
/// `**.example.com` 含 apex 与子域 / `*` 全局放行。
enum DomainPattern: Equatable {
    case exact(String)
    case subdomainsOnly(String)
    case apexAndSubdomains(String)
    case globalWildcard

    /// codex normalize_pattern :150-170 + DomainPattern.parse :237-249。
    static func parse(_ raw: String) -> DomainPattern {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern == "*" { return .globalWildcard }
        if let domain = pattern.hasPrefix("**.") ? String(pattern.dropFirst(3)) : nil {
            return .apexAndSubdomains(HostNormalization.normalize(domain))
        }
        if let domain = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : nil {
            return .subdomainsOnly(HostNormalization.normalize(domain))
        }
        return .exact(HostNormalization.normalize(pattern))
    }

    /// codex is_subdomain_or_equal / is_strict_subdomain :341-354
    ///（后缀锚必须带点——`badexample.com` 不命中 `example.com`）。
    func matches(_ host: String) -> Bool {
        let normalized = HostNormalization.normalize(host)
        switch self {
        case .globalWildcard:
            return true
        case .exact(let domain):
            return normalized == domain
        case .subdomainsOnly(let domain):
            return normalized != domain && normalized.hasSuffix(".\(domain)")
        case .apexAndSubdomains(let domain):
            return normalized == domain || normalized.hasSuffix(".\(domain)")
        }
    }
}

// MARK: - NetworkPolicy

/// 网络裁决（F028：受限网络 = 只能连白名单——域名逐连接裁决，deny 优先 +
/// SSRF 防护恒开）。纯函数面，无传输依赖（dsh policy.ts "pure, transport-free
/// half" 同构）。
struct NetworkPolicy: Sendable {

    /// 裁决（codex NetworkDecision :58 两值形态 + reason 细分
    /// denied/not_allowed/not_allowed_local——第一版无 Ask 可升级，登记⑦）。
    enum Verdict: Equatable {
        case allow
        /// reason：`not_allowed`（scheme 面/白名单未命中）/
        /// `not_allowed_local`（非公网 IP 字面量/loopback 主机名）。
        case deny(reason: String)
    }

    /// 域名白名单；nil = 不受限（第一版装配缺省）。deny 优先：白名单外一律拒。
    let allowedDomains: [String]?

    /// 不受限策略（SSRF 防护仍恒开——F028 SSRF 是工具面恒开防线，登记）。
    static let unrestricted = NetworkPolicy(allowedDomains: nil)

    init(allowedDomains: [String]?) {
        self.allowedDomains = allowedDomains
    }

    /// URL 形态裁决（scheme 面 → SSRF → 白名单）。
    func judge(url: URL) -> Verdict {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // dsh SUPPORTED_PROTOCOLS :57（SOCKS 等显式拒）。
            return .deny(reason: "not_allowed")
        }
        return judge(host: url.host ?? "", scheme: scheme)
    }

    /// host+scheme 形态裁决（纯函数；WebFetchTool 挂接点经 URL 形态进入）。
    func judge(host rawHost: String, scheme: String) -> Verdict {
        guard scheme == "http" || scheme == "https" else {
            return .deny(reason: "not_allowed")
        }
        let host = HostNormalization.normalize(rawHost)
        guard !host.isEmpty else { return .deny(reason: "not_allowed") }

        // SSRF 恒开（deny 优先于白名单——即使 `*` 全局白名单，非公网 IP
        // 字面量仍拒：codex connect_policy.rs:71 "resolved IP is non-public →
        // PermissionDenied" 同 invariant）。
        if IPAddressLiteral.nonPublicIfLiteral(host) == true {
            return .deny(reason: "not_allowed_local")
        }
        // loopback 主机名面（dsh isLoopbackHost :257-266 / codex :33-43 并集）。
        if isLoopbackHostname(host) {
            return .deny(reason: "not_allowed_local")
        }

        // 域名白名单（deny 优先：nil 之外，未命中即拒）。
        guard let allowedDomains else { return .allow }
        for pattern in allowedDomains {
            if DomainPattern.parse(pattern).matches(host) { return .allow }
        }
        return .deny(reason: "not_allowed")
    }

    /// 模型可见结构化拒绝文案（codex network_policy_decision.rs:46 逐字形态
    /// `Network access to "host" was blocked: <reason>`）。
    static func blockedMessage(host: String, reason: String) -> String {
        return "Network access to \"\(host)\" was blocked: \(reason)"
    }

    /// dsh isLoopbackHost :257-266 / codex is_loopback_host :33-43 并集：
    /// localhost 与 `.localhost` 后缀（IP 解析面走 SSRF 判定——127/8 全段）。
    private func isLoopbackHostname(_ host: String) -> Bool {
        return host == "localhost" || host.hasSuffix(".localhost")
    }
}
