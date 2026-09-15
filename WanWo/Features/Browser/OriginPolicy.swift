//
//  OriginPolicy.swift
//  WanWo
//
//  【M6.3 B2 · origin 策略最小本地近似（设计强制；OpenMinis 无此面——语义源=codex）】
//  语义源：analysis/06-codex-gap5-browser-computer-use.md:117-124
//  （codex config/src/browser_use.rs BrowserUseConfigToml 的词汇与缺省档）：
//
//      [browser_use]
//      default_origin_policy = { access = "allow", downloads = "ask",
//                                uploads = "deny", full_cdp_access = "deny" }
//      [browser_use.origins."https://intranet.example.com"]   # per-origin 覆盖
//      access = "allow"
//
//  最小化裁定（派单口径：只做默认档 + 可后置扩展的存储结构，不做 per-origin
//  配置 UI；四维词汇 1:1，不做 codex requirements 层合并栈）：
//    · access          —— 落点 = BrowserUseManager WKNavigationAction 决策处；
//    · downloads       —— 落点 = 两处 .download 决策（anchor/服务端下转）+
//                          fetch 动作工具层前置判定；"ask" 走 browser_use 工具
//                          的审批缝（SandboxEscalationApprover 同一呈现缝）；
//    · uploads         —— 引擎无 runOpenPanel 实现（OpenMinis 原件同款）=
//                          结构性 deny；判定函数在位，未来接入文件选取入口
//                          时必经 authorizeUploads；
//    · full_cdp_access —— iOS WKWebView 无 CDP（Apple 强制 WebKit；WIR 协议
//                          不开放应用内通道，06-gap5:56 联网核实）——恒 deny
//                          为不可抗力，无代码路径，仅保留政策维记录。
//  存储结构：defaultRule + originOverrides 字典（本批恒空、无写入面）——
//  per-origin 覆盖的判定路径已通，配置面接入时零判定逻辑改动。
//

import Foundation

// MARK: - 决策词汇（codex AllowDenyRequirementToml::{Allow, Deny} + ask 档）

/// 单维决策三值（codex 二值 + 审批档：needs/可以放行语义拆出 ask——
/// "ask"=需审批后放行，审批走 F022 砍除后仅存的沙箱提权呈现缝）。
enum OriginPolicyDecision: String, Equatable, Sendable {
    case allow
    case ask
    case deny
}

// MARK: - 政策规则（codex BrowserUseConfigToml 四维形态）

/// 单 origin（或缺省档）的四维政策（codex default_origin_policy 形态 1:1）。
struct OriginPolicyRule: Equatable, Sendable {
    /// 页面访问/读取类动作（导航 + execute_js 等页内动作）。
    var access: OriginPolicyDecision
    /// 下载（fetch 动作 + WKDownload 下转）。
    var downloads: OriginPolicyDecision
    /// 上传/文件选取。
    var uploads: OriginPolicyDecision
    /// 完整 CDP 通道（iOS 不可抗力：恒 deny，无对应代码路径）。
    var fullCDPAccess: OriginPolicyDecision

    /// codex default_origin_policy 缺省档 1:1（06-gap5:117）。
    static let `default` = OriginPolicyRule(
        access: .allow,
        downloads: .ask,
        uploads: .deny,
        fullCDPAccess: .deny)
}

// MARK: - OriginPolicy

/// origin 策略单例（最小本地近似：缺省档 + 预留 per-origin 覆盖存储）。
@MainActor
final class OriginPolicy {

    static let shared = OriginPolicy()

    /// 缺省档（codex default_origin_policy 同款）。
    var defaultRule: OriginPolicyRule = .default

    /// per-origin 覆盖表（键=origin 前缀字符串；生产本批恒空、无配置写入面
    /// ——存储结构先行，配置 UI/持久化随后续批次接入，判定路径已通。
    /// setter 保持 internal 供单测注入矩阵用例——OriginPolicyTests 前置）。
    var originOverrides: [String: OriginPolicyRule] = [:]

    /// downloads/uploads 的 "ask" 审批缝（工具层接线）。
    ///
    /// BrowserUseTool 在每次 execute 前（工具经 ToolPipeline exclusive 车道
    /// 串行执行）把 ctx.escalationApprover 适配成本闭包：reason 走审批呈现，
    /// 返回 true=allowed-once 放行。nil = 无审批缝 → ask 一律 fail closed
    /// （视为拒绝——与 P1-3 提权 fail closed 语义同源）。
    var askHandler: ((_ reason: String) async -> Bool)?

    private init() {}

    // MARK: 单维判定

    /// 单维判定（含 per-origin 前缀覆盖解析：最长前缀匹配——codex
    /// origins."https://intranet.example.com" 前缀语义的本地近似）。
    func decide(_ dimension: WritableKeyPath<OriginPolicyRule, OriginPolicyDecision>,
                for origin: String?) -> OriginPolicyDecision {
        if let origin, !origin.isEmpty {
            var best: (prefix: String, rule: OriginPolicyRule)?
            for (prefix, rule) in originOverrides where origin.hasPrefix(prefix) {
                if best == nil || prefix.count > best!.prefix.count { best = (prefix, rule) }
            }
            if let best { return best.rule[keyPath: dimension] }
        }
        return defaultRule[keyPath: dimension]
    }

    // MARK: 授权执行（ask → 审批缝；无缝 fail closed）

    /// downloads 维授权（fetch 动作前置 + WKDownload 决策处调用）。
    /// allow→true；deny→false；ask→askHandler（nil=无缝 fail closed→false）。
    func authorizeDownloads(for origin: String?) async -> Bool {
        await authorize(keyPath: \.downloads, origin: origin,
                        dimensionName: "downloads")
    }

    /// uploads 维授权（本批无文件选取入口——结构性 deny；函数在位供
    /// 未来入口接入时调用）。
    func authorizeUploads(for origin: String?) async -> Bool {
        await authorize(keyPath: \.uploads, origin: origin,
                        dimensionName: "uploads")
    }

    /// access 维判定（同步——导航决策处 decisionHandler 前使用；缺省 allow
    /// 为纯直通，deny 即取消。access 无 ask 档执行路径：审批面向的是
    /// downloads/uploads 两个副作用维，访问维 deny 即够）。
    func allowsAccess(for origin: String?) -> Bool {
        decide(\.access, for: origin) != .deny
    }

    private func authorize(keyPath: WritableKeyPath<OriginPolicyRule, OriginPolicyDecision>,
                           origin: String?, dimensionName: String) async -> Bool {
        switch decide(keyPath, for: origin) {
        case .allow:
            return true
        case .deny:
            return false
        case .ask:
            guard let askHandler else { return false } // 无审批缝 → fail closed
            let host = origin ?? "unknown origin"
            return await askHandler(
                "browser_use \(dimensionName) is set to ask for \(host). "
                    + "Allow this action to proceed?")
        }
    }
}
