//
//  OnDemandBash.swift
//  WanWo
//
//  【语义移植 · OpenMinis 原件】出处：repos/OpenMinis-main/src/ios/Agent/Shell/
//  OnDemandBash.swift（1:1 移植；执行器闭包由 WanWo 侧接到 IshExecutorBridge）。
//  脚本需要 bash 时按需确认/安装，带设计评审的护栏（T-bash-on-demand §2/§3，F2/M5）：
//    - 进程内三态可用性缓存（unavailable 有 10 分钟 TTL；available 遇后续 127 自愈），
//    - 真正跑 `apk` 之前先做宿主侧 5 秒网络预检（F2），
//    - 持久化失败退避（24h / 3 次），坏 apk 源或离线设备不会每次冷启动都吃安装预算（F2），
//    - 每进程生命周期只尝试安装一次。
//
//  `probe`/`install` 是注入闭包（跑 guest 命令返回退出码）——调用方接到真实
//  ISH 协调器，本类型不碰 MainActor。
//

import Foundation

private let logger = AppLogger(category: "Bashism")

actor OnDemandBash {
    static let shared = OnDemandBash()

    enum Availability { case unknown, available, unavailable(until: Date) }

    private var availability: Availability = .unknown
    private var attemptedInstallThisLaunch = false

    // 持久化失败退避（UserDefaults——跨冷启动存活）。
    private let failCountKey = "bash.install.failCount"
    private let lastFailKey = "bash.install.lastFailAt"
    private let maxStrikes = 3
    private let backoffWindow: TimeInterval = 24 * 3600
    private let unavailableTTL: TimeInterval = 10 * 60
    private let installBudget: TimeInterval = 60

    /// apk 镜像主机（安装前探测可达性）。
    private let apkProbeURL = URL(string: "https://dl-cdn.alpinelinux.org/alpine/")!

    struct Executor {
        /// 跑一条 guest 命令，返回退出码。不抛错：失败映射为非零码。
        let run: (_ command: String, _ timeout: TimeInterval) async -> Int
    }

    enum Outcome {
        case available                 // bash 可用
        case unavailable(reason: String)  // 退回 sh；reason 进 reminder
    }

    /// 确保 bash 可用。幂等 + 缓存。
    func ensureBash(executor: Executor) async -> Outcome {
        switch availability {
        case .available:
            return .available
        case .unavailable(let until):
            if Date() < until { return .unavailable(reason: "bash not installed") }
            availability = .unknown  // TTL 过期——重新探测（用户可能已手动安装）
        case .unknown:
            break
        }

        // 探测：bash 是否已在？
        if await executor.run("command -v bash >/dev/null 2>&1", 15) == 0 {
            availability = .available
            return .available
        }

        // 未安装。判断是否允许尝试安装。
        if attemptedInstallThisLaunch {
            availability = .unavailable(until: Date().addingTimeInterval(unavailableTTL))
            return .unavailable(reason: "bash install already attempted this session")
        }
        if let backoff = backoffReason() {
            availability = .unavailable(until: Date().addingTimeInterval(unavailableTTL))
            return .unavailable(reason: backoff)
        }

        attemptedInstallThisLaunch = true

        // F2：碰 apk 之前先做便宜的宿主侧可达性检查。
        if !(await networkReachable()) {
            recordFailure()
            availability = .unavailable(until: Date().addingTimeInterval(unavailableTTL))
            return .unavailable(reason: "network/apk mirror unreachable")
        }

        // 安装（独立预算；不占调用方的命令超时）。
        logger.info("[Bashism] installing bash (budget \(Int(installBudget))s)…")
        let rc = await executor.run("apk add bash", installBudget)
        let verified = rc == 0 ? (await executor.run("command -v bash >/dev/null 2>&1", 15) == 0) : false
        if verified {
            clearFailure()
            availability = .available
            // 安装成功后重新武装本生命周期守卫：它存在的目的是阻止反复失败的安装
            // 每次调用都吃预算，而不是阻止同一会话内用户后来 `apk del bash` 后的
            // 一次全新重装（M5 自愈必须仍然可用）。
            attemptedInstallThisLaunch = false
            logger.info("[Bashism] bash installed OK")
            return .available
        }

        recordFailure()
        availability = .unavailable(until: Date().addingTimeInterval(unavailableTTL))
        logger.error("[Bashism] bash install failed (rc=\(rc))")
        return .unavailable(reason: "apk add bash failed (rc=\(rc))")
    }

    /// 执行路径发现 `bash <file>` 本身返回 127 / not-found 时调用——
    /// 用户可能在我们缓存 available 之后 `apk del bash` 了（M5）。
    func markDisappeared() {
        availability = .unknown
    }

    // MARK: - 退避记账

    private func backoffReason() -> String? {
        let d = UserDefaults.standard
        let count = d.integer(forKey: failCountKey)
        if count >= maxStrikes {
            return "bash install disabled after \(maxStrikes) failures (retry manually: apk add bash)"
        }
        let last = d.double(forKey: lastFailKey)
        if last > 0, Date().timeIntervalSince1970 - last < backoffWindow {
            return "bash install backing off (recent failure)"
        }
        return nil
    }

    private func recordFailure() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: failCountKey) + 1, forKey: failCountKey)
        d.set(Date().timeIntervalSince1970, forKey: lastFailKey)
    }

    private func clearFailure() {
        let d = UserDefaults.standard
        d.removeObject(forKey: failCountKey)
        d.removeObject(forKey: lastFailKey)
    }

    private func networkReachable() async -> Bool {
        var req = URLRequest(url: apkProbeURL)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse { return (200..<500).contains(http.statusCode) }
            return true
        } catch {
            return false
        }
    }
}
