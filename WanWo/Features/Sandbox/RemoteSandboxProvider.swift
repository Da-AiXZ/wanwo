//
//  RemoteSandboxProvider.swift
//  WanWo
//
//  【M5-B 批 S2 · 远程沙箱 provider 接口 + 连通验证（拍板项③接口先行）】
//  出处（逐锚点对拍，file:line 亲验）：
//  dsh-upstream-m5/packages/e2b/e2b/src/index.ts（191 行全文）：
//    - :44-52  Config{apiKey?/cwd?/timeoutMs?}——apiKey 缺省读 `E2B_API_KEY`
//      （:97），**never forwarded into the sandbox**（:46 注释逐字）
//    - :80-81  缺省值：cwd='/home/user/workspace'，timeoutMs=300_000
//    - :142-152 validate() 三查逐字（apiKey 空 / cwd 非绝对 Linux 路径 /
//      timeoutMs 非正有限数——三条文案逐字移植）
//  packages/e2b/e2b/src/api-url.ts（26 行全文）——control-plane URL 推导
//    :21-26：E2B_API_URL 显式 > E2B_DEBUG=true → http://localhost:3000 >
//    https://api.{E2B_DOMAIN ?? 'e2b.app'}（1:1 移植，env 注入缝同款）。
//
//  E2B REST 形状（网上取证，呈报锚点；dsh 本体走 SDK 无 REST 面）：
//    · 连通验证端点：GET https://api.e2b.app/v2/sandboxes（v2 为现行；
//      v1 /sandboxes 已废弃）——e2b.dev 官方 API 文档 / dlthub 镜像取证
//    · 认证头：`X-API-Key: <key>`（legacy `Authorization: Bearer` 已废弃；
//      key 前缀 `e2b_`）；200 = 密钥有效返回 sandbox 数组 / 401 = invalid key
//  本件只做连通验证（最小面、不引 SDK）；sandbox create/exec 生命周期留后续件。
//
//  WanWo 形态适配（登记）：
//    · iOS 无运行时 shell env：apiKey 缺省解析两层——第一层 env 注入缝
//      `E2B_API_KEY`（dsh :97 语义 1:1），第二层 Info.plist `E2BAPIKey`；
//      两者皆缺省 = validate 拒绝（dsh :143-145 文案逐字）。apiKey 永不进
//      代码字面量、永不入报告/日志字段（本文件零日志面——红线）。
//    · dsh timeoutMs 是 JS number（validate 查 Number.isFinite）；Swift 用
//      Int 承载（毫秒整数量纲），finite 查Vacuously true——登记适配，文案
//      逐字保留。
//    · 传输走既有 HTTP 面：URLSession.shared.data(for:)（OnDemandBash.swift:146
//      / WebTools.swift:45 同模式），不经新网络层；测试经 performRequest
//      闭包缝注入（JobNotifier 注入闭包同款）。
//    · confine fail closed：本里程碑远程执行未接线（拍板项③接口先行）——
//      三 mode 全抛 SandboxUnavailableError（SANDBOX_UNAVAILABLE fail-closed
//      语义 dsh sandbox index.ts:118-144）。detail 文案 "remote sandbox
//      execution is not wired in this milestone" 落 dsh detail 槽（渲染为
//      " Runner failure: …" 后缀——dsh detail 槽语义本就是「后端不可用之
//      因由」，语义成立；登记待消费面裁定措辞去留）。
//    · SandboxProviderRegistry：本地 iSH 默认 / 远程 validateConnection 通过
//      才可选用；confine 消费面接线留 P2——本件不动 ShellTool（行为零变化）。
//

import Foundation

// MARK: - 远程沙箱配置（dsh e2b index.ts:44-58 + validate :142-152）

/// 共享 E2B 沙箱属主配置（dsh Config 1:1）。apiKey 属凭据面：永不转发进
/// sandbox、永不落代码/日志（dsh :46 注释语义 + 红线）。
struct RemoteSandboxConfig: Equatable, Sendable {

    /// dsh env 名（index.ts:97 `process.env.E2B_API_KEY` 逐字）。
    static let envAPIKey = "E2B_API_KEY"
    /// Info.plist 取样键名（iOS 缺省面第二层——见文件头适配登记）。
    static let infoPlistAPIKey = "E2BAPIKey"

    /// E2B API key（缺省解析见 resolveAPIKey）。
    let apiKey: String
    /// 共享远程工作目录（创建于 adapter 接收 sandbox 之前——dsh :48 注释）。
    let cwd: String
    /// E2B sandbox 生命周期毫秒数；到期即删除 sandbox（dsh :50-51 注释语义）。
    let timeoutMs: Int

    /// dsh 缺省值（index.ts:80-81）：cwd='/home/user/workspace'、
    /// timeoutMs=300_000；apiKey 无缺省（:97 缺省读 env 的语义在 resolveAPIKey）。
    init(apiKey: String,
         cwd: String = "/home/user/workspace",
         timeoutMs: Int = 300_000) {
        self.apiKey = apiKey
        self.cwd = cwd
        self.timeoutMs = timeoutMs
    }

    /// apiKey 缺省解析（dsh index.ts:97 的 WanWo 两层形态）：第一层 env
    /// 注入缝 `E2B_API_KEY`（dsh 语义 1:1），第二层 Info.plist `E2BAPIKey`。
    /// 空串按缺省处理（dsh :143 以 length===0 判空，同语义）。
    /// - Parameters:
    ///   - env: 环境取样缝（单测入参化；R6 纪律——全局读取只在对位调用侧）。
    ///   - infoPlist: Info.plist 字典取样缝；nil = 无取样面。
    /// - Returns: 解析到的 key；两层皆缺省 = nil。
    static func resolveAPIKey(env: [String: String],
                              infoPlist: [String: Any]?) -> String? {
        if let fromEnv = env[Self.envAPIKey], !fromEnv.isEmpty {
            return fromEnv
        }
        if let fromPlist = infoPlist?[Self.infoPlistAPIKey] as? String,
           !fromPlist.isEmpty {
            return fromPlist
        }
        return nil
    }

    /// control-plane URL 推导（api-url.ts:21-26 e2bApiUrl 1:1）：显式
    /// `E2B_API_URL`（非空）> `E2B_DEBUG=true`（大小写不敏感）→ debug 面
    /// http://localhost:3000 > `https://api.{E2B_DOMAIN ?? 'e2b.app'}`。
    /// api-url.ts:13-19 注释语义（选 proxy 的理由段）不移植——WanWo 形态
    /// 不经 dsh http-proxy，URL 本身逐层同构。
    static func resolveEndpoint(env: [String: String]) -> String {
        let explicit = env["E2B_API_URL"]
        if let explicit, !explicit.isEmpty { return explicit }
        if (env["E2B_DEBUG"] ?? "false").lowercased() == "true" {
            return "http://localhost:3000"   // api-url.ts:10 E2B_DEBUG_API_URL
        }
        let domain = env["E2B_DOMAIN"] ?? "e2b.app"  // api-url.ts:7 默认域
        return "https://api.\(domain)"
    }

    /// 配置校验（dsh validate() index.ts:142-152 逐查逐文案）。
    /// - Throws: `RemoteSandboxConfigError`（message = dsh 文案逐字）。
    func validate() throws {
        // :143-145——apiKey 空串 = 未配置（缺省解析层面 nil 已归一为空串）。
        if apiKey.isEmpty {
            throw RemoteSandboxConfigError(
                message: "dsh-e2b: configure apiKey or set E2B_API_KEY")
        }
        // :146-148——posix.isAbsolute ≈ 绝对路径以 "/" 起（Linux 语义）。
        if !cwd.hasPrefix("/") {
            throw RemoteSandboxConfigError(
                message: "dsh-e2b: cwd must be an absolute Linux path: \(cwd)")
        }
        // :149-151——Int 量纲下 finite 查vacuously成立（适配登记见文件头）。
        if timeoutMs <= 0 {
            throw RemoteSandboxConfigError(
                message: "dsh-e2b: timeoutMs must be a positive finite number")
        }
    }
}

/// 配置校验错误（dsh validate 的 plain Error + message 形态；errorDescription
/// 直透 message——文案逐字由测试对拍）。
struct RemoteSandboxConfigError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 连通验证报告（派单形状：ok/httpStatus/latencyMs/endpoint）

/// validateConnection 的结构化报告——失败**返回不抛**（派单语义）：网络错、
/// 非 2xx 一律落字段。字段零凭据（apiKey 永不出现在报告/日志）。
struct RemoteConnectionReport: Equatable, Sendable {
    /// 连通是否成立（HTTP 2xx）。
    let ok: Bool
    /// HTTP 状态码；nil = 未达 HTTP 层（网络错误/URL 非法）。
    let httpStatus: Int?
    /// 往返耗时（毫秒，含 DNS/TLS；测试桩场景近零）。
    let latencyMs: Int
    /// 实际请求的 control-plane 端点（resolveEndpoint 产物；无凭据成分）。
    let endpoint: String
}

// MARK: - 远程沙箱 provider（SandboxProvider 缝的 E2B 形态）

/// E2B 远程沙箱 provider。本里程碑只承担两职责：
/// ① confine fail closed（SANDBOX_UNAVAILABLE——远程执行未接线，派单拍板项③
///    接口先行；绝不静默直通，dsh sandbox index.ts:153-157 禁令语义）；
/// ② validateConnection 连通验证（REST GET /v2/sandboxes + X-API-Key 头，
///    失败结构化返回不抛——装配面据此决定远程是否可选用）。
/// sandbox create/exec 生命周期（dsh E2BRuntime eager-open 形态）留后续件。
struct RemoteSandboxProvider: SandboxProvider {

    /// 已校验配置（init 内 validate 强制）。
    let config: RemoteSandboxConfig
    /// control-plane 端点（resolveEndpoint 产物；构造期固化）。
    let endpoint: String

    /// 传输缝（既有 HTTP 面 URLSession.shared.data(for:)——OnDemandBash.swift:146
    /// / WebTools.swift:45 同模式；测试桩经此注入，不走真网络）。
    var performRequest: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    /// - Parameters:
    ///   - config: 远程沙箱配置（init 内先 validate——dsh E2BRuntime 构造期
    ///     validate 同位，index.ts:103）。
    ///   - endpoint: 端点注入缝；nil = 经 ProcessInfo 环境取样推导
    ///     （resolveEndpoint——全局环境读取单点，R6 纪律与
    ///     MCPTransportFactory.buildChildEnv parent 取样同位）。
    /// - Throws: 配置校验失败（RemoteSandboxConfigError，dsh 文案逐字）。
    init(config: RemoteSandboxConfig, endpoint: String? = nil) throws {
        try config.validate()
        self.config = config
        self.endpoint = endpoint
            ?? RemoteSandboxConfig.resolveEndpoint(
                env: ProcessInfo.processInfo.environment)
    }

    // MARK: SandboxProvider（fail closed——本里程碑远程执行未接线）

    /// 三 mode 全抛 SandboxUnavailableError（SANDBOX_UNAVAILABLE fail-closed；
    /// detail = 派单指定文案——见文件头适配登记）。禁止静默不受限直通
    /// （dsh sandbox index.ts:153-157）。
    func confine(policy: SandboxExecutionPolicy, command: String) throws -> ConfinedCommand {
        throw SandboxUnavailableError(
            mode: policy.mode,
            detail: "remote sandbox execution is not wired in this milestone")
    }

    // MARK: 连通验证（REST 最小面——不引 SDK）

    /// E2B control-plane 连通验证：GET {endpoint}/v2/sandboxes + `X-API-Key`
    /// 头（REST 形状取证见文件头）。200 = ok（sandbox 数组）/ 401 = invalid
    /// key / 其余非 2xx 与网络错误 = 结构化失败返回（不抛）。
    /// 请求超时 = config.timeoutMs 换算秒（URLRequest.timeoutInterval）。
    /// - Returns: `RemoteConnectionReport`（字段零凭据）。
    func validateConnection() async -> RemoteConnectionReport {
        let startedAt = Date()
        func makeReport(ok: Bool, httpStatus: Int?) -> RemoteConnectionReport {
            RemoteConnectionReport(
                ok: ok,
                httpStatus: httpStatus,
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                endpoint: endpoint)
        }
        // endpoint 非法（构造期已固化，防御性兜底）= 结构化失败。
        guard let url = URL(string: endpoint + "/v2/sandboxes") else {
            return makeReport(ok: false, httpStatus: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // 认证头：X-API-Key 现行（legacy Authorization Bearer 已废弃——取证）。
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = Double(config.timeoutMs) / 1000
        do {
            let (_, response) = try await performRequest(request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let ok = status.map { (200..<300).contains($0) } ?? false
            return makeReport(ok: ok, httpStatus: status)
        } catch {
            // 网络错误（URLError 等）：结构化失败，httpStatus=nil，不抛。
            return makeReport(ok: false, httpStatus: nil)
        }
    }
}

// MARK: - provider 注册表（本地默认 / 远程 opt-in）

/// 沙箱 provider 注册表：本地 iSH 后端恒为默认（S1 LocalSandboxProvider——
/// 唯一候选形态）；远程 E2B 仅在 validateConnection 通过后挂入（opt-in）。
/// confine 消费面接线留 P2——本件不动 ShellTool（行为零变化，派单纪律）。
struct SandboxProviderRegistry: Sendable {

    /// 本地默认 provider（iSH 后端）。
    let local: SandboxProvider
    /// 远程 provider；nil = 未启用或连通验证未通过（回落本地唯一候选）。
    let remote: RemoteSandboxProvider?

    /// 消费缝（P2 接线用）：远程在场优先远程，回落本地。
    func preferredProvider() -> SandboxProvider {
        return remote ?? local
    }

    /// 装配工厂（派单语义「validateConnection 通过才可选用」）：远程在场时
    /// 先连通验证，通过才挂入；失败结构化吞掉（远程保持不可用，不抛）。
    static func assemble(
        local: SandboxProvider = LocalSandboxProvider(),
        remote: RemoteSandboxProvider?
    ) async -> SandboxProviderRegistry {
        guard let remote else {
            return SandboxProviderRegistry(local: local, remote: nil)
        }
        let report = await remote.validateConnection()
        return SandboxProviderRegistry(
            local: local,
            remote: report.ok ? remote : nil)
    }
}
